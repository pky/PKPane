import Darwin
import Foundation

enum SSHConfigAccessState: Equatable, Sendable {
  case direct
  case bookmarked(URL)
  case unavailable
}

enum SSHConfigReaderError: LocalizedError {
  case accessRequired
  case configNotFound

  var errorDescription: String? {
    switch self {
    case .accessRequired:
      String(localized: "~/.ssh フォルダへのアクセスを許可すると config を読み込めます")
    case .configNotFound:
      String(localized: "~/.ssh/config が見つかりません")
    }
  }
}

struct SSHConfigReader: Sendable {
  private let homeDirectory: URL
  private let accessRepository: SSHDirectoryAccessRepository
  private let fileReader: @Sendable (URL) throws -> String
  private let scopedAccess:
    @Sendable (URL) -> (start: @Sendable () -> Bool, stop: @Sendable () -> Void)

  init(
    homeDirectory: URL = UserHomeDirectory.current,
    accessRepository: SSHDirectoryAccessRepository,
    fileReader: @escaping @Sendable (URL) throws -> String = {
      try String(contentsOf: $0, encoding: .utf8)
    },
    scopedAccess:
      @escaping @Sendable (URL) -> (
        start: @Sendable () -> Bool, stop: @Sendable () -> Void
      ) = { url in
        (
          start: { url.startAccessingSecurityScopedResource() },
          stop: { url.stopAccessingSecurityScopedResource() }
        )
      }
  ) {
    self.homeDirectory = homeDirectory.standardizedFileURL
    self.accessRepository = accessRepository
    self.fileReader = fileReader
    self.scopedAccess = scopedAccess
  }

  func accessState() -> SSHConfigAccessState {
    do {
      _ = try fileReader(directConfigURL)
      return .direct
    } catch  where Self.isPermissionError(error) {
      guard let folderURL = try? accessRepository.restore() else { return .unavailable }
      return .bookmarked(folderURL.standardizedFileURL)
    } catch  where Self.isFileNotFoundError(error) {
      guard let folderURL = try? accessRepository.restore() else { return .direct }
      return .bookmarked(folderURL.standardizedFileURL)
    } catch {
      // 権限以外の読取エラーは loadDocument で具体的なエラーとして返す。
      return .direct
    }
  }

  func loadDocument() throws -> (document: SSHConfigDocument, folderURL: URL) {
    let state = accessState()
    return try withDirectoryAccess(state: state) {
      let folderURL = try folderURL(for: state)
      let configURL = folderURL.appending(path: "config")
      let text: String
      do {
        text = try fileReader(configURL)
      } catch  where Self.isFileNotFoundError(error) {
        throw SSHConfigReaderError.configNotFound
      } catch  where Self.isPermissionError(error) {
        throw SSHConfigReaderError.accessRequired
      }

      var unreadableIncludePaths: [String] = []
      let parsed = SSHConfigParser.parse(
        text,
        includeResolver: { pattern in
          guard let normalizedPattern = normalizedURL(pattern, within: folderURL) else {
            return nil
          }
          return includeURLs(matching: normalizedPattern, within: folderURL).map { url in
            do {
              return (path: url.path, text: try fileReader(url))
            } catch {
              unreadableIncludePaths.append(url.path)
              // 空の内容としてParserへ渡し、同じ絶対パスの再読取も防ぐ。
              return (path: url.path, text: "")
            }
          }
        },
        baseDirectory: folderURL.path)
      let warnings =
        parsed.warnings + unreadableIncludePaths.map(SSHConfigWarning.includeUnreadable)
      return (
        SSHConfigDocument(
          blocks: parsed.blocks, warnings: warnings, baseDirectory: parsed.baseDirectory),
        folderURL
      )
    }
  }

  func withDirectoryAccess<T>(_ body: () throws -> T) throws -> T {
    try withDirectoryAccess(state: accessState(), body)
  }

  func normalizedKeyFileURL(_ path: String, within folderURL: URL) -> URL? {
    normalizedURL(path, within: folderURL)
  }

  func saveDirectoryAccess(_ folderURL: URL) throws {
    try accessRepository.save(folderURL)
  }

  private func folderURL(for state: SSHConfigAccessState) throws -> URL {
    switch state {
    case .direct:
      directFolderURL
    case .bookmarked(let folderURL):
      folderURL
    case .unavailable:
      throw SSHConfigReaderError.accessRequired
    }
  }

  private func withDirectoryAccess<T>(
    state: SSHConfigAccessState, _ body: () throws -> T
  ) throws -> T {
    guard case .bookmarked(let folderURL) = state else {
      if case .unavailable = state { throw SSHConfigReaderError.accessRequired }
      return try body()
    }
    let access = scopedAccess(folderURL)
    let didStartAccessing = access.start()
    defer {
      if didStartAccessing { access.stop() }
    }
    return try body()
  }

  private var directFolderURL: URL {
    homeDirectory.appending(path: ".ssh")
  }

  private var directConfigURL: URL {
    directFolderURL.appending(path: "config")
  }

  private func normalizedURL(_ path: String, within folderURL: URL) -> URL? {
    let candidate: URL
    if path.hasPrefix("/") {
      candidate = URL(filePath: path)
    } else {
      candidate = folderURL.appending(path: path)
    }
    let normalizedFolder = folderURL.standardizedFileURL.resolvingSymlinksInPath()
    let normalizedCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
    guard Self.contains(normalizedCandidate, in: normalizedFolder) else { return nil }
    return normalizedCandidate
  }

  private func includeURLs(matching patternURL: URL, within folderURL: URL) -> [URL] {
    let pattern = patternURL.path
    guard pattern.contains(where: { "*?[".contains($0) }) else { return [patternURL] }
    guard
      let enumerator = FileManager.default.enumerator(
        at: folderURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])
    else { return [] }

    return enumerator.compactMap { value -> URL? in
      guard let url = value as? URL,
        fnmatch(pattern, url.path, FNM_PATHNAME) == 0,
        Self.contains(
          url.standardizedFileURL.resolvingSymlinksInPath(),
          in: folderURL.standardizedFileURL.resolvingSymlinksInPath())
      else { return nil }
      return url
    }
    .sorted { $0.path < $1.path }
  }

  private static func contains(_ candidate: URL, in folder: URL) -> Bool {
    let folderComponents = folder.pathComponents
    let candidateComponents = candidate.pathComponents
    return candidateComponents.count >= folderComponents.count
      && Array(candidateComponents.prefix(folderComponents.count)) == folderComponents
  }

  private static func isPermissionError(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
      return true
    }
    if nsError.domain == NSPOSIXErrorDomain,
      nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
    {
      return true
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
      return isPermissionError(underlying)
    }
    return false
  }

  private static func isFileNotFoundError(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileNoSuchFileError {
      return true
    }
    if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
      return true
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
      return isFileNotFoundError(underlying)
    }
    return false
  }
}
