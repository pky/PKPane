import Observation

/// サイドバー接続セクションの表示/非表示状態(ピン留め)を保持するUI向けモデル。
/// 実体はSidebarConnectionVisibilityStore(UserDefaults永続化)。LaunchViewのサイドバー
/// フィルタリングと、ConnectPanelViewの一覧モード(サイドバーに表示・から隠すトグル)の
/// 両方から同じインスタンスを参照する。
@Observable
@MainActor
final class SidebarConnectionVisibilityModel {
  private let store: SidebarConnectionVisibilityStore
  private(set) var hiddenIdentifiers: Set<String>

  init(store: SidebarConnectionVisibilityStore = SidebarConnectionVisibilityStore()) {
    self.store = store
    hiddenIdentifiers = store.hiddenIdentifiers()
  }

  func isHidden(_ profile: NASConnectionProfile) -> Bool {
    hiddenIdentifiers.contains(SidebarConnectionVisibilityStore.identifier(for: profile))
  }

  func isHidden(_ target: SFTPConnectionTarget) -> Bool {
    hiddenIdentifiers.contains(SidebarConnectionVisibilityStore.identifier(for: target))
  }

  func isHidden(_ target: FTPConnectionTarget) -> Bool {
    hiddenIdentifiers.contains(SidebarConnectionVisibilityStore.identifier(for: target))
  }

  func setHidden(_ hidden: Bool, for profile: NASConnectionProfile) {
    setHidden(hidden, identifier: SidebarConnectionVisibilityStore.identifier(for: profile))
  }

  func setHidden(_ hidden: Bool, for target: SFTPConnectionTarget) {
    setHidden(hidden, identifier: SidebarConnectionVisibilityStore.identifier(for: target))
  }

  func setHidden(_ hidden: Bool, for target: FTPConnectionTarget) {
    setHidden(hidden, identifier: SidebarConnectionVisibilityStore.identifier(for: target))
  }

  private func setHidden(_ hidden: Bool, identifier: String) {
    store.setHidden(hidden, for: identifier)
    hiddenIdentifiers = store.hiddenIdentifiers()
  }
}
