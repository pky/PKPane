import Foundation
import PLzmaSDK
import SWCompression
import Unrar
import ZIPFoundation

enum ArchiveFileProviderError: LocalizedError {
  case invalidLocation
  case itemNotFound
  case notDirectory
  case entryTooLarge(String)
  case stagingCapacityExceeded
  case archiveChanged
  case invalidExtractedSize

  var errorDescription: String? {
    switch self {
    case .invalidLocation:
      "アーカイブ内の場所が無効です。"
    case .itemNotFound:
      "アーカイブ内の項目が見つかりません。"
    case .notDirectory:
      "アーカイブ内のフォルダではありません。"
    case .entryTooLarge(let name):
      "「\(name)」は一時展開キャッシュの上限を超えるため表示できません。"
    case .stagingCapacityExceeded:
      "圧縮tarの一時展開容量が上限に達しています。開いているアーカイブを閉じてください。"
    case .archiveChanged:
      "アーカイブの内容が閲覧開始後に変更されました。開き直してください。"
    case .invalidExtractedSize:
      "アーカイブ内のファイルサイズを検証できませんでした。"
    }
  }
}

/// アーカイブを通常のブラウザ画面へ投影する読み取り専用Provider。
/// ライブラリ固有のEntry本体は保持せず、一覧に必要な不変メタデータだけを
/// 初期化時にスナップショット化する。
struct ArchiveFileProvider: FileBrowserProvider, FileBrowserPreviewProvider,
  FileStreamReadableProvider
{
  let id: FileProviderID
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .readSymbolicLink]
  let archiveURL: URL
  let rootLocation: FileLocation
  let invalidEntryCount: Int

  private let limits: ArchiveSafetyLimits
  private let extractionCache: ArchiveExtractionCache
  private let entryArchiveURL: URL
  private let temporaryEntryArchive: ArchiveProviderTemporaryFile?
  private let entriesByPath: [String: ArchiveIndexedEntry]
  private let childPathsByDirectory: [String: [String]]

  init(
    archiveURL: URL,
    limits: ArchiveSafetyLimits = .default,
    identifier: UUID = UUID(),
    extractionCache: ArchiveExtractionCache = .shared,
    stagingBudget: ArchiveStagingBudget = .shared
  ) throws {
    let archiveURL = archiveURL.standardizedFileURL
    let providerID = FileProviderID(rawValue: "archive:\(identifier.uuidString)")
    guard let format = ArchiveFormat(url: archiveURL) else {
      throw ArchiveServiceError.unsupportedFormat(archiveURL.pathExtension)
    }
    let index: ArchiveIndex
    let entryArchiveURL: URL
    var temporaryEntryArchive: ArchiveProviderTemporaryFile? = nil
    switch format {
    case .zip:
      let archive = try ZIPFoundation.Archive(url: archiveURL, accessMode: .read)
      index = try ArchiveIndexBuilder.build(
        entries: archive,
        providerID: providerID,
        limits: limits)
      entryArchiveURL = archiveURL
    case .sevenZip:
      index = try SevenZipArchiveEntryReader.buildIndex(
        at: archiveURL,
        providerID: providerID,
        limits: limits)
      entryArchiveURL = archiveURL
    case .rar:
      index = try RARArchiveEntryReader.buildIndex(
        at: archiveURL,
        providerID: providerID,
        limits: limits)
      entryArchiveURL = archiveURL
    case .tar:
      index = try TarArchiveEntryReader.buildIndex(
        at: archiveURL,
        providerID: providerID,
        limits: limits,
        format: format)
      entryArchiveURL = archiveURL
    case .tarGzip, .tarBzip2, .tarXz:
      let stagedTar = try CompressedTarArchiveStager.stage(
        archiveURL: archiveURL,
        format: format,
        limits: limits,
        budget: stagingBudget)
      index = try TarArchiveEntryReader.buildIndex(
        at: stagedTar.url,
        providerID: providerID,
        limits: limits,
        format: format)
      entryArchiveURL = stagedTar.url
      temporaryEntryArchive = stagedTar
    case .gzip, .bzip2, .xz:
      index = try SingleFileArchiveEntryReader.buildIndex(
        at: archiveURL,
        providerID: providerID,
        limits: limits,
        format: format)
      entryArchiveURL = archiveURL
    }

    id = providerID
    self.archiveURL = archiveURL
    rootLocation = FileLocation(remotePath: "/", providerID: providerID)
    invalidEntryCount = index.invalidEntryCount
    self.limits = limits
    self.extractionCache = extractionCache
    self.entryArchiveURL = entryArchiveURL
    self.temporaryEntryArchive = temporaryEntryArchive
    entriesByPath = index.entriesByPath
    childPathsByDirectory = index.childPathsByDirectory
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    guard location.providerID == id, let path = location.remotePath else {
      throw ArchiveFileProviderError.invalidLocation
    }
    let normalizedPath = ArchiveVirtualPath.normalized(path)
    if normalizedPath != "/" {
      guard let entry = entriesByPath[normalizedPath] else {
        throw ArchiveFileProviderError.itemNotFound
      }
      guard entry.isDirectory else {
        throw ArchiveFileProviderError.notDirectory
      }
    }
    return childPathsByDirectory[normalizedPath, default: []].compactMap {
      entriesByPath[$0]?.fileItem
    }
  }

  func parent(of location: FileLocation) -> FileLocation? {
    guard location.providerID == id, let path = location.remotePath else { return nil }
    let normalizedPath = ArchiveVirtualPath.normalized(path)
    guard normalizedPath != "/" else { return nil }
    return FileLocation(
      remotePath: ArchiveVirtualPath.parent(of: normalizedPath),
      providerID: id)
  }

  func breadcrumbs(
    for location: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    guard location.providerID == id, let path = location.remotePath else { return [] }
    var breadcrumbs = [
      FileBrowserBreadcrumb(location: rootLocation, name: archiveURL.lastPathComponent)
    ]
    var currentPath = ""
    for component in ArchiveVirtualPath.components(of: path) {
      currentPath += "/\(component)"
      breadcrumbs.append(
        FileBrowserBreadcrumb(
          location: FileLocation(remotePath: currentPath, providerID: id),
          name: component))
    }
    return breadcrumbs
  }

  func previewURL(for item: FileItem) async throws -> URL {
    let entry = try indexedFile(for: item)
    let ownedEntryArchive = temporaryEntryArchive
    let key = ArchiveExtractionCache.Key(providerID: id, entryPath: entry.path)
    return try await extractionCache.cachedURL(
      for: key,
      fileName: entry.name,
      expectedSize: entry.declaredUncompressedSize
    ) { destinationURL in
      try withExtendedLifetime(ownedEntryArchive) {
        try ArchiveEntryReader.extractFile(
          at: entryArchiveURL,
          entry: entry,
          to: destinationURL,
          limits: limits)
      }
    }
  }

  func detailThumbnailURL(for item: FileItem) async throws -> URL? {
    try await previewURL(for: item)
  }

  func fileChunks(
    for item: FileItem,
    chunkSize: Int
  ) -> AsyncThrowingStream<Data, Error> {
    let archiveURL = entryArchiveURL
    let ownedEntryArchive = temporaryEntryArchive
    let limits = limits
    let entry: ArchiveIndexedEntry
    do {
      entry = try indexedFile(for: item)
    } catch {
      return AsyncThrowingStream { $0.finish(throwing: error) }
    }
    let limit = max(4, (4 * 1_048_576) / max(chunkSize, 1))
    return BoundedChunkPipe.synchronousStream(limit: limit) { yield in
      try withExtendedLifetime(ownedEntryArchive) {
        try ArchiveEntryReader.streamFile(
          at: archiveURL,
          entry: entry,
          chunkSize: chunkSize,
          limits: limits
        ) { data in
          try yield(data)
        }
      }
    }
  }

  private func indexedFile(for item: FileItem) throws -> ArchiveIndexedEntry {
    guard item.location.providerID == id,
      let path = item.location.remotePath,
      let entry = entriesByPath[ArchiveVirtualPath.normalized(path)]
    else {
      throw ArchiveFileProviderError.itemNotFound
    }
    guard !entry.isDirectory else { throw ArchiveFileProviderError.notDirectory }
    return entry
  }
}

