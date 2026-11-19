import AppKit
import Foundation

/// ローカルボリュームの取り出しをメインスレッド外で実行する。
@MainActor
final class SystemLocalVolumeEjector {
  func eject(
    volumeURL: URL,
    completion: @escaping @MainActor (Result<Void, LocalVolumeEjectError>) -> Void
  ) {
    DispatchQueue.global(qos: .utility).async {
      let result: Result<Void, LocalVolumeEjectError>
      do {
        try NSWorkspace.shared.unmountAndEjectDevice(at: volumeURL)
        result = .success(())
      } catch {
        result = .failure(.ejectionFailed)
      }

      Task { @MainActor in
        completion(result)
      }
    }
  }
}

enum LocalVolumeEjectError: LocalizedError, Equatable, Sendable {
  case ejectionFailed

  var errorDescription: String? {
    switch self {
    case .ejectionFailed:
      String(localized: "ボリュームを取り出せませんでした。")
    }
  }
}
