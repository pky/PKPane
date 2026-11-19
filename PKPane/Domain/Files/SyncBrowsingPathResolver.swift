import Foundation

/// 操作ペインの移動前後から、Providerに依存しない相対移動を表す。
struct SyncBrowsingRelativeMove: Equatable, Sendable {
  let upwardLevelCount: Int
  let downwardComponents: [String]

  /// 移動前後の共通祖先を基準に「上がる階層数」と「降りる名前列」へ分解する。
  static func resolve(from source: FileLocation, to destination: FileLocation) -> Self? {
    guard source.providerID == destination.providerID else { return nil }
    let sourceComponents = pathComponents(of: source)
    let destinationComponents = pathComponents(of: destination)
    let commonCount = zip(sourceComponents, destinationComponents)
      .prefix { $0.0 == $0.1 }
      .count
    let move = Self(
      upwardLevelCount: sourceComponents.count - commonCount,
      downwardComponents: Array(destinationComponents.dropFirst(commonCount)))
    return move.upwardLevelCount == 0 && move.downwardComponents.isEmpty ? nil : move
  }

  /// 相手ペインの現在地を起点に同じ相対移動を適用する。
  func applying(to location: FileLocation) -> FileLocation? {
    var destination = location
    for _ in 0..<upwardLevelCount {
      guard let parent = destination.deletingLastPathComponent(), parent != destination else {
        return nil
      }
      destination = parent
    }
    for component in downwardComponents {
      guard let child = destination.appending(pathComponent: component) else { return nil }
      destination = child
    }
    return destination
  }

  private static func pathComponents(of location: FileLocation) -> [String] {
    switch location.path {
    case .local(let url):
      url.standardizedFileURL.pathComponents
    case .remote(let path):
      path.split(separator: "/").map(String.init)
    }
  }
}
