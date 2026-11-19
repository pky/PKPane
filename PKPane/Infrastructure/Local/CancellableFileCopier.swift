import Darwin
import Dispatch
import Foundation
import Synchronization

/// clonefile(2)による即時クローンを優先し、失敗時は同一ボリューム上ならコールバック未登録
/// copyfile(3)によるサーバーサイドコピー回復を試み、それも失敗すればキャンセル可能な
/// 手動チャンクコピーへフォールバックする再帰コピー。copyfile(3)の進捗ステータス
/// コールバック(COPYFILE_STATE_STATUS_CB)は本アプリの動作環境でコールバック呼び出し時に
/// プロセスがクラッシュする既知の不具合があるため使用しない
/// (詳細: .superpowers/sdd/2026-08-01-transfer-fixes-m15/task-1-report.md)。
enum CancellableFileCopier {
  private static let chunkSize = 1 * 1_024 * 1_024
  /// 帯域待ちをSwift concurrencyの協調スレッド上で同期ブロックしないための専用キュー。
  private static let workQueue = DispatchQueue(
    label: "com.pky.PKPane.cancellable-file-copier",
    qos: .utility,
    attributes: .concurrent)

  static func copy(
    from sourceURL: URL,
    to destinationURL: URL,
    isCancelled: @escaping @Sendable () -> Bool,
    progress: (@Sendable (Int64) -> Void)? = nil,
    cloneAttempt: (URL, URL) -> Bool = defaultCloneAttempt,
    copyfileAttempt: (URL, URL) -> Bool = defaultCopyfileAttempt,
    rateLimiter: TransferRateLimiter = .shared,
    volumeIsLocal: (URL) -> Bool = defaultVolumeIsLocal
  ) throws {
    let onSameVolume = isOnSameVolume(sourceURL, destinationURL)
    let allowsKernelFastPath =
      rateLimiter.currentBytesPerSecond() == nil
      || (onSameVolume && volumeIsLocal(sourceURL)
        && volumeIsLocal(destinationURL.deletingLastPathComponent()))
    if allowsKernelFastPath, cloneAttempt(sourceURL, destinationURL) {
      if let progress {
        progress((try? totalByteSize(of: destinationURL)) ?? 0)
      }
      return
    }
    let accumulator = ProgressAccumulator(progress: progress)
    // ボリューム判定はコピー元・先のペアで不変なので、再帰の入口で1回だけ行い真偽値を
    // 引き回す。ファイルごとに問い合わせると、小ファイル大量コピー(まさにこの経路の
    // 高速化対象)でstatfs相当の呼び出しがファイル数分積み上がってしまう。
    try copyEntryRecursively(
      from: sourceURL, to: destinationURL, isCancelled: isCancelled, accumulator: accumulator,
      copyfileAttempt: copyfileAttempt,
      onSameVolume: onSameVolume,
      allowsKernelFastPath: allowsKernelFastPath,
      rateLimiter: rateLimiter)
  }

