import Foundation
import PLzmaSDK

struct SevenZipArchiveCodec: ArchiveCodec {
  func createArchive(
    from sourceURLs: [URL],
    to destinationURL: URL,
    cancellationProgress: Progress,
    progress: @escaping @Sendable (ArchiveProgress) -> Void
  ) throws {
    do {
      try checkCancellation(cancellationProgress)
      guard !sourceURLs.isEmpty else { throw ArchiveServiceError.noItems }
      let entries = try ArchiveSourceEntries.collect(from: sourceURLs)
      guard Set(entries.map(\.path)).count == entries.count else {
        throw ArchiveServiceError.duplicateEntryPath("同名の項目", .sevenZip)
      }

      let totalBytes = entries.reduce(Int64.zero) { $0 + $1.size }
      let reporter = SevenZipProgressReporter(totalBytes: totalBytes, handler: progress)
      let delegate = SevenZipEncoderDelegate(
        cancellationProgress: cancellationProgress,
        reporter: reporter)
      let outputStream = try OutStream(path: PLzmaSDK.Path(destinationURL.path))
      let encoder = try Encoder(
        stream: outputStream,
        fileType: .sevenZ,
        method: .LZMA2,
        delegate: delegate)
      let previousCancellationHandler = cancellationProgress.cancellationHandler
      cancellationProgress.cancellationHandler = {
        previousCancellationHandler?()
        DispatchQueue.global(qos: .userInitiated).async {
          try? encoder.abort()
        }
      }
      defer { cancellationProgress.cancellationHandler = previousCancellationHandler }
      reporter.start()

      for sourceURL in sourceURLs {
        try checkCancellation(cancellationProgress)
        try encoder.add(
          path: PLzmaSDK.Path(sourceURL.path),
          mode: .default,
          archivePath: PLzmaSDK.Path(sourceURL.lastPathComponent))
      }
      guard try encoder.open() else {
        try checkCancellation(cancellationProgress)
        throw ArchiveServiceError.operationFailed(.sevenZip)
      }
      try checkCancellation(cancellationProgress)
      // PLzmaSDKはdelegateをweakで保持するため、処理完了まで寿命を明示的に延長する。
      let didCompress = try withExtendedLifetime(delegate) {
        try encoder.compress()
      }
      guard didCompress else {
        try checkCancellation(cancellationProgress)
        throw ArchiveServiceError.operationFailed(.sevenZip)
      }
      try checkCancellation(cancellationProgress)
      reporter.finish()
    } catch let error as ArchiveServiceError {
      throw error
    } catch is CancellationError {
      try? FileManager.default.removeItem(at: destinationURL)
      throw CancellationError()
    } catch {
      if cancellationProgress.isCancelled || Task.isCancelled {
        try? FileManager.default.removeItem(at: destinationURL)
        throw CancellationError()
      }
      if error is PLzmaSDK.Exception {
        throw ArchiveServiceError.operationFailed(.sevenZip)
      }
      throw error
    }
  }

