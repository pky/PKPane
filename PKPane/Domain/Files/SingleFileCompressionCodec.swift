import Foundation

struct SingleFileCompressionCodec: ArchiveCodec {
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
      let outputName = format.baseName(for: archiveURL)
      let outputURL = try ArchiveEntrySafety.outputURL(
        for: outputName,
        in: destinationURL,
        format: format)
      try ArchivePreExtractionSafety.prepareDirectories(
        for: [outputURL],
        in: destinationURL,
        format: format)
      let temporaryURL = destinationURL.appending(
        path: ".pkpane-decompression-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: temporaryURL) }

      let result = try StreamingArchiveDecoder.decompress(
        at: archiveURL,
        to: temporaryURL,
        format: format,
        limits: limits,
        cancellationProgress: cancellationProgress,
        configuration: streamingConfiguration,
        inputProgress: { completedBytes, totalBytes in
          progress(
            ArchiveProgress(
              completedBytes: Int64(clamping: completedBytes),
              totalBytes: Int64(clamping: totalBytes)))
        })
      let safetyEntry = ArchiveSafetyEntry(
        path: outputName,
        uncompressedSize: result.uncompressedBytes,
        compressedSize: result.compressedBytes,
        isSymbolicLink: false)
      try ArchiveEntrySafety.validate(entry: safetyEntry, limits: limits, format: format)
      try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
      progress(
        ArchiveProgress(
          completedBytes: Int64(clamping: result.compressedBytes),
          totalBytes: Int64(clamping: result.compressedBytes)))
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
}

enum ArchiveDataWriter {
  static func write(
    _ data: Data,
    to outputURL: URL,
    format: ArchiveFormat,
    cancellationProgress: Progress,
    reporter: ArchiveProgressReporter
  ) throws {
    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
      throw ArchiveServiceError.operationFailed(format)
    }
    let handle = try FileHandle(forWritingTo: outputURL)
    defer { try? handle.close() }
    reporter.beginEntry(size: Int64(data.count))
    let chunkSize = 1_024 * 1_024
    var index = data.startIndex
    var completedBytes = 0
    while index < data.endIndex {
      try ArchiveCancellation.check(cancellationProgress)
      let byteCount = min(chunkSize, data.distance(from: index, to: data.endIndex))
      let endIndex = data.index(index, offsetBy: byteCount)
      try handle.write(contentsOf: data[index..<endIndex])
      index = endIndex
      completedBytes += byteCount
      reporter.report(entryCompletedBytes: Int64(completedBytes))
    }
    reporter.completeEntry()
  }
}

enum ArchiveCancellation {
  static func check(_ cancellationProgress: Progress) throws {
    guard !cancellationProgress.isCancelled else { throw CancellationError() }
    try Task.checkCancellation()
  }
}
