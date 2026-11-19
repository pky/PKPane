import CryptoKit
import Foundation

enum RemotePreviewCacheError: Error {
  case fileTooLarge
}

actor RemotePreviewCache {
  struct Key: Hashable, Sendable {
    let connectionID: FileProviderConnectionID
    let remotePath: String
    let modifiedAt: Date?
    let size: Int64?

    var digest: String {
      let modifiedBits = modifiedAt.map { String($0.timeIntervalSince1970.bitPattern) } ?? "nil"
      let input =
        "\(connectionID.rawValue)\u{0}\(remotePath)\u{0}\(modifiedBits)\u{0}\(size.map(String.init) ?? "nil")"
      return SHA256.hash(data: Data(input.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    }
  }

  static let maximumBytes: UInt64 = 256 * 1_024 * 1_024
  static let maximumFileBytes: UInt64 = 16 * 1_024 * 1_024
  static let shared = RemotePreviewCache()

  private struct CachedFile {
    let url: URL
    let size: UInt64
    var lastAccess: UInt64
  }

  private struct PreparedPreview: Sendable {
    let temporaryURL: URL
    let destinationURL: URL
    let size: UInt64
  }

  private struct InFlightPreview {
    let token: UUID
    let task: Task<PreparedPreview, Error>
  }

  private let rootURL: URL
  private let legacyRootURL: URL
  private let sizeLimit: UInt64
  private let fileSizeLimit: UInt64
  private var files: [String: CachedFile] = [:]
  private var totalBytes: UInt64 = 0
  private var accessSequence: UInt64 = 0
  private var inFlightPreviews: [String: InFlightPreview] = [:]
  private var isPrepared = false

  init(
    rootURL: URL? = nil,
    legacyRootURL: URL? = nil,
    maximumBytes: UInt64 = RemotePreviewCache.maximumBytes,
    maximumFileBytes: UInt64 = RemotePreviewCache.maximumFileBytes
  ) {
    self.rootURL = rootURL ?? Self.defaultRootURL()
    self.legacyRootURL = legacyRootURL ?? Self.defaultLegacyRootURL
    sizeLimit = maximumBytes
    fileSizeLimit = maximumFileBytes
  }

  func prepare() {
    guard !isPrepared else { return }
    isPrepared = true
    try? FileManager.default.removeItem(at: legacyRootURL)
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
        options: [])
    else {
      return
    }

    var discovered: [(digest: String, url: URL, size: UInt64, modifiedAt: Date)] = []
    for url in urls {
      guard
        let digest = Self.digest(fromCacheFileName: url.lastPathComponent),
        let values = try? url.resourceValues(forKeys: [
          .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ]),
        values.isRegularFile == true,
        let fileSize = values.fileSize,
        fileSize >= 0,
        UInt64(fileSize) <= fileSizeLimit
      else {
        try? FileManager.default.removeItem(at: url)
        continue
      }
      discovered.append(
        (digest, url, UInt64(fileSize), values.contentModificationDate ?? .distantPast))
    }

    for file in discovered.sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
      if files[file.digest] != nil {
        removeRecord(for: file.digest)
      }
      accessSequence &+= 1
      files[file.digest] = CachedFile(
        url: file.url,
        size: file.size,
        lastAccess: accessSequence)
      totalBytes += file.size
    }
    makeSpaceForExistingFiles()
  }

  func cachedURL(
    for key: Key,
    fileName: String,
    load: @escaping @Sendable () async throws -> Data
  ) async throws -> URL {
    prepare()
    let digest = key.digest
    if let cachedURL = touchCachedURL(for: digest) {
      return cachedURL
    }
    removeRecord(for: digest)

    let inFlight: InFlightPreview
    if let existing = inFlightPreviews[digest] {
      inFlight = existing
    } else {
      let token = UUID()
      let rootURL = rootURL
      let suffix = Self.safeExtensionSuffix(for: fileName)
      let destinationURL = rootURL.appending(path: "\(digest)\(suffix)")
      let temporaryURL = rootURL.appending(path: ".\(UUID().uuidString).tmp")
      let fileSizeLimit = min(fileSizeLimit, sizeLimit)
      let task = Task.detached(priority: .userInitiated) {
        do {
          let data = try await load()
          guard UInt64(data.count) <= fileSizeLimit else {
            throw RemotePreviewCacheError.fileTooLarge
          }
          try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true)
          try data.write(to: temporaryURL, options: .atomic)
          try Task.checkCancellation()
          return PreparedPreview(
            temporaryURL: temporaryURL,
            destinationURL: destinationURL,
            size: UInt64(data.count))
        } catch {
          try? FileManager.default.removeItem(at: temporaryURL)
          throw error
        }
      }
      inFlight = InFlightPreview(token: token, task: task)
      inFlightPreviews[digest] = inFlight
    }

    let prepared: PreparedPreview
    do {
      prepared = try await inFlight.task.value
    } catch {
      clearInFlightPreview(for: digest, matching: inFlight.token)
      throw error
    }
    defer { try? FileManager.default.removeItem(at: prepared.temporaryURL) }
    if let cachedURL = touchCachedURL(for: digest) {
      return cachedURL
    }
    guard inFlightPreviews[digest]?.token == inFlight.token else {
      throw CancellationError()
    }
    defer { clearInFlightPreview(for: digest, matching: inFlight.token) }
    makeSpace(for: prepared.size)
    try? FileManager.default.removeItem(at: prepared.destinationURL)
    try FileManager.default.moveItem(
      at: prepared.temporaryURL,
      to: prepared.destinationURL)
    accessSequence &+= 1
    files[digest] = CachedFile(
      url: prepared.destinationURL,
      size: prepared.size,
      lastAccess: accessSequence)
    totalBytes += prepared.size
    touchModificationDate(of: prepared.destinationURL)
    return prepared.destinationURL
  }

  /// 既存エントリだけを照会し、未命中時は読み込みやin-flight作成を一切行わない。
  func cachedURLIfPresent(for key: Key) -> URL? {
    prepare()
    let digest = key.digest
    guard let cachedURL = touchCachedURL(for: digest) else {
      removeRecord(for: digest)
      return nil
    }
    return cachedURL
  }

  func removeAll() async {
    let tasks = inFlightPreviews.values.map(\.task)
    inFlightPreviews.removeAll()
    for task in tasks {
      task.cancel()
    }
    for task in tasks {
      _ = try? await task.value
    }
    files.removeAll()
    totalBytes = 0
    try? FileManager.default.removeItem(at: rootURL)
    isPrepared = true
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
          path: "remote-previews-\(ProcessInfo.processInfo.processIdentifier)",
          directoryHint: .isDirectory)
    }
    let directory =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return directory.appending(path: "PKPane/RemotePreviews", directoryHint: .isDirectory)
  }

  static var defaultLegacyRootURL: URL {
    FileManager.default.temporaryDirectory
      .appending(path: "PKPanePreview", directoryHint: .isDirectory)
  }

  private func touchCachedURL(for digest: String) -> URL? {
    guard var cached = files[digest], FileManager.default.fileExists(atPath: cached.url.path) else {
      return nil
    }
    accessSequence &+= 1
    cached.lastAccess = accessSequence
    files[digest] = cached
    touchModificationDate(of: cached.url)
    return cached.url
  }

  private func touchModificationDate(of url: URL) {
    try? FileManager.default.setAttributes(
      [.modificationDate: Date()],
      ofItemAtPath: url.path)
  }

  private func makeSpace(for expectedSize: UInt64) {
    while totalBytes > sizeLimit - expectedSize,
      let oldest = files.min(by: { $0.value.lastAccess < $1.value.lastAccess })
    {
      removeRecord(for: oldest.key)
    }
  }

  private func makeSpaceForExistingFiles() {
    while totalBytes > sizeLimit,
      let oldest = files.min(by: { $0.value.lastAccess < $1.value.lastAccess })
    {
      removeRecord(for: oldest.key)
    }
  }

  private func clearInFlightPreview(for digest: String, matching token: UUID) {
    guard inFlightPreviews[digest]?.token == token else { return }
    inFlightPreviews[digest] = nil
  }

  private func removeRecord(for digest: String) {
    guard let removed = files.removeValue(forKey: digest) else { return }
    totalBytes = totalBytes >= removed.size ? totalBytes - removed.size : 0
    try? FileManager.default.removeItem(at: removed.url)
  }

  private static func safeExtensionSuffix(for fileName: String) -> String {
    let fileExtension = (fileName as NSString).pathExtension.lowercased()
    guard isValidExtension(fileExtension) else {
      return ""
    }
    return ".\(fileExtension)"
  }

  private static func digest(fromCacheFileName fileName: String) -> String? {
    let components = fileName.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 1 || components.count == 2 else { return nil }
    let digest = String(components[0])
    guard
      digest.count == 64,
      digest.unicodeScalars.allSatisfy({
        (48...57).contains($0.value) || (97...102).contains($0.value)
      }),
      components.count == 1 || isValidExtension(String(components[1]))
    else {
      return nil
    }
    return digest
  }

  private static func isValidExtension(_ fileExtension: String) -> Bool {
    !fileExtension.isEmpty
      && fileExtension.count <= 16
      && fileExtension.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
  }
}
