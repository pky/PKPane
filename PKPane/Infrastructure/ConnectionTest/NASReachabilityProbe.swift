import Foundation
import Network

/// NAS接続テストの「到達性確認」に失敗した際のエラー。到達不能・タイムアウトいずれも
/// ConnectionErrorClassifier側で同じ「到達不能」カテゴリへ写像する。
enum ConnectionReachabilityError: LocalizedError, Equatable {
  case timedOut
  case unreachable(String)

  var errorDescription: String? {
    "サーバーに到達できません。ホスト名とネットワーク接続を確認してください。"
  }
}

/// NASのTCP到達性を確認するプローブ。「接続をテスト」機能の実体で、実装をプロトコル注入
/// により差し替え可能にしている(単体テストは実ネットワークに依存しないフェイクを使う)。
protocol NASReachabilityProbing: Sendable {
  /// hostのportへTCP接続を試み、確立できたら復帰する。timeout以内に確立できなければ
  /// ConnectionReachabilityError.timedOutを投げる。呼び出し元のTaskがキャンセルされた場合は
  /// CancellationErrorを投げて即座に中断する。
  func probe(host: String, port: UInt16, timeout: Duration) async throws
}

/// Network.framework(NWConnection)によるTCP到達性確認の実装。
struct NWReachabilityProbe: NASReachabilityProbing {
  func probe(host: String, port: UInt16, timeout: Duration) async throws {
    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
      throw ConnectionReachabilityError.unreachable(host)
    }
    let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
    defer { connection.cancel() }
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await Self.waitUntilReady(connection) }
        group.addTask {
          try await Task.sleep(for: timeout)
          throw ConnectionReachabilityError.timedOut
        }
        defer { group.cancelAll() }
        _ = try await group.next()
      }
    } catch let error as ConnectionReachabilityError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ConnectionReachabilityError.unreachable(host)
    }
  }

  /// stateUpdateHandlerは複数回呼ばれうるため、continuationの二重resumeを防ぐガードを
  /// 介して1回だけ再開する。
  private static func waitUntilReady(_ connection: NWConnection) async throws {
    final class ResumeOnce: @unchecked Sendable {
      private let lock = NSLock()
      private var didResume = false
      func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        body()
      }
    }
    let resumeOnce = ResumeOnce()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        connection.stateUpdateHandler = { state in
          switch state {
          case .ready:
            resumeOnce.run { continuation.resume() }
          case .failed(let error):
            resumeOnce.run {
              connection.cancel()
              continuation.resume(throwing: error)
            }
          case .cancelled:
            resumeOnce.run { continuation.resume(throwing: CancellationError()) }
          default:
            break
          }
        }
        connection.start(queue: .global(qos: .utility))
      }
    } onCancel: {
      connection.cancel()
    }
  }
}
