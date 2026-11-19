import Foundation
import Unrar

struct RARArchiveCodec: ArchiveCodec {
  func createArchive(
    from sourceURLs: [URL],
    to destinationURL: URL,
    cancellationProgress: Progress,
    progress: @escaping @Sendable (ArchiveProgress) -> Void
  ) throws {
    throw ArchiveServiceError.unsupportedFormat(ArchiveFormat.rar.fileExtension)
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
      let (archive, entries) = try RARArchiveReader.openValidated(at: archiveURL)

      let archiveSize = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      let normalizedPaths = entries.map { RARPathNormalizer.normalized($0.fileName) }
      let safetyEntries = entries.enumerated().map { index, entry in
        ArchiveSafetyEntry(
          path: normalizedPaths[index],
          uncompressedSize: entry.uncompressedSize,
          compressedSize: index == 0 ? UInt64(max(archiveSize, 0)) : 0,
          isSymbolicLink: false)
      }
      try ArchiveEntrySafety.validate(
        entries: safetyEntries,
        limits: limits,
        compressionAccounting: .aggregate,
        format: .rar)

      let outputURLs = try normalizedPaths.map {
        try ArchiveEntrySafety.outputURL(for: $0, in: destinationURL, format: .rar)
      }
      guard Set(outputURLs.map(\.path)).count == outputURLs.count else {
        throw ArchiveServiceError.duplicateEntryPath("同じ展開先", .rar)
      }
      try ArchivePreExtractionSafety.prepareDirectories(
        for: outputURLs,
        in: destinationURL,
        format: .rar)
      try createEntryDirectories(
        entries: entries,
        normalizedPaths: normalizedPaths,
        outputURLs: outputURLs)

      let totalBytes = safetyEntries.reduce(Int64.zero) {
        $0 + Int64(clamping: $1.uncompressedSize)
      }
      let reporter = ArchiveProgressReporter(totalBytes: totalBytes, handler: progress)
      for (entry, outputURL) in zip(entries, outputURLs) {
        try ArchiveCancellation.check(cancellationProgress)
        guard !entry.directory else { continue }
        try extractEntry(
          entry,
          from: archive,
          to: outputURL,
          limits: limits,
          cancellationProgress: cancellationProgress,
          reporter: reporter)
      }
      reporter.finish()
    } catch let error as ArchiveServiceError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch UnrarError.missingPassword {
      throw ArchiveServiceError.encryptedArchive(.rar)
    } catch {
      if cancellationProgress.isCancelled || Task.isCancelled {
        throw CancellationError()
      }
      throw ArchiveServiceError.operationFailed(.rar)
    }
  }

  private func createEntryDirectories(
    entries: [Unrar.Entry],
    normalizedPaths: [String],
    outputURLs: [URL]
  ) throws {
    let directories = entries.indices
      .filter { entries[$0].directory }
      .sorted { outputURLs[$0].pathComponents.count < outputURLs[$1].pathComponents.count }
    for index in directories {
      try ArchivePreExtractionSafety.ensureActualDirectory(
        outputURLs[index],
        relativePath: normalizedPaths[index],
        format: .rar)
    }
  }

  private func extractEntry(
    _ entry: Unrar.Entry,
    from archive: Unrar.Archive,
    to outputURL: URL,
    limits: ArchiveSafetyLimits,
    cancellationProgress: Progress,
    reporter: ArchiveProgressReporter
  ) throws {
    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
      throw ArchiveServiceError.operationFailed(.rar)
    }
    let handle = try FileHandle(forWritingTo: outputURL)
    defer { try? handle.close() }
    reporter.beginEntry(size: Int64(clamping: entry.uncompressedSize))
    var writtenBytes: UInt64 = 0
    var handlerError: Error?

    do {
      try archive.extract(entry) { data, extractionProgress in
        guard handlerError == nil else {
          extractionProgress.cancel()
          return
        }
        do {
          try ArchiveCancellation.check(cancellationProgress)
          let (newWrittenBytes, overflow) = writtenBytes.addingReportingOverflow(UInt64(data.count))
          guard !overflow,
            newWrittenBytes <= entry.uncompressedSize,
            newWrittenBytes <= limits.maximumUncompressedBytes
          else {
            throw ArchiveServiceError.tooLarge(.rar)
          }
          try handle.write(contentsOf: data)
          writtenBytes = newWrittenBytes
          reporter.report(entryCompletedBytes: Int64(clamping: writtenBytes))
        } catch {
          handlerError = error
          extractionProgress.cancel()
        }
      }
    } catch {
      if let handlerError { throw handlerError }
      throw error
    }
    if let handlerError { throw handlerError }
    guard writtenBytes == entry.uncompressedSize else {
      throw ArchiveServiceError.operationFailed(.rar)
    }
    reporter.completeEntry()
  }
}

enum RARPathNormalizer {
  static func normalized(_ path: String) -> String {
    path.replacingOccurrences(of: "\\", with: "/")
  }
}

enum RARArchiveReader {
  static func openValidated(at archiveURL: URL) throws -> (Unrar.Archive, [Unrar.Entry]) {
    let archive = try Unrar.Archive(fileURL: archiveURL)
    guard !archive.isVolume else {
      throw ArchiveServiceError.multiVolumeArchive(.rar)
    }
    guard !archive.isHeaderEncrypted else {
      throw ArchiveServiceError.encryptedArchive(.rar)
    }
    let entries = try archive.entries()
    guard !entries.contains(where: \.encrypted) else {
      throw ArchiveServiceError.encryptedArchive(.rar)
    }
    return (archive, entries)
  }
}
