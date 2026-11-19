import Darwin
import Foundation

/// App Sandboxのコンテナではなく、ログインユーザーのホームを扱う。
enum UserHomeDirectory {
  static let current: URL = {
    var record = passwd()
    var result: UnsafeMutablePointer<passwd>?
    var buffer = [CChar](repeating: 0, count: 16_384)
    let path = buffer.withUnsafeMutableBufferPointer { buffer -> String? in
      guard getpwuid_r(getuid(), &record, buffer.baseAddress, buffer.count, &result) == 0,
        result != nil, let directory = record.pw_dir
      else { return nil }
      return String(cString: directory)
    }
    return URL(filePath: path ?? NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory())
      .standardizedFileURL
  }()

  static func isAppContainerHome(_ url: URL, home: URL = current) -> Bool {
    url.standardizedFileURL.path
      == home.appending(
        path: "Library/Containers/\(Bundle.main.bundleIdentifier ?? "com.pky.PKPane")/Data"
      )
      .standardizedFileURL.path
  }

  static func standardFolderURLs(home: URL = current) -> [URL] {
    ["Desktop", "Downloads", "Documents", "Pictures", "Movies"].map {
      home.appending(path: $0, directoryHint: .isDirectory)
    } + [home, URL(filePath: "/Applications", directoryHint: .isDirectory)]
  }

  static func localizedStandardFolderName(
    for url: URL, home: URL = current, bundle: Bundle = .main
  ) -> String? {
    let url = url.standardizedFileURL
    let names: [String: String] = [
      "Desktop": String(localized: "デスクトップ", bundle: bundle),
      "Downloads": String(localized: "ダウンロード", bundle: bundle),
      "Documents": String(localized: "標準フォルダ：書類", defaultValue: "書類", bundle: bundle),
      "Pictures": String(localized: "ピクチャ", bundle: bundle),
      "Movies": String(localized: "ムービー", bundle: bundle),
      "Music": String(localized: "ミュージック", bundle: bundle),
    ]
    if url.deletingLastPathComponent().path == home.standardizedFileURL.path {
      return names[url.lastPathComponent]
    }
    if url.path == "/Applications" || url.path == home.appending(path: "Applications").path {
      return String(localized: "アプリケーション", bundle: bundle)
    }
    return nil
  }

  static func standardFolderSystemImage(for url: URL, home: URL = current) -> String? {
    let url = url.standardizedFileURL
    if url.path == home.standardizedFileURL.path { return "house" }
    if url.path == "/Applications" || url.path == home.appending(path: "Applications").path {
      return "app"
    }
    if url.path == home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs").path {
      return "icloud"
    }
    guard url.deletingLastPathComponent().path == home.standardizedFileURL.path else { return nil }
    return [
      "Desktop": "desktopcomputer", "Downloads": "arrow.down.circle", "Documents": "doc",
      "Pictures": "photo", "Movies": "film", "Music": "music.note",
    ][url.lastPathComponent]
  }
}
