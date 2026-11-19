import AppKit

/// FinderとのファイルURL交換を抽象化し、テストから実クリップボードを隔離する。
@MainActor
protocol FileClipboard: AnyObject {
  var changeCount: Int { get }
  var fileURLs: [URL] { get }
  func write(_ urls: [URL])
}

@MainActor
final class SystemFileClipboard: FileClipboard {
  private let pasteboard: NSPasteboard

  init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
  var changeCount: Int { pasteboard.changeCount }
  var fileURLs: [URL] {
    (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      as? [URL]) ?? []
  }
  func write(_ urls: [URL]) {
    pasteboard.clearContents()
    pasteboard.writeObjects(urls as [NSURL])
  }
}

@MainActor
final class MemoryFileClipboard: FileClipboard {
  private(set) var changeCount = 0
  private(set) var fileURLs: [URL] = []
  func write(_ urls: [URL]) {
    fileURLs = urls
    changeCount += 1
  }
}

@MainActor
func defaultFileClipboard() -> any FileClipboard {
  if TestEnvironmentDetector.isRunningTests(environment: ProcessInfo.processInfo.environment) {
    return MemoryFileClipboard()
  }
  return SystemFileClipboard()
}
