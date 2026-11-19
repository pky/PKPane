import Foundation

/// ローカルディレクトリ直下の変更(追加・削除・リネーム)をDispatchSourceで監視する。
/// 開いているフォルダへ外部から落ちたファイルをFinderのように即反映するために使う。
/// イベントは短時間に連続し得る(スクリーンショット書き込み等)ため、呼び出し側の
/// コールバックはdebounce済みで高々数百ms間隔でしか呼ばれない。
final class LocalDirectoryWatcher {
  private let source: DispatchSourceFileSystemObject
  private var debounceWorkItem: DispatchWorkItem?

  /// 呼び出し側は既に開いたfdを渡す(open(2)自体はopening(directoryURL:onChange:)が
  /// メインスレッド外で行う)。queueが.mainのため、onChangeは実際にはメインスレッドから
  /// 発火する。@MainActorクロージャの呼び出しはMainActor.assumeIsolatedで表現する。
  private init(
    fileDescriptor: Int32, debounce: DispatchTimeInterval,
    onChange: @escaping @MainActor @Sendable () -> Void
  ) {
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: [.write, .rename, .delete],
      queue: .main)
    source.setCancelHandler {
      close(fileDescriptor)
    }
    self.source = source
    source.setEventHandler { [weak self] in
      guard let self else { return }
      self.debounceWorkItem?.cancel()
      let workItem = DispatchWorkItem {
        MainActor.assumeIsolated { onChange() }
      }
      self.debounceWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: workItem)
    }
    source.resume()
  }

  /// directoryURLの監視を非同期に開始する。open(2)は停止中のSMB/NFSマウントなどで
  /// ブロックしうるため、Task.detachedへ出してメインスレッド(呼び出し元のload()等)を
  /// 塞がない(LocalFileProvider.contents(of:includingHidden:)と同じ規約)。fdが開けない
  /// 場合はnilを返す。呼び出し側は監視なしで通常動作を続ける(従来挙動のまま)。
  static func opening(
    directoryURL: URL, debounce: DispatchTimeInterval = .milliseconds(250),
    onChange: @escaping @MainActor @Sendable () -> Void
  ) async -> LocalDirectoryWatcher? {
    let path = directoryURL.path
    let descriptor = await Task.detached(priority: .userInitiated) {
      open(path, O_EVTONLY)
    }.value
    guard descriptor >= 0 else { return nil }
    return LocalDirectoryWatcher(
      fileDescriptor: descriptor, debounce: debounce, onChange: onChange)
  }

  deinit {
    // debounceWorkItemはメインキュー(上のイベントハンドラ)専用の状態。deinitはARCの
    // 都合で任意のスレッドから走りうるため、非SendableなdebounceWorkItemへここから
    // 触れるとデータ競合になる。source.cancel()だけをスレッド安全に行い、未配送のまま
    // 残ったWorkItemが後から発火してもonChange側のweak self+currentLocation照合で
    // 無害なので放置する。
    source.cancel()
  }
}