struct ArchiveIndex: Sendable {
  let entriesByPath: [String: ArchiveIndexedEntry]
  let childPathsByDirectory: [String: [String]]
  let invalidEntryCount: Int
}

struct ArchiveEntryDescriptor: Sendable {
  let rawPath: String
  let isDirectory: Bool
  let uncompressedSize: Int64?
  let compressedSize: Int64?
  let checksum: UInt32?
  let modificationDate: Date?
  let ordinal: Int
}

struct ArchiveIndexedEntry: Sendable {
  let path: String
  let providerID: FileProviderID
  let providerToken: String
  let isDirectory: Bool
  let isSyntheticDirectory: Bool
  let size: Int64?
  let modifiedAt: Date?
  let format: ArchiveFormat
  let ordinal: Int

  init(
    path: String,
    providerID: FileProviderID,
    providerToken: String,
    isDirectory: Bool,
    isSyntheticDirectory: Bool,
    size: Int64?,
    modifiedAt: Date?,
    archivePath: String,
    compressedSize: UInt64,
    checksum: UInt32?,
    format: ArchiveFormat,
    ordinal: Int = 0
  ) {
    self.path = path
    self.providerID = providerID
    self.providerToken = providerToken
    self.isDirectory = isDirectory
    self.isSyntheticDirectory = isSyntheticDirectory
    self.size = size
    self.modifiedAt = modifiedAt
    self.archivePath = archivePath
    self.compressedSize = compressedSize
    self.checksum = checksum
    self.format = format
    self.ordinal = ordinal
  }

  var name: String { ArchiveVirtualPath.name(of: path) }
  var declaredUncompressedSize: UInt64? { size.flatMap(UInt64.init(exactly:)) }
  var uncompressedSize: UInt64 { UInt64(size ?? 0) }
  var identity: ArchiveEntryIdentity {
    ArchiveEntryIdentity(
      archivePath: archivePath,
      uncompressedSize: uncompressedSize,
      compressedSize: compressedSize,
      checksum: checksum)
  }

  let archivePath: String
  let compressedSize: UInt64
  let checksum: UInt32?

  var fileItem: FileItem {
    FileItem(
      remotePath: path,
      url: ArchiveVirtualPath.itemURL(providerToken: providerToken, path: path),
      providerID: providerID,
      isDirectory: isDirectory,
      size: size,
      modifiedAt: modifiedAt,
      name: name)
  }
}

enum ArchiveIndexBuilder {
  fileprivate static func build(
    entries: ZIPFoundation.Archive,
    providerID: FileProviderID,
    limits: ArchiveSafetyLimits
  ) throws -> ArchiveIndex {
    let entriesArray = Array(entries)
    let resolver = ZipArchivePathResolver(entries: entriesArray)
    var descriptors: [ArchiveEntryDescriptor] = []
    var invalidEntryCount = 0

    for (ordinal, entry) in entriesArray.enumerated() {
      do {
        let resolvedPath = resolver.path(for: entry)
        try ArchiveEntrySafety.validateMetadata(
          entry: ArchiveSafetyEntry(entry, path: resolvedPath),
          limits: limits,
          format: .zip)
        guard let uncompressedSize = Int64(exactly: entry.uncompressedSize),
          let compressedSize = Int64(exactly: entry.compressedSize)
        else {
          invalidEntryCount += 1
          continue
        }
        descriptors.append(
          ArchiveEntryDescriptor(
            rawPath: resolvedPath,
            isDirectory: entry.type == .directory,
            uncompressedSize: uncompressedSize,
            compressedSize: compressedSize,
            checksum: entry.checksum,
            modificationDate: entry.fileAttributes[.modificationDate] as? Date,
            ordinal: ordinal))
      } catch {
        invalidEntryCount += 1
      }
    }

    let index = try build(
      descriptors: descriptors,
      providerID: providerID,
      limits: limits,
      format: .zip)
    return ArchiveIndex(
      entriesByPath: index.entriesByPath,
      childPathsByDirectory: index.childPathsByDirectory,
      invalidEntryCount: invalidEntryCount + index.invalidEntryCount)
  }