  /// 同期ファイルI/Oと帯域待ちを専用GCDキューへ退避して実行する。
  /// Providerのasync境界から利用し、Swift concurrencyの協調スレッドを占有しない。
  static func performOnDedicatedThread<T: Sendable>(
    _ operation:
      @escaping @Sendable (
        _ isCancelled: @escaping @Sendable () -> Bool
      ) throws -> T
  ) async throws -> T {
    let cancellation = DedicatedThreadCancellationFlag()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        workQueue.async {
          do {
            guard !cancellation.isCancelled else { throw CancellationError() }
            continuation.resume(returning: try operation { cancellation.isCancelled })
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  /// clonefile(2)を直接呼び出す。copyfile(3)と違い進捗コールバックを持たないため
  /// このアプリの動作環境でも安全に使える。同一APFSボリュームなら即時完了する。
  static func defaultCloneAttempt(_ sourceURL: URL, _ destinationURL: URL) -> Bool {
    sourceURL.path.withCString { sourcePath in
      destinationURL.path.withCString { destinationPath in
        clonefile(sourcePath, destinationPath, 0) == 0
      }
    }
  }

  /// copyfile(3)をコールバック未登録(state: nil)・COPYFILE_ALLで呼ぶ。本機ではコールバック
  /// 未登録なら安全に動作することを確認済み。clonefileが失敗する非APFSの同一ボリューム
  /// (SMBマウント等)では、SMBサーバーサイドコピーへフォールスルーしうるため次善手として
  /// 試す。失敗時(EXDEV等)はfalseを返し呼び出し側がチャンクコピーへフォールバックする。
  static func defaultCopyfileAttempt(_ sourceURL: URL, _ destinationURL: URL) -> Bool {
    copyfile(sourceURL.path, destinationURL.path, nil, copyfile_flags_t(COPYFILE_ALL)) == 0
  }

  private static func isOnSameVolume(_ sourceURL: URL, _ destinationURL: URL) -> Bool {
    (try? SystemFileOperationFileSystem().areOnSameVolume(
      sourceURL, destinationURL.deletingLastPathComponent())) == true
  }

  private static func defaultVolumeIsLocal(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true
  }

  private static func copyEntryRecursively(
    from sourceURL: URL,
    to destinationURL: URL,
    isCancelled: @Sendable () -> Bool,
    accumulator: ProgressAccumulator,
    copyfileAttempt: (URL, URL) -> Bool,
    onSameVolume: Bool,
    allowsKernelFastPath: Bool,
    rateLimiter: TransferRateLimiter
  ) throws {
    guard !isCancelled() else { throw CancellationError() }
    let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    if values.isSymbolicLink == true {
      let target = try FileManager.default.destinationOfSymbolicLink(atPath: sourceURL.path)
      try FileManager.default.createSymbolicLink(
        atPath: destinationURL.path, withDestinationPath: target)
      return
    }
    if values.isDirectory == true {
      try copyDirectoryRecursively(
        from: sourceURL, to: destinationURL, isCancelled: isCancelled, accumulator: accumulator,
        copyfileAttempt: copyfileAttempt,
        onSameVolume: onSameVolume,
        allowsKernelFastPath: allowsKernelFastPath,
        rateLimiter: rateLimiter)
      return
    }
    try copyFile(
      from: sourceURL, to: destinationURL, isCancelled: isCancelled, accumulator: accumulator,
      copyfileAttempt: copyfileAttempt,
      onSameVolume: onSameVolume,
      allowsKernelFastPath: allowsKernelFastPath,
      rateLimiter: rateLimiter)
  }

  private static func copyDirectoryRecursively(
    from sourceURL: URL,
    to destinationURL: URL,
    isCancelled: @Sendable () -> Bool,
    accumulator: ProgressAccumulator,
    copyfileAttempt: (URL, URL) -> Bool,
    onSameVolume: Bool,
    allowsKernelFastPath: Bool,
    rateLimiter: TransferRateLimiter
  ) throws {
    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false)
    let children = try FileManager.default.contentsOfDirectory(
      at: sourceURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [])
    for child in children {
      guard !isCancelled() else { throw CancellationError() }
      try copyEntryRecursively(
        from: child,
        to: destinationURL.appending(path: child.lastPathComponent),
        isCancelled: isCancelled,
        accumulator: accumulator,
        copyfileAttempt: copyfileAttempt,
        onSameVolume: onSameVolume,
        allowsKernelFastPath: allowsKernelFastPath,
        rateLimiter: rateLimiter)
    }
    try copyMetadataOnly(from: sourceURL, to: destinationURL)
  }

  /// 同一ボリューム上ならまずcopyfile(3)によるサーバーサイドコピー回復を試す(成功すれば
  /// チャンクループを丸ごとスキップできる)。対象外・失敗時はチャンクコピー+メタデータ転送へ
  /// フォールバックする。ファイル単位でこの判定を通すため、ディレクトリ内の他ファイルへの
  /// キャンセル粒度(isCancelledチェック)には影響しない。ただしcopyfile呼び出し自体は
  /// 中断不能で、キャンセル応答は最大単一ファイル分遅れる(計画で受容済み)。
  private static func copyFile(
    from sourceURL: URL,
    to destinationURL: URL,
    isCancelled: @Sendable () -> Bool,
    accumulator: ProgressAccumulator,
    copyfileAttempt: (URL, URL) -> Bool,
    onSameVolume: Bool,
    allowsKernelFastPath: Bool,
    rateLimiter: TransferRateLimiter
  ) throws {
    guard !isCancelled() else { throw CancellationError() }
    if allowsKernelFastPath, onSameVolume, copyfileAttempt(sourceURL, destinationURL) {
      accumulator.add((try? totalByteSize(of: destinationURL)) ?? 0)
      return
    }
    try copyFileInChunks(
      from: sourceURL, to: destinationURL, isCancelled: isCancelled, accumulator: accumulator,
      rateLimiter: rateLimiter)
    try copyMetadataOnly(from: sourceURL, to: destinationURL)
  }

  private static func copyFileInChunks(
    from sourceURL: URL,
    to destinationURL: URL,
    isCancelled: @Sendable () -> Bool,
    accumulator: ProgressAccumulator,
    rateLimiter: TransferRateLimiter
  ) throws {
    guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let input = try FileHandle(forReadingFrom: sourceURL)
    defer { try? input.close() }
    let output = try FileHandle(forWritingTo: destinationURL)
    defer { try? output.close() }
    while true {
      guard !isCancelled() else { throw CancellationError() }
      guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { break }
      try waitForBandwidth(chunk.count, using: rateLimiter, isCancelled: isCancelled)
      try output.write(contentsOf: chunk)
      accumulator.add(Int64(chunk.count))
    }
  }

  private static func waitForBandwidth(
    _ byteCount: Int,
    using rateLimiter: TransferRateLimiter,
    isCancelled: @Sendable () -> Bool
  ) throws {
    let waiter = BlockingRateLimitWaiter()
    let task = Task {
      do {
        try await rateLimiter.acquire(bytes: byteCount)
        waiter.finish()
      } catch {
        waiter.finish(throwing: error)
      }
    }
    do {
      try waiter.wait(isCancelled: isCancelled)
    } catch {
      task.cancel()
      throw error
    }
  }

  /// copyfile(3)をコールバックなし・非再帰で呼び、権限・タイムスタンプ・xattrなど
  /// 1項目分のメタデータだけを転送する。コールバック未登録時は安全に動作する。
  private static func copyMetadataOnly(from sourceURL: URL, to destinationURL: URL) throws {
    let result = copyfile(
      sourceURL.path, destinationURL.path, nil, copyfile_flags_t(COPYFILE_METADATA))
    guard result == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
  }

  private static func totalByteSize(of url: URL) throws -> Int64 {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
    guard values.isDirectory != true else {
      var total: Int64 = 0
      let children = try FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [])
      for child in children {
        total += (try? totalByteSize(of: child)) ?? 0
      }
      return total
    }
    return values.fileSize.map(Int64.init) ?? 0
  }
}

/// Swift Taskのキャンセル状態を専用GCDキューへ安全に引き渡す共有フラグ。
private final class DedicatedThreadCancellationFlag: Sendable {
  private let cancelled = Mutex(false)

