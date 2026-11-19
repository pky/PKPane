import Foundation

struct FileProviderID: Hashable, Sendable, RawRepresentable, Codable {
  let rawValue: String

  static let local = Self(rawValue: "local")
}

enum FileLocationPath: Hashable, Sendable, Codable {
  case local(URL)
  case remote(String)
}

struct FileLocation: Hashable, Sendable, Codable {
  let providerID: FileProviderID
  let path: FileLocationPath

  init(localURL: URL, providerID: FileProviderID = .local) {
    self.providerID = providerID
    self.path = .local(localURL.standardizedFileURL)
  }

  /// 閲覧・転送先として使うローカルディレクトリ用。
  /// シンボリックリンクと末尾スラッシュを解決し、同じ実体のディレクトリを同値にする。
  init(directoryURL: URL, providerID: FileProviderID = .local) {
    self.providerID = providerID
    path = .local(directoryURL.standardizedFileURL.resolvingSymlinksInPath())
  }

  /// 呼び出し側がstandardizedFileURL済みと保証できるURL用の高速イニシャライザ。
  init(normalizedLocalURL: URL, providerID: FileProviderID = .local) {
    self.providerID = providerID
    path = .local(normalizedLocalURL)
  }

  init(remotePath: String, providerID: FileProviderID) {
    self.providerID = providerID
    self.path = .remote(remotePath)
  }

  var localURL: URL? {
    guard case .local(let url) = path else { return nil }
    return url
  }

  var remotePath: String? {
    guard case .remote(let path) = path else { return nil }
    return path
  }

  /// 同じ実体のディレクトリを指すかを比較する。
  /// セッション状態・永続ジョブのパス表記は保持し、比較時だけシンボリックリンクを解決する。
  func representsSameDirectory(as other: Self) -> Bool {
    guard providerID == other.providerID else { return false }
    guard let localURL, let otherURL = other.localURL else { return self == other }
    return FileLocation(directoryURL: localURL, providerID: providerID)
      == FileLocation(directoryURL: otherURL, providerID: other.providerID)
  }

  func appending(pathComponent name: String) -> FileLocation? {
    guard !name.isEmpty,
      name != ".",
      name != "..",
      !name.contains("/")
    else {
      return nil
    }
    switch path {
    case .local(let url):
      return FileLocation(localURL: url.appending(path: name), providerID: providerID)
    case .remote(let directory):
      let childPath: String
      switch directory {
      case ".":
        childPath = "./\(name)"
      case "/":
        childPath = "/\(name)"
      default:
        childPath = "\(directory)/\(name)"
      }
      return FileLocation(remotePath: childPath, providerID: providerID)
    }
  }

  func deletingLastPathComponent() -> FileLocation? {
    switch path {
    case .local(let url):
      return FileLocation(localURL: url.deletingLastPathComponent(), providerID: providerID)
    case .remote(let path):
      guard path != ".", path != "/" else { return nil }
      if path.hasPrefix("./") {
        let components = path.dropFirst(2).split(separator: "/")
        guard components.count > 1 else {
          return FileLocation(remotePath: ".", providerID: providerID)
        }
        return FileLocation(
          remotePath: "./\(components.dropLast().joined(separator: "/"))",
          providerID: providerID)
      }
      let components = path.split(separator: "/")
      guard components.count > 1 else {
        return FileLocation(remotePath: "/", providerID: providerID)
      }
      return FileLocation(
        remotePath: "/\(components.dropLast().joined(separator: "/"))",
        providerID: providerID)
    }
  }
}

struct FileProviderCapabilities: OptionSet, Hashable, Sendable {
  let rawValue: UInt16

  static let read = Self(rawValue: 1 << 0)
  static let write = Self(rawValue: 1 << 1)
  static let rename = Self(rawValue: 1 << 2)
  static let moveWithinProvider = Self(rawValue: 1 << 3)
  static let copyWithinProvider = Self(rawValue: 1 << 4)
  static let trash = Self(rawValue: 1 << 5)
  static let deletePermanently = Self(rawValue: 1 << 6)
  static let replaceAtomically = Self(rawValue: 1 << 7)
  static let observeChanges = Self(rawValue: 1 << 8)
  static let resumeTransfer = Self(rawValue: 1 << 9)
  static let readSymbolicLink = Self(rawValue: 1 << 10)
  static let finderTags = Self(rawValue: 1 << 11)
  static let gitStatus = Self(rawValue: 1 << 12)
  static let cloudDownloadStatus = Self(rawValue: 1 << 13)
}