  static func build(
    descriptors: [ArchiveEntryDescriptor],
    providerID: FileProviderID,
    limits: ArchiveSafetyLimits,
    format: ArchiveFormat
  ) throws -> ArchiveIndex {
    var records: [String: ArchiveIndexedEntry] = [:]
    var invalidEntryCount = 0
    var acceptedEntryCount = 0
    var totalBytes: UInt64 = 0
    var acceptedSafetyEntries: [ArchiveSafetyEntry] = []
    acceptedSafetyEntries.reserveCapacity(min(descriptors.count, limits.maximumEntryCount))

    for descriptor in descriptors {
      guard acceptedEntryCount < limits.maximumEntryCount else {
        invalidEntryCount += 1
        continue
      }
      do {
        let components = try ArchiveEntrySafety.validatedPathComponents(
          descriptor.rawPath,
          format: format)
        let path = "/" + components.joined(separator: "/")
        let isDirectory = descriptor.isDirectory
        guard canInsert(path: path, isDirectory: isDirectory, into: records) else {
          invalidEntryCount += 1
          continue
        }
        let uncompressedSize: UInt64
        if let declaredSize = descriptor.uncompressedSize {
          guard let convertedSize = UInt64(exactly: declaredSize) else {
            invalidEntryCount += 1
            continue
          }
          uncompressedSize = convertedSize
        } else {
          uncompressedSize = 0
        }
        let compressedSize: UInt64
        if let declaredSize = descriptor.compressedSize {
          guard let convertedSize = UInt64(exactly: declaredSize) else {
            invalidEntryCount += 1
            continue
          }
          compressedSize = convertedSize
        } else {
          compressedSize = 0
        }
        let (nextTotalBytes, overflow) = totalBytes.addingReportingOverflow(
          uncompressedSize)
        guard !overflow, nextTotalBytes <= limits.maximumUncompressedBytes else {
          invalidEntryCount += 1
          continue
        }
        totalBytes = nextTotalBytes
        acceptedEntryCount += 1
        insertMissingParentDirectories(
          for: path,
          providerID: providerID,
          format: format,
          into: &records)
        records[path] = ArchiveIndexedEntry(
          path: path,
          providerID: providerID,
          providerToken: providerID.rawValue,
          isDirectory: isDirectory,
          isSyntheticDirectory: false,
          size: isDirectory ? nil : descriptor.uncompressedSize,
          modifiedAt: descriptor.modificationDate,
          archivePath: descriptor.rawPath,
          compressedSize: compressedSize,
          checksum: descriptor.checksum,
          format: format,
          ordinal: descriptor.ordinal)
        acceptedSafetyEntries.append(
          ArchiveSafetyEntry(
            path: descriptor.rawPath,
            uncompressedSize: uncompressedSize,
            compressedSize: compressedSize,
            isSymbolicLink: false))
      } catch {
        invalidEntryCount += 1
      }
    }

    try ArchiveEntrySafety.validateAggregateCompressionRatio(
      entries: acceptedSafetyEntries,
      limits: limits,
      format: format)

    var children: [String: [String]] = [:]
    for path in records.keys {
      children[ArchiveVirtualPath.parent(of: path), default: []].append(path)
    }
    for directory in children.keys {
      children[directory]?.sort {
        ArchiveVirtualPath.name(of: $0).localizedStandardCompare(
          ArchiveVirtualPath.name(of: $1)) == .orderedAscending
      }
    }
    return ArchiveIndex(
      entriesByPath: records,
      childPathsByDirectory: children,
      invalidEntryCount: invalidEntryCount)
  }

  static func canInsert(
    path: String,
    isDirectory: Bool,
    into records: [String: ArchiveIndexedEntry]
  ) -> Bool {
    if let existing = records[path] {
      // 子から先に合成した暗黙ディレクトリは、後続の明示ディレクトリEntryで補完できる。
      return existing.isDirectory && isDirectory && existing.isSyntheticDirectory
    }
    var parent = ArchiveVirtualPath.parent(of: path)
    while parent != "/" {
      if let ancestor = records[parent], !ancestor.isDirectory { return false }
      parent = ArchiveVirtualPath.parent(of: parent)
    }
    if !isDirectory {
      let prefix = path + "/"
      guard !records.keys.contains(where: { $0.hasPrefix(prefix) }) else { return false }
    }
    return true
  }

  private static func insertMissingParentDirectories(
    for path: String,
    providerID: FileProviderID,
    format: ArchiveFormat,
    into records: inout [String: ArchiveIndexedEntry]
  ) {
    var parent = ArchiveVirtualPath.parent(of: path)
    while parent != "/" {
      if records[parent] == nil {
        records[parent] = ArchiveIndexedEntry(
          path: parent,
          providerID: providerID,
          providerToken: providerID.rawValue,
          isDirectory: true,
          isSyntheticDirectory: true,
          size: nil,
          modifiedAt: nil,
          archivePath: "",
          compressedSize: 0,
          checksum: nil,
          format: format,
          ordinal: -1)
      }
      parent = ArchiveVirtualPath.parent(of: parent)
    }
  }
}

struct ArchiveEntryIdentity: Sendable {
  let archivePath: String
  let uncompressedSize: UInt64
  let compressedSize: UInt64
  let checksum: UInt32?
}

enum ArchiveEntryReader {
  static func extractFile(
    at archiveURL: URL,
    entry: ArchiveIndexedEntry,
    to destinationURL: URL,
    limits: ArchiveSafetyLimits
  ) throws {
    switch entry.format {
    case .zip:
      try extractFile(
        at: archiveURL,
        entry: entry.identity,
        to: destinationURL,
        limits: limits,
        validateCompressionRatio: false)
    case .sevenZip:
      try SevenZipArchiveEntryReader.extractFile(
        at: archiveURL,
        entry: entry,
        to: destinationURL,
        limits: limits)
    case .rar:
      try RARArchiveEntryReader.extractFile(
        at: archiveURL,
        entry: entry,
        to: destinationURL,
        limits: limits)
    case .tar, .tarGzip, .tarBzip2, .tarXz:
      try TarArchiveEntryReader.extractFile(
        at: archiveURL,
        entry: entry,
        to: destinationURL,
        limits: limits)
    case .gzip, .bzip2, .xz:
      try SingleFileArchiveEntryReader.extractFile(
        at: archiveURL,
        entry: entry,
        to: destinationURL,
        limits: limits)
    }
  }

  static func streamFile(
    at archiveURL: URL,
    entry: ArchiveIndexedEntry,
    chunkSize: Int,
    limits: ArchiveSafetyLimits,
    consume: @escaping (Data) throws -> Void
  ) throws {
    switch entry.format {
    case .zip:
      try streamFile(
        at: archiveURL,
        entry: entry.identity,
        chunkSize: chunkSize,
        limits: limits,
        validateCompressionRatio: false,
        consume: consume)
    case .sevenZip:
      try ArchiveExtractedFileReader.streamFile(
        entry: entry,
        chunkSize: chunkSize,
        extract: { destinationURL in
          try SevenZipArchiveEntryReader.extractFile(
            at: archiveURL,
            entry: entry,
            to: destinationURL,
            limits: limits)
        },
        consume: consume)
    case .rar:
      try ArchiveExtractedFileReader.streamFile(
        entry: entry,
        chunkSize: chunkSize,
        extract: { destinationURL in
          try RARArchiveEntryReader.extractFile(
            at: archiveURL,
            entry: entry,
            to: destinationURL,
            limits: limits)
        },
        consume: consume)
    case .tar, .tarGzip, .tarBzip2, .tarXz:
      try ArchiveExtractedFileReader.streamFile(
        entry: entry,
        chunkSize: chunkSize,
        maximumBytes: limits.maximumUncompressedBytes,
        extract: { destinationURL in
          try TarArchiveEntryReader.extractFile(
            at: archiveURL,
            entry: entry,
            to: destinationURL,
            limits: limits)
        },
        consume: consume)
    case .gzip, .bzip2, .xz:
      try ArchiveExtractedFileReader.streamFile(
        entry: entry,
        chunkSize: chunkSize,
        maximumBytes: limits.maximumUncompressedBytes,
        extract: { destinationURL in
          try SingleFileArchiveEntryReader.extractFile(
            at: archiveURL,
            entry: entry,
            to: destinationURL,
            limits: limits)
        },
        consume: consume)
    }
  }