  func extractArchive(
    at archiveURL: URL,
    to destinationURL: URL,
    limits: ArchiveSafetyLimits,
    cancellationProgress: Progress,
    progress: @escaping @Sendable (ArchiveProgress) -> Void
  ) throws {
    do {
      try checkCancellation(cancellationProgress)
      let delegate = SevenZipDecoderDelegate(cancellationProgress: cancellationProgress)
      let decoder = try Decoder(
        stream: try InStream(path: PLzmaSDK.Path(archiveURL.path)),
        fileType: .sevenZ,
        delegate: delegate)
      let previousCancellationHandler = cancellationProgress.cancellationHandler
      cancellationProgress.cancellationHandler = {
        previousCancellationHandler?()
        DispatchQueue.global(qos: .userInitiated).async {
          try? decoder.abort()
        }
      }
      defer { cancellationProgress.cancellationHandler = previousCancellationHandler }

      guard try decoder.open() else {
        try checkCancellation(cancellationProgress)
        throw ArchiveServiceError.operationFailed(.sevenZip)
      }
      try checkCancellation(cancellationProgress)
      let itemCount = try decoder.count()
      guard itemCount <= UInt64(limits.maximumEntryCount) else {
        throw ArchiveServiceError.tooManyEntries(.sevenZip)
      }
      var safetyEntries: [ArchiveSafetyEntry] = []
      var validatedOutputURLs: [URL] = []
      safetyEntries.reserveCapacity(Int(itemCount))
      validatedOutputURLs.reserveCapacity(Int(itemCount))
      for index in 0..<itemCount {
        try checkCancellation(cancellationProgress)
        let item = try decoder.item(at: index)
        let path = try item.path().description
        let safetyEntry = ArchiveSafetyEntry(
          path: path,
          uncompressedSize: item.size,
          compressedSize: item.packSize,
          isSymbolicLink: false)
        safetyEntries.append(safetyEntry)
        let outputURL = try ArchiveEntrySafety.outputURL(
          for: path,
          in: destinationURL,
          format: .sevenZip)
        validatedOutputURLs.append(outputURL)
      }
      try ArchiveEntrySafety.validate(
        entries: safetyEntries,
        limits: limits,
        compressionAccounting: .aggregate,
        format: .sevenZip)
      try ArchivePreExtractionSafety.prepareDirectories(
        for: validatedOutputURLs,
        in: destinationURL,
        format: .sevenZip)
      let totalBytes = safetyEntries.reduce(Int64.zero) {
        $0 + Int64(clamping: $1.uncompressedSize)
      }

      let reporter = SevenZipProgressReporter(totalBytes: totalBytes, handler: progress)
      delegate.reporter = reporter
      reporter.start()
      // PLzmaSDKはdelegateをweakで保持するため、処理完了まで寿命を明示的に延長する。
      let didExtract = try withExtendedLifetime(delegate) {
        try decoder.extract(to: PLzmaSDK.Path(destinationURL.path))
      }
      guard didExtract else {
        try checkCancellation(cancellationProgress)
        throw ArchiveServiceError.operationFailed(.sevenZip)
      }
      try checkCancellation(cancellationProgress)
      try SevenZipPostExtractionSafety.validateNoSymbolicLinks(in: destinationURL)
      reporter.finish()
    } catch let error as ArchiveServiceError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if cancellationProgress.isCancelled || Task.isCancelled {
        throw CancellationError()
      }
      if error is PLzmaSDK.Exception {
        throw ArchiveServiceError.operationFailed(.sevenZip)
      }
      throw error
    }
  }

  private func checkCancellation(_ cancellationProgress: Progress) throws {
    guard !cancellationProgress.isCancelled else { throw CancellationError() }
    try Task.checkCancellation()
  }
}

enum ArchivePreExtractionSafety {
  static func prepareDirectories(
    for outputURLs: [URL],
    in rootURL: URL,
    format: ArchiveFormat,
    fileManager: FileManager = .default
  ) throws {
    let rootURL = rootURL.standardizedFileURL
    try ensureActualDirectory(
      rootURL,
      relativePath: "",
      format: format,
      fileManager: fileManager)

    let rootComponentCount = rootURL.pathComponents.count
    let directoryURLs = Set(
      outputURLs.flatMap { outputURL -> [URL] in
        let parentComponents = outputURL.standardizedFileURL.pathComponents
          .dropFirst(rootComponentCount)
          .dropLast()
        var directoryURL = rootURL
        return parentComponents.map { component in
          directoryURL.append(path: component, directoryHint: .isDirectory)
          return directoryURL.standardizedFileURL
        }
      }
    ).sorted { $0.pathComponents.count < $1.pathComponents.count }

    for directoryURL in directoryURLs {
      let relativePath = directoryURL.pathComponents
        .dropFirst(rootURL.pathComponents.count)
        .joined(separator: "/")
      try ensureActualDirectory(
        directoryURL,
        relativePath: relativePath,
        format: format,
        fileManager: fileManager)
    }
  }

