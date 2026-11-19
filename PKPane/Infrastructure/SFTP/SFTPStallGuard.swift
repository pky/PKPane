import Foundation
import Synchronization

struct SFTPTransferStallError: LocalizedError, Equatable {
  var errorDescription: String? {
    "サーバーからの応答が途絶えたため転送を中止しました。接続を確認して再試行してください。"
  }
}

/// runの継続を「先着1件のみ採用」で複数の非構造化Taskから安全に共有するための箱。
/// MutexはCopyableではないため、ローカル変数のままでは2つ以上のエスケープするクロージャへ
/// 個別にキャプチャできない(Swift 6の送信チェックに抵触する)。参照型でラップすることで、
/// 各クロージャは常にこのクラスの参照(Copyable)をキャプチャする形になり、安全に共有できる。
private final class StallGuardResumeBox<T: Sendable>: Sendable {
  private let continuation: Mutex<CheckedContinuation<T, Error>?>

  init(_ continuation: CheckedContinuation<T, Error>) {
    self.continuation = Mutex(continuation)
  }

  func resume(returning value: T) {
    continuation.withLock { box in
      box?.resume(returning: value)
      box = nil
    }
  }

  func resume(throwing error: Error) {
    continuation.withLock { box in
      box?.resume(throwing: error)
      box = nil
    }
  }

  var isResolved: Bool {
    continuation.withLock { $0 == nil }
  }
}

/// SFTP転送のキャンセルとストールを、接続の強制close(onAbort)へ集約するガード。
/// Citadelのsendrequest待ちはTaskキャンセルに反応しないため、
/// closeでpromiseを失敗させてawaitを解放するのが唯一確実な中断手段。
final class SFTPStallGuard: Sendable {
  private enum AbortReason { case cancelled, stalled }

  private let timeout: Duration
  private let onAbort: @Sendable () -> Void
  private let state = Mutex<(lastActivity: ContinuousClock.Instant, reason: AbortReason?)>(
    (ContinuousClock().now, nil))

  init(timeout: Duration = .seconds(30), onAbort: @escaping @Sendable () -> Void) {
    self.timeout = timeout
    self.onAbort = onAbort
  }

  func recordActivity() {
    state.withLock { $0.lastActivity = ContinuousClock().now }
  }

  /// operationを監視タスクと並走させ、キャンセルまたはストールを検知したらonAbortを発火して
  /// operationの完了を待たずにエラーを投げ直す。
  ///
  /// operationはあえて非構造化Task(Task { ... })として起動する。withThrowingTaskGroupの
  /// 子タスクとして追加してしまうと、operationが応答不能になった場合にグループのスコープを
  /// 抜ける際に暗黙の完了待ちが発生し、run自体がハングしてしまう。これでは「onAbort後は
  /// operationの完了を待たずにrunを抜けられる」という要件(テスト1が検証する内容)を
  /// 満たせない。ここでは継続(continuation)を「先着1件のみ採用」の箱で共有し、operationの
  /// 完了とwatchdogによるabort検知をレースさせる。onAbort後もoperationのTaskは
  /// (可能ならキャンセルは試みるが)完了を待たずに放置してよい。実環境ではonAbort=接続close
  /// がCitadelのEventLoopPromiseを失敗させ、放置されたTaskはその時点で自然に回収される。
  func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    recordActivity()

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let resumeBox = StallGuardResumeBox<T>(continuation)

        let operationTask = Task {
          do {
            let value = try await operation()
            resumeBox.resume(returning: value)
          } catch {
            // 実環境ではonAbort(=接続close)がoperation側のawaitを解放するため、watchdogより
            // 先にこのcatchへ到達しうる(NIOのpromise失敗は数ホップ、watchdogのポーリングは
            // 平均250ms)。素のエラーをそのまま投げると呼び出し元の契約(キャンセル起因は
            // CancellationError、ストール起因はSFTPTransferStallErrorへ変換)を破るため、
            // ここでもreasonを見て同じ変換を行う。reasonはonAbort呼び出しより必ず先に
            // 書き込まれるため、onAbort経由でoperationが解放された時点では既に読み取れる。
            switch self.state.withLock({ $0.reason }) {
            case .cancelled: resumeBox.resume(throwing: CancellationError())
            case .stalled: resumeBox.resume(throwing: SFTPTransferStallError())
            case nil: resumeBox.resume(throwing: error)
            }
          }
        }

        let watchdogTask = Task { [timeout, onAbort] in
          while !Task.isCancelled {
            if resumeBox.isResolved {
              return
            }
            if let reason = self.state.withLock({ $0.reason }) {
              switch reason {
              case .cancelled: resumeBox.resume(throwing: CancellationError())
              case .stalled: resumeBox.resume(throwing: SFTPTransferStallError())
              }
              operationTask.cancel()
              return
            }
            let stalled = self.state.withLock { shared in
              ContinuousClock().now - shared.lastActivity > timeout
            }
            if stalled {
              self.state.withLock { $0.reason = .stalled }
              onAbort()
              resumeBox.resume(throwing: SFTPTransferStallError())
              operationTask.cancel()
              return
            }
            try? await Task.sleep(for: .milliseconds(250))
          }
        }
        _ = watchdogTask
      }
    } onCancel: {
      state.withLock { $0.reason = .cancelled }
      onAbort()
    }
  }
}