  static func extractFile(
    at archiveURL: URL,
    entry identity: ArchiveEntryIdentity,
    to destinationURL: URL,
    limits: ArchiveSafetyLimits
  ) throws {
    try extractFile(
      at: archiveURL,
      entry: identity,
      to: destinationURL,
      limits: limits,
      validateCompressionRatio: true)
  }

  private static func extractFile(
    at archiveURL: URL,
    entry identity: ArchiveEntryIdentity,
    to destinationURL: URL,
    limits: ArchiveSafetyLimits,
    validateCompressionRatio: Bool
  ) throws {
    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: destinationURL.path) else {
      throw CocoaError(.fileWriteFileExists)
    }
    try fileManager.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    do {
      let handle = try FileHandle(forWritingTo: destinationURL)
      do {
        try streamFile(
          at: archiveURL,
          entry: identity,
          chunkSize: 32 * 1_024,
          limits: limits,
          validateCompressionRatio: validateCompressionRatio
        ) { data in
          try handle.write(contentsOf: data)
        }
        try handle.close()
      } catch {
        try? handle.close()
        throw error
      }
    } catch {
      try? fileManager.removeItem(at: destinationURL)
      throw error
    }
  }

  static func streamFile(
    at archiveURL: URL,
    entry identity: ArchiveEntryIdentity,
    chunkSize: Int,
    limits: ArchiveSafetyLimits,
    consume: @escaping (Data) throws -> Void
  ) throws {
    try streamFile(
      at: archiveURL,
      entry: identity,
      chunkSize: chunkSize,
      limits: limits,
      validateCompressionRatio: true,
      consume: consume)
  }

  private static func streamFile(
    at archiveURL: URL,
    entry identity: ArchiveEntryIdentity,
    chunkSize: Int,
    limits: ArchiveSafetyLimits,
    validateCompressionRatio: Bool,
    consume: @escaping (Data) throws -> Void
  ) throws {
    guard chunkSize > 0 else { throw ArchiveFileProviderError.invalidExtractedSize }
    let (archive, entry) = try validatedEntry(
      at: archiveURL,
      identity: identity,
      limits: limits,
      validateCompressionRatio: validateCompressionRatio)
    try validateAndConsume(
      entry: identity,
      extract: { consumer in
        try archive.extract(entry, bufferSize: chunkSize, consumer: consumer)
      },
      consume: consume)
  }

  /// ZIPFoundationが申告サイズより多いデータを返した時点で、後続チャンクを処理せず停止する。
  /// 実Archiveとテスト用リーダー境界の両方が同じ逐次検証を通るための共通部。
  static func validateAndConsume(
    entry identity: ArchiveEntryIdentity,
    extract: (_ consumer: @escaping (Data) throws -> Void) throws -> UInt32,
    consume: @escaping (Data) throws -> Void
  ) throws {
    var extractedBytes: UInt64 = 0
    let checksum = try extract { data in
      try Task.checkCancellation()
      let (nextExtractedBytes, overflow) = extractedBytes.addingReportingOverflow(
        UInt64(data.count))
      guard !overflow, nextExtractedBytes <= identity.uncompressedSize else {
        throw ArchiveFileProviderError.invalidExtractedSize
      }
      extractedBytes = nextExtractedBytes
      try consume(data)
    }
    guard extractedBytes == identity.uncompressedSize else {
      throw ArchiveFileProviderError.invalidExtractedSize
    }
    if let expectedChecksum = identity.checksum {
      guard checksum == expectedChecksum else {
        throw ArchiveFileProviderError.archiveChanged
      }
    }
  }

  private static func validatedEntry(
    at archiveURL: URL,
    identity: ArchiveEntryIdentity,
    limits: ArchiveSafetyLimits,
    validateCompressionRatio: Bool
  ) throws -> (ZIPFoundation.Archive, ZIPFoundation.Entry) {
    let archive = try ZIPFoundation.Archive(url: archiveURL, accessMode: .read)
    let entries = Array(archive)
    // Archiveのsubscriptはフラグ依存の`path`で照合するため、indexが保存した
    // archivePath(アーカイブ単位で解決した名前)とは一致しないことがある。
    // 再オープンした全エントリから同じリゾルバを構築し、同じ解釈で探す。
    let resolver = ZipArchivePathResolver(entries: entries)
    guard let entry = entries.first(where: { resolver.path(for: $0) == identity.archivePath })
    else {
      throw ArchiveFileProviderError.archiveChanged
    }
    let safetyEntry = ArchiveSafetyEntry(entry, path: resolver.path(for: entry))
    if validateCompressionRatio {
      try ArchiveEntrySafety.validate(entry: safetyEntry, limits: limits, format: .zip)
    } else {
      try ArchiveEntrySafety.validateMetadata(
        entry: safetyEntry,
        limits: limits,
        format: .zip)
    }
    guard entry.type == .file,
      entry.uncompressedSize == identity.uncompressedSize,
      entry.compressedSize == identity.compressedSize
    else {
      throw ArchiveFileProviderError.archiveChanged
    }
    if let expectedChecksum = identity.checksum,
      entry.checksum != expectedChecksum
    {
      throw ArchiveFileProviderError.archiveChanged
    }
    return (archive, entry)
  }
}

