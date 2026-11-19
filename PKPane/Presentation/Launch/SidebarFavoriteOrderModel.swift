import Foundation
import Observation

/// 保存先そのものを変更せず、端末内のサイドバー表示順だけを保存する。
@Observable
@MainActor
final class SidebarFavoriteOrderModel {
  private let defaults: UserDefaults
  private let key = "sidebar-favorite-order"
  private var savedIDs: [String]
  @ObservationIgnored private var defaultsObserver: (any NSObjectProtocol)?

  init(defaults: UserDefaults? = nil) {
    let defaults = defaults ?? PKPaneUserDefaults.resolve()
    self.defaults = defaults
    savedIDs = defaults.stringArray(forKey: key) ?? []
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reload() }
    }
  }

  isolated deinit {
    if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
  }

  private func reload() {
    let latest = defaults.stringArray(forKey: key) ?? []
    if latest != savedIDs { savedIDs = latest }
  }

  func orderedIDs(available: [String]) -> [String] {
    let availableSet = Set(available)
    var seen = Set<String>()
    return (savedIDs.filter { availableSet.contains($0) } + available).filter {
      seen.insert($0).inserted
    }
  }

  func insert(_ ids: [String], before anchor: String?, available: [String]) {
    reload()
    let availableSet = Set(available)
    var seen = Set<String>()
    let moving = ids.filter { availableSet.contains($0) && seen.insert($0).inserted }
    guard !moving.isEmpty else { return }
    // 自分自身の直前へのdropは表示位置を変えない。
    guard !(moving.count == 1 && moving.first == anchor) else { return }
    // 未ロードの保存先IDも保持し、起動途中の操作で別プロトコルの順序を失わない。
    var next = savedIDs
    next.append(contentsOf: available.filter { !next.contains($0) })
    let index = anchor.flatMap { target in
      next.firstIndex(of: target).map { anchorIndex in
        next[..<anchorIndex].filter { !moving.contains($0) }.count
      }
    }
    next.removeAll { moving.contains($0) }
    next.insert(contentsOf: moving, at: index ?? next.endIndex)
    savedIDs = next
    defaults.set(next, forKey: key)
  }

  /// この経路は登録・表示順だけを変更し、ファイル転送を呼ばない。
  func performDrop(
    _ urls: [URL], before anchor: String?, available: () -> [String],
    register: (URL) -> String?
  ) -> Bool {
    let internalIDs = Self.draggedIDs(urls: urls, available: available())
    let ids: [String]
    if urls.contains(where: Self.isFavoriteDrag) {
      ids = internalIDs
    } else {
      ids = urls.compactMap(register)
    }
    guard !ids.isEmpty else { return false }
    insert(ids, before: anchor, available: available())
    return true
  }

  func move(_ id: String, by offset: Int, available: [String]) {
    reload()
    let order = orderedIDs(available: available)
    guard let index = order.firstIndex(of: id) else { return }
    let destination = index + offset
    guard order.indices.contains(destination) else { return }
    let anchorIndex = offset > 0 ? destination + 1 : destination
    insert([id], before: anchorIndex < order.count ? order[anchorIndex] : nil, available: available)
  }

  static func dragURL(for id: String) -> URL {
    var components = URLComponents()
    components.scheme = "pkpane-favorite"
    components.host = "sidebar"
    components.path = "/" + id
    return components.url ?? URL(filePath: "/")
  }

  static func isFavoriteDrag(_ url: URL) -> Bool {
    url.scheme == "pkpane-favorite"
  }

  static func draggedIDs(urls: [URL], available: [String]) -> [String] {
    let availableSet = Set(available)
    return urls.compactMap { url in
      guard isFavoriteDrag(url), url.host == "sidebar" else { return nil }
      let id = url.lastPathComponent
      return availableSet.contains(id) ? id : nil
    }
  }
}
