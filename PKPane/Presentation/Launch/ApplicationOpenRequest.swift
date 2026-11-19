import Foundation
import Observation

enum ApplicationOpenTarget: Equatable, Sendable {
  case directory(URL)
  case file(URL, parentDirectory: URL)

  var directoryURL: URL {
    switch self {
    case .directory(let url):
      url
    case .file(_, let parentDirectory):
      parentDirectory
    }
  }

  var itemURL: URL? {
    guard case .file(let url, _) = self else { return nil }
    return url
  }
}

struct ApplicationOpenResolution: Equatable, Sendable {
  let target: ApplicationOpenTarget?
  let ignoredURLCount: Int
}

enum ApplicationOpenRequestResolver {
  static func resolve(
    _ urls: [URL],
    fileManager: FileManager = .default
  ) -> ApplicationOpenResolution {
    let ignoredURLCount = max(0, urls.count - 1)
    guard let firstURL = urls.first, firstURL.isFileURL else {
      return ApplicationOpenResolution(target: nil, ignoredURLCount: ignoredURLCount)
    }

    let url = firstURL.standardizedFileURL
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return ApplicationOpenResolution(target: nil, ignoredURLCount: ignoredURLCount)
    }
    let target: ApplicationOpenTarget =
      isDirectory.boolValue
      ? .directory(url)
      : .file(url, parentDirectory: url.deletingLastPathComponent())
    return ApplicationOpenResolution(target: target, ignoredURLCount: ignoredURLCount)
  }
}

struct ApplicationOpenRequest: Identifiable, Equatable, Sendable {
  let id = UUID()
  let target: ApplicationOpenTarget
}

@Observable
@MainActor
final class ApplicationOpenRequestStore {
  private var requests: [ApplicationOpenRequest] = []
  private var hasCompletedWorkspaceRestoration = false
  private(set) var revision = 0

  @discardableResult
  func receive(_ urls: [URL]) -> ApplicationOpenResolution {
    let resolution = ApplicationOpenRequestResolver.resolve(urls)
    if resolution.ignoredURLCount > 0 {
      AppLog.notice(
        "openイベントの先頭以外を無視しました: \(resolution.ignoredURLCount)件",
        category: "ApplicationOpen")
    }
    guard let target = resolution.target else { return resolution }
    requests.append(ApplicationOpenRequest(target: target))
    revision &+= 1
    return resolution
  }

  func completeWorkspaceRestoration() {
    hasCompletedWorkspaceRestoration = true
  }

  func takeNextRequestIfReady() -> ApplicationOpenRequest? {
    guard hasCompletedWorkspaceRestoration, !requests.isEmpty else { return nil }
    return requests.removeFirst()
  }
}

@MainActor
enum ApplicationOpenNavigation {
  static func presentation(for target: ApplicationOpenTarget) -> ProviderBrowserPresentation {
    let provider = LocalFileProvider()
    let directoryURL = target.directoryURL
    let location = FileLocation(localURL: directoryURL, providerID: provider.id)
    let browser = FileBrowserSession(provider: provider, initialLocation: location)
    if let itemURL = target.itemURL {
      browser.revealItem(at: itemURL, in: location)
    }
    return ProviderBrowserPresentation(
      title: directoryURL.lastPathComponent,
      browser: browser,
      sftpTarget: nil)
  }
}