enum SevenZipArchiveEntryReader {
  static func buildIndex(
    at archiveURL: URL,
    providerID: FileProviderID,
    limits: ArchiveSafetyLimits
  ) throws -> ArchiveIndex {
    let decoder = try openDecoder(at: archiveURL)
    let count = try decoder.count()
    guard count <= UInt64(limits.maximumEntryCount) else {
      throw ArchiveServiceError.tooManyEntries(.sevenZip)
    }
    guard let integerCount = Int(exactly: count) else {
      throw ArchiveServiceError.tooManyEntries(.sevenZip)
    }
    var descriptors: [ArchiveEntryDescriptor] = []
    var invalidEntryCount = 0
    descriptors.reserveCapacity(min(integerCount, limits.maximumEntryCount))

    for ordinal in 0..<integerCount {
      do {
        let item = try decoder.item(at: PLzmaSDK.Size(ordinal))
        guard !item.encrypted,
          let uncompressedSize = Int64(exactly: item.size),
          let compressedSize = Int64(exactly: item.packSize)
        else {
          invalidEntryCount += 1
          continue
        }
        let path = try item.path().description
        try ArchiveEntrySafety.validateMetadata(
          entry: ArchiveSafetyEntry(
            path: path,
            uncompressedSize: item.size,
            compressedSize: item.packSize,
            isSymbolicLink: false),
          limits: limits,
          format: .sevenZip)
        descriptors.append(
          ArchiveEntryDescriptor(
            rawPath: path,
            isDirectory: item.isDir,
            uncompressedSize: uncompressedSize,
            compressedSize: compressedSize,
            checksum: item.crc32,
            modificationDate: item.modificationDate,
            ordinal: ordinal))
      } catch {
        invalidEntryCount += 1
      }
    }

    let index = try ArchiveIndexBuilder.build(
      descriptors: descriptors,
      providerID: providerID,
      limits: limits,
      format: .sevenZip)
    return ArchiveIndex(
      entriesByPath: index.entriesByPath,
      childPathsByDirectory: index.childPathsByDirectory,
      invalidEntryCount: invalidEntryCount + index.invalidEntryCount)
  }

  static func extractFile(
    at archiveURL: URL,
    entry: ArchiveIndexedEntry,
    to destinationURL: URL,
    limits: ArchiveSafetyLimits
  ) throws {
    let decoder = try openDecoder(at: archiveURL)
    let count = try decoder.count()
    guard entry.ordinal >= 0, entry.ordinal < Int(count) else {
      throw ArchiveFileProviderError.archiveChanged
    }
    let item = try decoder.item(at: PLzmaSDK.Size(entry.ordinal))
    let path = try item.path().description
    guard !item.encrypted, !item.isDir,
      path == entry.archivePath,
      item.size == entry.uncompressedSize,
      item.packSize == entry.compressedSize,
      item.crc32 == entry.checksum
    else {
      throw ArchiveFileProviderError.archiveChanged
    }
    try ArchiveEntrySafety.validateMetadata(
      entry: ArchiveSafetyEntry(
        path: path,
        uncompressedSize: item.size,
        compressedSize: item.packSize,
        isSymbolicLink: false),
      limits: limits,
      format: .sevenZip)

    let fileManager = FileManager.default
    let extractionRoot = fileManager.temporaryDirectory.appending(
      path: "pkpane-sevenzip-entry-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? fileManager.removeItem(at: extractionRoot) }
    try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
    let items = try ItemArray(items: [item])
    guard
      try decoder.extract(
        items: items,
        to: PLzmaSDK.Path(extractionRoot.path),
        itemsFullPath: false)
    else {
      throw ArchiveServiceError.operationFailed(.sevenZip)
    }
    try SevenZipPostExtractionSafety.validateNoSymbolicLinks(in: extractionRoot)
    let extractedURL = extractionRoot.appending(path: entry.name)
    let actualSize = try extractedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
    guard actualSize.map(UInt64.init) == entry.uncompressedSize else {
      throw ArchiveFileProviderError.invalidExtractedSize
    }
    try fileManager.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    guard !fileManager.fileExists(atPath: destinationURL.path) else {
      throw CocoaError(.fileWriteFileExists)
    }
    try fileManager.moveItem(at: extractedURL, to: destinationURL)
  }

  private static func openDecoder(at archiveURL: URL) throws -> Decoder {
    let decoder = try Decoder(
      stream: try InStream(path: PLzmaSDK.Path(archiveURL.path)),
      fileType: .sevenZ)
    guard try decoder.open() else {
      throw ArchiveServiceError.operationFailed(.sevenZip)
    }
    return decoder
  }
}

enum RARArchiveEntryReader {
  static func buildIndex(
    at archiveURL: URL,
    providerID: FileProviderID,
    limits: ArchiveSafetyLimits
  ) throws -> ArchiveIndex {
    let (_, entries) = try RARArchiveReader.openValidated(at: archiveURL)
    guard entries.count <= limits.maximumEntryCount else {
      throw ArchiveServiceError.tooManyEntries(.rar)
    }
    var descriptors: [ArchiveEntryDescriptor] = []
    var invalidEntryCount = 0
    descriptors.reserveCapacity(min(entries.count, limits.maximumEntryCount))

    for (ordinal, entry) in entries.enumerated() {
      do {
        let path = RARPathNormalizer.normalized(entry.fileName)
        try ArchiveEntrySafety.validateMetadata(
          entry: ArchiveSafetyEntry(
            path: path,
            uncompressedSize: entry.uncompressedSize,
            compressedSize: entry.compressedSize,
            isSymbolicLink: false),
          limits: limits,
          format: .rar)
        guard let uncompressedSize = Int64(exactly: entry.uncompressedSize),
          let compressedSize = Int64(exactly: entry.compressedSize)
        else {
          invalidEntryCount += 1
          continue
        }
        descriptors.append(
          ArchiveEntryDescriptor(
            rawPath: path,
            isDirectory: entry.directory,
            uncompressedSize: uncompressedSize,
            compressedSize: compressedSize,
            checksum: entry.crc32,
            modificationDate: entry.modified,
            ordinal: ordinal))
      } catch {
        invalidEntryCount += 1
      }
    }

    let index = try ArchiveIndexBuilder.build(
      descriptors: descriptors,
      providerID: providerID,
      limits: limits,
      format: .rar)
    return ArchiveIndex(
      entriesByPath: index.entriesByPath,
      childPathsByDirectory: index.childPathsByDirectory,
      invalidEntryCount: invalidEntryCount + index.invalidEntryCount)
  }