  var isCancelled: Bool {
    cancelled.withLock { $0 }
  }

  func cancel() {
    cancelled.withLock { $0 = true }
  }
}

/// CancellableFileCopierの専用GCDスレッドだけを停止させる同期橋渡し。
/// Swift concurrencyの協調スレッドからはperformOnDedicatedThread経由で退避済みである。
final class BlockingRateLimitWaiter: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var error: (any Error)?

  func finish(throwing error: (any Error)? = nil) {
    lock.withLock { self.error = error }
    semaphore.signal()
  }

  func wait(isCancelled: @Sendable () -> Bool) throws {
    while semaphore.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
      guard !isCancelled() else { throw CancellationError() }
    }
    if let error = lock.withLock({ error }) {
      throw error
    }
  }
}

/// 再帰コピー1回の呼び出し中のみ生存する、単一スレッドからの逐次アクセスを前提とした
/// 累積カウンタ。並行アクセスはされないためロックは持たない。
private final class ProgressAccumulator {
  private var completedBytes: Int64 = 0
  private let progress: (@Sendable (Int64) -> Void)?

  init(progress: (@Sendable (Int64) -> Void)?) {
    self.progress = progress
  }

  func add(_ bytes: Int64) {
    completedBytes += bytes
    progress?(completedBytes)
  }
}