  static func ensureActualDirectory(
    _ directoryURL: URL,
    relativePath: String,
    format: ArchiveFormat,
    fileManager: FileManager = .default
  ) throws {
    if (try? fileManager.destinationOfSymbolicLink(atPath: directoryURL.path)) != nil {
      throw ArchiveServiceError.symbolicLinkEntry(relativePath, format)
    }

    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else {
        throw ArchiveServiceError.operationFailed(format)
      }
      return
    }

    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: false)
  }
}

enum SevenZipPostExtractionSafety {
  static func validateNoSymbolicLinks(
    in rootURL: URL,
    fileManager: FileManager = .default
  ) throws {
    let keys: [URLResourceKey] = [.isSymbolicLinkKey]
    guard
      let enumerator = fileManager.enumerator(
        at: rootURL,
        includingPropertiesForKeys: keys,
        options: [])
    else {
      throw ArchiveServiceError.operationFailed(.sevenZip)
    }
    for case let itemURL as URL in enumerator {
      let values = try itemURL.resourceValues(forKeys: Set(keys))
      guard values.isSymbolicLink == true else { continue }
      // 一時領域ではrootURLが/var、enumeratorのURLが/private/varになることがあるため、
      // 文字数やルート側のcomponent数ではなく列挙深度から相対パスを復元する。
      let relativePath = itemURL.pathComponents.suffix(enumerator.level).joined(separator: "/")
      throw ArchiveServiceError.symbolicLinkEntry(relativePath, .sevenZip)
    }
  }
}

private final class SevenZipEncoderDelegate: EncoderDelegate, @unchecked Sendable {
  private let cancellationProgress: Progress
  private let reporter: SevenZipProgressReporter

  init(
    cancellationProgress: Progress,
    reporter: SevenZipProgressReporter
  ) {
    self.cancellationProgress = cancellationProgress
    self.reporter = reporter
  }

  func encoder(encoder: Encoder, path: String, progress: Double) {
    guard !cancellationProgress.isCancelled else { return }
    reporter.report(fraction: progress)
  }
}

private final class SevenZipDecoderDelegate: DecoderDelegate, @unchecked Sendable {
  private let cancellationProgress: Progress
  var reporter: SevenZipProgressReporter?

  init(cancellationProgress: Progress) {
    self.cancellationProgress = cancellationProgress
  }

  func decoder(decoder: Decoder, path: String, progress: Double) {
    guard !cancellationProgress.isCancelled else { return }
    reporter?.report(fraction: progress)
  }
}

private final class SevenZipProgressReporter: @unchecked Sendable {
  private let lock = NSLock()
  private let totalBytes: Int64
  private let handler: @Sendable (ArchiveProgress) -> Void
  private var lastReportedBytes: Int64 = -1

  init(totalBytes: Int64, handler: @escaping @Sendable (ArchiveProgress) -> Void) {
    self.totalBytes = max(totalBytes, 0)
    self.handler = handler
  }

  func start() {
    report(completedBytes: 0)
  }

  func report(fraction: Double) {
    let clampedFraction = min(max(fraction, 0), 1)
    report(completedBytes: Int64((Double(totalBytes) * clampedFraction).rounded(.down)))
  }

  func finish() {
    report(completedBytes: totalBytes)
  }

  private func report(completedBytes: Int64) {
    let update = lock.withLock { () -> ArchiveProgress? in
      let clamped = min(max(completedBytes, lastReportedBytes), totalBytes)
      guard clamped > lastReportedBytes else { return nil }
      lastReportedBytes = clamped
      return ArchiveProgress(completedBytes: clamped, totalBytes: totalBytes)
    }
    if let update {
      handler(update)
    }
  }
}