  static func extractFile(
    at archiveURL: URL,
    entry indexedEntry: ArchiveIndexedEntry,
    to destinationURL: URL,
    limits: ArchiveSafetyLimits
  ) throws {
    let (archive, entries) = try RARArchiveReader.openValidated(at: archiveURL)
    guard entries.indices.contains(indexedEntry.ordinal) else {
      throw ArchiveFileProviderError.archiveChanged
    }
    let entry = entries[indexedEntry.ordinal]
    let path = RARPathNormalizer.normalized(entry.fileName)
    guard !entry.directory,
      path == indexedEntry.archivePath,
      entry.uncompressedSize == indexedEntry.uncompressedSize,
      entry.compressedSize == indexedEntry.compressedSize,
      entry.crc32 == indexedEntry.checksum
    else {
      throw ArchiveFileProviderError.archiveChanged
    }
    try ArchiveEntrySafety.validateMetadata(
      entry: ArchiveSafetyEntry(
        path: path,
        uncompressedSize: entry.uncompressedSize,
        compressedSize: entry.compressedSize,
        isSymbolicLink: false),
      limits: limits,
      format: .rar)

    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    do {
      let handle = try FileHandle(forWritingTo: destinationURL)
      defer { try? handle.close() }
      var writtenBytes: UInt64 = 0
      var handlerError: Error?
      do {
        try archive.extract(entry) { data, progress in
          guard handlerError == nil else {
            progress.cancel()
            return
          }
          do {
            try Task.checkCancellation()
            let (nextWrittenBytes, overflow) = writtenBytes.addingReportingOverflow(
              UInt64(data.count))
            guard !overflow,
              nextWrittenBytes <= indexedEntry.uncompressedSize,
              nextWrittenBytes <= limits.maximumUncompressedBytes
            else {
              throw ArchiveFileProviderError.invalidExtractedSize
            }
            try handle.write(contentsOf: data)
            writtenBytes = nextWrittenBytes
          } catch {
            handlerError = error
            progress.cancel()
          }
        }
      } catch {
        if let handlerError { throw handlerError }
        throw error
      }
      if let handlerError { throw handlerError }
      guard writtenBytes == indexedEntry.uncompressedSize else {
        throw ArchiveFileProviderError.invalidExtractedSize
      }
    } catch {
      try? fileManager.removeItem(at: destinationURL)
      throw error
    }
  }
}

enum TarArchiveEntryReader {
  static func buildIndex(
    at tarURL: URL,
    providerID: FileProviderID,
    limits: ArchiveSafetyLimits,
    format: ArchiveFormat
  ) throws -> ArchiveIndex {
    let fileSize = try tarURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard fileSize >= 0, UInt64(fileSize) <= limits.maximumUncompressedBytes else {
      throw ArchiveServiceError.tooLarge(format)
    }
    let tarData = try Data(contentsOf: tarURL, options: .mappedIfSafe)
    let entryInfos = try TarContainer.info(container: tarData)
    guard entryInfos.count <= limits.maximumEntryCount else {
      throw ArchiveServiceError.tooManyEntries(format)
    }
    var descriptors: [ArchiveEntryDescriptor] = []
    var invalidEntryCount = 0
    descriptors.reserveCapacity(min(entryInfos.count, limits.maximumEntryCount))

    for (ordinal, info) in entryInfos.enumerated() {
      do {
        let isDirectory: Bool
        switch info.type {
        case .regular:
          isDirectory = false
        case .directory:
          isDirectory = true
        case .symbolicLink, .hardLink, .fifo, .blockSpecial, .characterSpecial, .socket,
          .contiguous, .unknown:
          invalidEntryCount += 1
          continue
        }
        guard let size = info.size, size >= 0, let entrySize = Int64(exactly: size) else {
          invalidEntryCount += 1
          continue
        }
        let uncompressedSize = isDirectory ? UInt64.zero : UInt64(size)
        try ArchiveEntrySafety.validateMetadata(
          entry: ArchiveSafetyEntry(
            path: info.name,
            uncompressedSize: uncompressedSize,
            compressedSize: uncompressedSize,
            isSymbolicLink: false),
          limits: limits,
          format: format)
        descriptors.append(
          ArchiveEntryDescriptor(
            rawPath: info.name,
            isDirectory: isDirectory,
            uncompressedSize: isDirectory ? 0 : entrySize,
            compressedSize: isDirectory ? 0 : entrySize,
            checksum: nil,
            modificationDate: info.modificationTime,
            ordinal: ordinal))
      } catch {
        invalidEntryCount += 1
      }
    }

    let index = try ArchiveIndexBuilder.build(
      descriptors: descriptors,
      providerID: providerID,
      limits: limits,
      format: format)
    return ArchiveIndex(
      entriesByPath: index.entriesByPath,
      childPathsByDirectory: index.childPathsByDirectory,
      invalidEntryCount: invalidEntryCount + index.invalidEntryCount)
  }

  static func extractFile(
    at tarURL: URL,
    entry indexedEntry: ArchiveIndexedEntry,
    to destinationURL: URL,
    limits: ArchiveSafetyLimits
  ) throws {
    guard indexedEntry.ordinal >= 0, indexedEntry.declaredUncompressedSize != nil else {
      throw ArchiveFileProviderError.archiveChanged
    }
    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: destinationURL.path) else {
      throw CocoaError(.fileWriteFileExists)
    }
    try fileManager.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)

    let handle = try FileHandle(forReadingFrom: tarURL)
    defer { try? handle.close() }
    var reader = TarReader(fileHandle: handle)
    var ordinal = 0
    do {
      while true {
        try Task.checkCancellation()
        let outcome = try reader.process { tarEntry -> TarReadOutcome in
          guard let tarEntry else { return .end }
          defer { ordinal += 1 }
          guard ordinal == indexedEntry.ordinal else { return .next }
          guard case .regular = tarEntry.info.type,
            tarEntry.info.name == indexedEntry.archivePath,
            let declaredSize = tarEntry.info.size,
            declaredSize >= 0,
            UInt64(declaredSize) == indexedEntry.uncompressedSize,
            indexedEntry.compressedSize == indexedEntry.uncompressedSize,
            indexedEntry.checksum == nil,
            let data = tarEntry.data,
            UInt64(data.count) == indexedEntry.uncompressedSize
          else {
            throw ArchiveFileProviderError.archiveChanged
          }
          try ArchiveEntrySafety.validateMetadata(
            entry: ArchiveSafetyEntry(
              path: tarEntry.info.name,
              uncompressedSize: indexedEntry.uncompressedSize,
              compressedSize: indexedEntry.uncompressedSize,
              isSymbolicLink: false),
            limits: limits,
            format: indexedEntry.format)
          guard fileManager.createFile(atPath: destinationURL.path, contents: data) else {
            throw CocoaError(.fileWriteUnknown)
          }
          return .finished
        }
        switch outcome {
        case .next:
          continue
        case .finished:
          return
        case .end:
          throw ArchiveFileProviderError.archiveChanged
        }
      }
    } catch {
      try? fileManager.removeItem(at: destinationURL)
      throw error
    }
  }

  private enum TarReadOutcome {
    case next
    case finished
    case end
  }
}

enum SingleFileArchiveEntryReader {
  static func buildIndex(
    at archiveURL: URL,
    providerID: FileProviderID,
    limits: ArchiveSafetyLimits,
    format: ArchiveFormat
  ) throws -> ArchiveIndex {
    let fileSize = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard fileSize >= 0, UInt64(fileSize) <= limits.maximumUncompressedBytes,
      let compressedSize = Int64(exactly: fileSize)
    else {
      throw ArchiveServiceError.tooLarge(format)
    }
    let descriptor = ArchiveEntryDescriptor(
      rawPath: format.baseName(for: archiveURL),
      isDirectory: false,
      uncompressedSize: nil,
      compressedSize: compressedSize,
      checksum: nil,
      modificationDate: nil,
      ordinal: 0)
    return try ArchiveIndexBuilder.build(
      descriptors: [descriptor],
      providerID: providerID,
      limits: limits,
      format: format)
  }

