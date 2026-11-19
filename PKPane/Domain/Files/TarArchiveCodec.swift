import Foundation
import SWCompression

struct TarArchiveCodec: ArchiveCodec {
  let format: ArchiveFormat
  private let streamingConfiguration: StreamingDecompressionConfiguration

  init(
    format: ArchiveFormat,
    streamingConfiguration: StreamingDecompressionConfiguration = .default
  ) {
    self.format = format
    self.streamingConfiguration = streamingConfiguration
  }

  func createArchive(
    from sourceURLs: [URL],
    to destinationURL: URL,
    cancellationProgress: Progress,
    progress: @escaping @Sendable (ArchiveProgress) -> Void
  ) throws {
    throw ArchiveServiceError.unsupportedFormat(format.fileExtension)
  }

  func extractArchive(
    at archiveURL: URL,
    to destinationURL: URL,
    limits: ArchiveSafetyLimits,
    cancellationProgress: Progress,
    progress: @escaping @Sendable (ArchiveProgress) -> Void
  ) throws {
    do {
      try ArchiveCancellation.check(cancellationProgress)
      let tarURL = try decompressedTarURL(
        from: archiveURL,
        to: destinationURL,
        limits: limits,
        cancellationProgress: cancellationProgress)
      defer {
        if tarURL != archiveURL {
          try? FileManager.default.removeItem(at: tarURL)
        }
      }
      // SWCompression 4.0.0にはtarの逐次読みAPIがない。圧縮tarは上の解除中、
      // plain tarはファイルサイズ検査で上限を保証したうえで、Dataはファイルマップする。
      let tarData = try Data(contentsOf: tarURL, options: .mappedIfSafe)
      try ArchiveCancellation.check(cancellationProgress)
      guard UInt64(tarData.count) <= limits.maximumUncompressedBytes else {
        throw ArchiveServiceError.tooLarge(format)
      }
      let entries = try TarContainer.open(container: tarData)
      let archiveSize = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      let compressedSize = UInt64(max(archiveSize, 0))
      let safetyEntries = try entries.enumerated().map { index, entry in
        try validateSupportedEntryType(entry.info.type, path: entry.info.name)
        return ArchiveSafetyEntry(
          path: entry.info.name,
          uncompressedSize: UInt64(max(entry.info.size ?? 0, 0)),
          compressedSize: index == 0 ? compressedSize : 0,
          isSymbolicLink: false)
      }
      try ArchiveEntrySafety.validate(
        entries: safetyEntries,
        limits: limits,
        compressionAccounting: .aggregate,
        format: format)

      let outputURLs = try entries.map {
        try ArchiveEntrySafety.outputURL(for: $0.info.name, in: destinationURL, format: format)
      }
      guard Set(outputURLs.map(\.path)).count == outputURLs.count else {
        throw ArchiveServiceError.duplicateEntryPath("同じ展開先", format)
      }
      try ArchivePreExtractionSafety.prepareDirectories(
        for: outputURLs,
        in: destinationURL,
        format: format)
      try createEntryDirectories(
        entries: entries,
        outputURLs: outputURLs)

      let totalBytes = safetyEntries.reduce(Int64.zero) {
        $0 + Int64(clamping: $1.uncompressedSize)
      }
      let reporter = ArchiveProgressReporter(totalBytes: totalBytes, handler: progress)
      for (entry, outputURL) in zip(entries, outputURLs) {
        try ArchiveCancellation.check(cancellationProgress)
        guard !isDirectory(entry.info.type) else { continue }
        guard let data = entry.data else {
          throw ArchiveServiceError.operationFailed(format)
        }
        try ArchiveDataWriter.write(
          data,
          to: outputURL,
          format: format,
          cancellationProgress: cancellationProgress,
          reporter: reporter)
      }
      reporter.finish()
    } catch let error as ArchiveServiceError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if cancellationProgress.isCancelled || Task.isCancelled {
        throw CancellationError()
      }
      throw ArchiveServiceError.operationFailed(format)
    }
  }

  private func decompressedTarURL(
    from archiveURL: URL,
    to destinationURL: URL,
    limits: ArchiveSafetyLimits,
    cancellationProgress: Progress
  ) throws -> URL {
    switch format {
    case .tar:
      let fileSize = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard UInt64(max(fileSize, 0)) <= limits.maximumUncompressedBytes else {
        throw ArchiveServiceError.tooLarge(format)
      }
      return archiveURL
    case .tarGzip, .tarBzip2, .tarXz:
      let temporaryURL = destinationURL.appending(
        path: ".pkpane-tar-\(UUID().uuidString).tar")
      do {
        _ = try StreamingArchiveDecoder.decompress(
          at: archiveURL,
          to: temporaryURL,
          format: format,
          limits: limits,
          cancellationProgress: cancellationProgress,
          configuration: streamingConfiguration)
        return temporaryURL
      } catch {
        try? FileManager.default.removeItem(at: temporaryURL)
        throw error
      }
    case .zip, .sevenZip, .gzip, .bzip2, .xz, .rar:
      throw ArchiveServiceError.unsupportedFormat(format.fileExtension)
    }
  }

  private func createEntryDirectories(
    entries: [TarEntry],
    outputURLs: [URL]
  ) throws {
    let directories = zip(entries, outputURLs)
      .filter { isDirectory($0.0.info.type) }
      .sorted { $0.1.pathComponents.count < $1.1.pathComponents.count }
    for (entry, outputURL) in directories {
      try ArchivePreExtractionSafety.ensureActualDirectory(
        outputURL,
        relativePath: entry.info.name,
        format: format)
    }
  }

  private func validateSupportedEntryType(
    _ type: ContainerEntryType,
    path: String
  ) throws {
    switch type {
    case .regular, .directory:
      return
    case .symbolicLink:
      throw ArchiveServiceError.symbolicLinkEntry(path, format)
    case .hardLink:
      throw ArchiveServiceError.unsupportedArchiveEntry(path, .hardLink, format)
    case .fifo:
      throw ArchiveServiceError.unsupportedArchiveEntry(path, .fifo, format)
    case .blockSpecial:
      throw ArchiveServiceError.unsupportedArchiveEntry(path, .blockDevice, format)
    case .characterSpecial:
      throw ArchiveServiceError.unsupportedArchiveEntry(path, .characterDevice, format)
    case .socket:
      throw ArchiveServiceError.unsupportedArchiveEntry(path, .socket, format)
    case .contiguous:
      throw ArchiveServiceError.unsupportedArchiveEntry(path, .contiguousFile, format)
    case .unknown:
      throw ArchiveServiceError.unsupportedArchiveEntry(path, .unknown, format)
    }
  }

  private func isDirectory(_ type: ContainerEntryType) -> Bool {
    if case .directory = type { return true }
    return false
  }
}
