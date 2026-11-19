import Foundation

struct FolderBreadcrumb: Identifiable, Equatable {
  let url: URL
  let name: String

  var id: URL { url }

  static func make(root: URL, current: URL) -> [FolderBreadcrumb] {
    let rootComponents = root.standardizedFileURL.pathComponents
    let currentComponents = current.standardizedFileURL.pathComponents
    guard currentComponents.starts(with: rootComponents) else { return [] }

    var breadcrumbs = [FolderBreadcrumb(url: root, name: root.lastPathComponent)]
    var path = root
    for component in currentComponents.dropFirst(rootComponents.count) {
      path.append(path: component, directoryHint: .isDirectory)
      breadcrumbs.append(FolderBreadcrumb(url: path, name: component))
    }
    return breadcrumbs
  }
}