  static func extractFile(
    at archiveURL: URL,
    entry: ArchiveIndexedEntry,
    to destinationURL: URL,
    limits: ArchiveSafetyLimits
  ) throws {
    let fileSize = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard fileSize >= 0,
      UInt64(fileSize) == entry.compressedSize,
      entry.ordinal == 0,
      !entry.isDirectory,
      entry.archivePath == entry.format.baseName(for: archiveURL),
      entry.declaredUncompressedSize == nil
    else {
      throw ArchiveFileProviderError.archiveChanged
    }
    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: destinationURL.path) else {
      throw CocoaError(.fileWriteFileExists)
    }
    try fileManager.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    do {
      let result = try StreamingArchiveDecoder.decompress(
        at: archiveURL,
        to: destinationURL,
        format: entry.format,
        limits: limits.archiveBrowsingExtractionLimits,
        cancellationProgress: Progress(totalUnitCount: 1))
      guard result.compressedBytes == entry.compressedSize else {
        throw ArchiveFileProviderError.archiveChanged
      }
      try ArchiveEntrySafety.validateMetadata(
        entry: ArchiveSafetyEntry(
          path: entry.archivePath,
          uncompressedSize: result.uncompressedBytes,
          compressedSize: result.compressedBytes,
          isSymbolicLink: false),
        limits: limits,
        format: entry.format)
    } catch {
      try? fileManager.removeItem(at: destinationURL)
      throw error
    }
  }
}

private enum CompressedTarArchiveStager {
  static func stage(
    archiveURL: URL,
    format: ArchiveFormat,
    limits: ArchiveSafetyLimits,
    budget: ArchiveStagingBudget
  ) throws -> ArchiveProviderTemporaryFile {
    let temporaryURL = FileManager.default.temporaryDirectory.appending(
      path: "pkpane-compressed-tar-\(UUID().uuidString).tar")
    var preservesTemporaryFile = false
    defer {
      if !preservesTemporaryFile {
        try? FileManager.default.removeItem(at: temporaryURL)
      }
    }
    let result = try StreamingArchiveDecoder.decompress(
      at: archiveURL,
      to: temporaryURL,
      format: format,
      limits: limits.archiveBrowsingExtractionLimits,
      cancellationProgress: Progress(totalUnitCount: 1))
    let reservation = try budget.reserve(bytes: result.uncompressedBytes)
    preservesTemporaryFile = true
    return ArchiveProviderTemporaryFile(url: temporaryURL, reservation: reservation)
  }
}

private final class ArchiveProviderTemporaryFile: @unchecked Sendable {
  let url: URL
  private let reservation: ArchiveStagingReservation

  init(url: URL, reservation: ArchiveStagingReservation) {
    self.url = url
    self.reservation = reservation
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}

final class ArchiveStagingBudget: @unchecked Sendable {
  static let shared = ArchiveStagingBudget(maximumBytes: ArchiveExtractionCache.maximumBytes)

  private let maximumBytes: UInt64
  private let lock = NSLock()
  private var reservations: [UUID: UInt64] = [:]
  private var totalBytes: UInt64 = 0

  init(maximumBytes: UInt64) {
    self.maximumBytes = maximumBytes
  }

  var usedBytes: UInt64 {
    lock.withLock { totalBytes }
  }

  fileprivate func reserve(bytes: UInt64) throws -> ArchiveStagingReservation {
    let identifier = UUID()
    try lock.withLock {
      guard bytes <= maximumBytes, totalBytes <= maximumBytes - bytes else {
        throw ArchiveFileProviderError.stagingCapacityExceeded
      }
      totalBytes += bytes
      reservations[identifier] = bytes
    }
    return ArchiveStagingReservation(identifier: identifier, budget: self)
  }

  fileprivate func release(identifier: UUID) {
    lock.withLock {
      guard let bytes = reservations.removeValue(forKey: identifier) else { return }
      totalBytes -= bytes
    }
  }
}

private final class ArchiveStagingReservation: @unchecked Sendable {
  private let identifier: UUID
  private let budget: ArchiveStagingBudget

  init(identifier: UUID, budget: ArchiveStagingBudget) {
    self.identifier = identifier
    self.budget = budget
  }

  deinit {
    budget.release(identifier: identifier)
  }
}

extension ArchiveSafetyLimits {
  fileprivate var archiveBrowsingExtractionLimits: ArchiveSafetyLimits {
    ArchiveSafetyLimits(
      maximumEntryCount: maximumEntryCount,
      maximumUncompressedBytes: min(
        maximumUncompressedBytes,
        ArchiveExtractionCache.maximumBytes),
      maximumCompressionRatio: maximumCompressionRatio)
  }
}

enum ArchiveExtractedFileReader {
  static func streamFile(
    entry: ArchiveIndexedEntry,
    chunkSize: Int,
    maximumBytes: UInt64 = .max,
    extract: (URL) throws -> Void,
    consume: (Data) throws -> Void
  ) throws {
    guard chunkSize > 0 else { throw ArchiveFileProviderError.invalidExtractedSize }
    let temporaryURL = FileManager.default.temporaryDirectory.appending(
      path: "pkpane-archive-stream-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    try extract(temporaryURL)
    let handle = try FileHandle(forReadingFrom: temporaryURL)
    defer { try? handle.close() }
    var consumedBytes: UInt64 = 0
    while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
      try Task.checkCancellation()
      let (nextConsumedBytes, overflow) = consumedBytes.addingReportingOverflow(UInt64(data.count))
      guard !overflow, nextConsumedBytes <= maximumBytes,
        entry.declaredUncompressedSize.map({ nextConsumedBytes <= $0 }) ?? true
      else {
        throw ArchiveFileProviderError.invalidExtractedSize
      }
      consumedBytes = nextConsumedBytes
      try consume(data)
    }
    guard entry.declaredUncompressedSize.map({ consumedBytes == $0 }) ?? true else {
      throw ArchiveFileProviderError.invalidExtractedSize
    }
  }
}

actor ArchiveExtractionCache {
  struct Key: Hashable, Sendable {
    let providerID: FileProviderID
    let entryPath: String
  }

  static let maximumBytes: UInt64 = 512 * 1_024 * 1_024
  static let shared = ArchiveExtractionCache()

  private struct CachedFile {
    let url: URL
    let size: UInt64
    var lastAccess: UInt64
  }

  private struct PreparedExtraction: Sendable {
    let temporaryURL: URL
    let destinationURL: URL
    let size: UInt64
  }

  private struct InFlightExtraction {
    let token: UUID
    let task: Task<PreparedExtraction, Error>
  }

  private let rootURL: URL
  private let sizeLimit: UInt64
  private var files: [Key: CachedFile] = [:]
  private var totalBytes: UInt64 = 0
  private var accessSequence: UInt64 = 0
  private var inFlightExtractions: [Key: InFlightExtraction] = [:]

  init(rootURL: URL? = nil, maximumBytes: UInt64 = ArchiveExtractionCache.maximumBytes) {
    self.rootURL = rootURL ?? Self.defaultRootURL()
    sizeLimit = maximumBytes
    try? FileManager.default.removeItem(at: self.rootURL)
  }

  func cachedURL(
    for key: Key,
    fileName: String,
    expectedSize: UInt64?,
    extract: @escaping @Sendable (URL) throws -> Void
  ) async throws -> URL {
    guard expectedSize.map({ $0 <= sizeLimit }) ?? true else {
      throw ArchiveFileProviderError.entryTooLarge(fileName)
    }
    if let cachedURL = touchCachedURL(for: key) {
      return cachedURL
    }
    removeRecord(for: key)
    let inFlight: InFlightExtraction
    if let existing = inFlightExtractions[key] {
      inFlight = existing
    } else {
      let token = UUID()
      let rootURL = rootURL
      let sizeLimit = sizeLimit
      let fileExtension = (fileName as NSString).pathExtension
      let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
      let destinationURL = rootURL.appending(path: "\(UUID().uuidString)\(suffix)")
      let temporaryURL = rootURL.appending(path: ".\(UUID().uuidString).tmp")
      let task = Task.detached(priority: .userInitiated) {
        do {
          try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true)
          try extract(temporaryURL)
          try Task.checkCancellation()
          let actualSize = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
          guard let actualSize, actualSize >= 0 else {
            throw ArchiveFileProviderError.invalidExtractedSize
          }
          let extractedSize = UInt64(actualSize)
          guard expectedSize.map({ $0 == extractedSize }) ?? true else {
            throw ArchiveFileProviderError.invalidExtractedSize
          }
          guard extractedSize <= sizeLimit else {
            throw ArchiveFileProviderError.entryTooLarge(fileName)
          }
          return PreparedExtraction(
            temporaryURL: temporaryURL,
            destinationURL: destinationURL,
            size: extractedSize)
        } catch {
          try? FileManager.default.removeItem(at: temporaryURL)
          throw error
        }
      }
      inFlight = InFlightExtraction(token: token, task: task)
      inFlightExtractions[key] = inFlight
    }
    let prepared: PreparedExtraction
    do {
      prepared = try await inFlight.task.value
    } catch {
      clearInFlightExtraction(for: key, matching: inFlight.token)
      throw error
    }
    defer { try? FileManager.default.removeItem(at: prepared.temporaryURL) }
    if let cachedURL = touchCachedURL(for: key) {
      return cachedURL
    }
    guard inFlightExtractions[key]?.token == inFlight.token else {
      throw CancellationError()
    }
    defer { clearInFlightExtraction(for: key, matching: inFlight.token) }
    try makeSpace(for: prepared.size)
    try FileManager.default.moveItem(
      at: prepared.temporaryURL,
      to: prepared.destinationURL)
    accessSequence &+= 1
    files[key] = CachedFile(
      url: prepared.destinationURL,
      size: prepared.size,
      lastAccess: accessSequence)
    totalBytes += prepared.size
    return prepared.destinationURL
  }

  func removeAll() async {
    let tasks = inFlightExtractions.values.map(\.task)
    inFlightExtractions.removeAll()
    for task in tasks {
      task.cancel()
    }
    for task in tasks {
      _ = try? await task.value
    }
    files.removeAll()
    totalBytes = 0
    try? FileManager.default.removeItem(at: rootURL)
  }

  /// テストランナー(XCTest/Swift Testing)内では実ユーザーのApplication Supportへ
  /// 絶対に書き込まない。プロセスIDを含めた一時パスへ切り替え、並列テスト間の
  /// 相互干渉と実ファイル汚染を断つ(JSONTransferJobStore.defaultURLと同じ方針)。
  static func defaultRootURL(environment: [String: String] = ProcessInfo.processInfo.environment)
    -> URL
  {
    if TestEnvironmentDetector.isRunningTests(environment: environment) {
      return FileManager.default.temporaryDirectory
        .appending(path: "pkpane-tests", directoryHint: .isDirectory)
        .appending(
          path: "archive-previews-\(ProcessInfo.processInfo.processIdentifier)",
          directoryHint: .isDirectory)
    }
    let directory =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return directory.appending(path: "PKPane/ArchivePreviews", directoryHint: .isDirectory)
  }

  nonisolated static func removeDefaultCacheDirectory() {
    try? FileManager.default.removeItem(at: defaultRootURL())
  }

  private func makeSpace(for expectedSize: UInt64) throws {
    while totalBytes > sizeLimit - expectedSize,
      let oldest = files.min(by: { $0.value.lastAccess < $1.value.lastAccess })
    {
      removeRecord(for: oldest.key)
    }
  }

  private func touchCachedURL(for key: Key) -> URL? {
    guard var cached = files[key], FileManager.default.fileExists(atPath: cached.url.path) else {
      return nil
    }
    accessSequence &+= 1
    cached.lastAccess = accessSequence
    files[key] = cached
    return cached.url
  }

  private func clearInFlightExtraction(for key: Key, matching token: UUID) {
    guard inFlightExtractions[key]?.token == token else { return }
    inFlightExtractions[key] = nil
  }

  private func removeRecord(for key: Key) {
    guard let removed = files.removeValue(forKey: key) else { return }
    totalBytes = totalBytes >= removed.size ? totalBytes - removed.size : 0
    try? FileManager.default.removeItem(at: removed.url)
  }
}

enum ArchiveVirtualPath {
  static func normalized(_ path: String) -> String {
    let components = components(of: path)
    return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
  }

  static func components(of path: String) -> [String] {
    path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
  }

  static func parent(of path: String) -> String {
    let parentComponents = components(of: path).dropLast()
    return parentComponents.isEmpty ? "/" : "/" + parentComponents.joined(separator: "/")
  }

  static func name(of path: String) -> String {
    components(of: path).last ?? ""
  }

  static func itemURL(providerToken: String, path: String) -> URL {
    var components = URLComponents()
    components.scheme = "pkpane-archive"
    components.host = providerToken.replacingOccurrences(of: ":", with: "-")
    components.path = normalized(path)
    return components.url!
  }
}
