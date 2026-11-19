import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class RemoteEditController {
  static let shared = RemoteEditController()

  private let rootURL: URL
  private let store: any RemoteEditSessionStoring
  private let openWorkingCopy: @MainActor (URL) -> Void
  private var providers: [FileProviderID: any RemoteEditProvider] = [:]
  private var monitors: [UUID: DirectoryMonitor] = [:]
  private var presenters: [UUID: RemoteEditFilePresenter] = [:]
  private var debounceTasks: [UUID: Task<Void, Never>] = [:]

  private(set) var sessions: [RemoteEditSession]
  private(set) var errorMessage: String?
  private(set) var conflictSessionID: UUID?

  /// テストランナー内では実ユーザーのApplication Support/PKPane/RemoteEditsへ絶対に
  /// 触らない。init経路にrootURL配下の全削除があり、テストが実ユーザーの編集中
  /// ローカルコピーを破壊して「リモートファイルが見つかりません」を誘発した
  /// (2026-08-31実害)。JSONTransferJobStore.defaultURLと同じ方針で隔離する。
  nonisolated static func defaultRootURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if TestEnvironmentDetector.isRunningTests(environment: environment) {
      return FileManager.default.temporaryDirectory
        .appending(path: "pkpane-tests", directoryHint: .isDirectory)
        .appending(
          path: "remote-edits-\(ProcessInfo.processInfo.processIdentifier)",
          directoryHint: .isDirectory)
    }
    let directory =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return directory.appending(path: "PKPane/RemoteEdits", directoryHint: .isDirectory)
  }

  init(
    rootURL: URL? = nil,
    store: (any RemoteEditSessionStoring)? = nil,
    openWorkingCopy: @escaping @MainActor (URL) -> Void = { url in
      guard !ProcessInfo.processInfo.arguments.contains("-ui-test-suppress-external-editor") else {
        return
      }
      // ユニットテストからこの既定クロージャに到達しても実アプリを起動しない
      // (テスト実行のたびに外部アプリ/Finderが開く実害の封じ込め)。
      guard
        !TestEnvironmentDetector.isRunningTests(
          environment: ProcessInfo.processInfo.environment)
      else { return }
      NSWorkspace.shared.open(url)
    }
  ) {
    let defaultRoot = Self.defaultRootURL()
    self.rootURL = rootURL ?? defaultRoot
    self.openWorkingCopy = openWorkingCopy
    let defaultStore = RemoteEditSessionStore(
      url: (rootURL ?? defaultRoot).appending(path: "sessions.json"))
    let resolvedStore = store ?? defaultStore
    self.store = resolvedStore
    sessions = (try? self.store.load()) ?? []
    cleanupExpiredWorkingCopies()
  }

  var hasUnsyncedChanges: Bool {
    sessions.contains { $0.state != .synced }
  }

  func restore(using provider: any FileBrowserProvider) {
    guard let provider = provider as? any RemoteEditProvider else { return }
    providers[provider.id] = provider
    for session in sessions where session.providerID == provider.id {
      guard FileManager.default.fileExists(atPath: session.workingCopyPath) else { continue }
      observe(session)
      scheduleSynchronization(for: session.id)
    }
  }

  func startEditing(_ item: FileItem, using provider: any FileBrowserProvider) async {
    guard !item.isDirectory,
      let provider = provider as? any RemoteEditProvider
    else {
      errorMessage = "この接続では外部編集を利用できません。"
      return
    }
    providers[provider.id] = provider
    if let existing = sessions.first(where: { $0.remoteLocation == item.location }),
      FileManager.default.fileExists(atPath: existing.workingCopyPath)
    {
      observe(existing)
      openWorkingCopy(existing.workingCopyURL)
      return
    }
    do {
      let directory = rootURL.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory)
      let workingCopyURL = directory.appending(path: item.name)
      try await provider.downloadWorkingCopy(for: item, to: workingCopyURL)
      let revision = try workingCopyRevision(at: workingCopyURL)
      let session = RemoteEditSession(
        providerID: provider.id,
        remoteLocation: item.location,
        workingCopyURL: workingCopyURL,
        originalName: item.name,
        baseline: RemoteEditBaseline(item: item),
        lastSyncedRevision: revision)
      sessions.removeAll { $0.remoteLocation == item.location }
      sessions.append(session)
      persist()
      observe(session)
      openWorkingCopy(workingCopyURL)
    } catch {
      errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
    }
  }

  func resolveConflict(_ resolution: RemoteEditConflictResolution) {
    guard let id = conflictSessionID else { return }
    conflictSessionID = nil
    switch resolution {
    case .keepLocal:
      return
    case .overwrite:
      Task { await synchronize(id: id, force: true) }
    case .saveAs(let name):
      guard let index = sessions.firstIndex(where: { $0.id == id }),
        let location = sessions[index].remoteLocation.deletingLastPathComponent()?
          .appending(pathComponent: name)
      else { return }
      sessions[index].remoteLocation = location
      sessions[index].state = .unsynced
      persist()
      Task { await synchronize(id: id, force: true) }
    case .downloadLatest:
      Task { await downloadLatest(for: id) }
    }
  }

  func clearError() {
    errorMessage = nil
  }

  func resetForUITesting() {
    for task in debounceTasks.values {
      task.cancel()
    }
    debounceTasks = [:]
    for monitor in monitors.values {
      monitor.stop()
    }
    monitors = [:]
    for presenter in presenters.values {
      NSFileCoordinator.removeFilePresenter(presenter)
    }
    presenters = [:]
    sessions = []
    conflictSessionID = nil
    errorMessage = nil
    try? FileManager.default.removeItem(at: rootURL)
    persist()
  }

  func synchronizeNow(for id: UUID) async {
    await synchronize(id: id, force: false)
  }

  private func observe(_ session: RemoteEditSession) {
    guard monitors[session.id] == nil else { return }
    let presenter = RemoteEditFilePresenter(url: session.workingCopyURL) { [weak self] in
      self?.workingCopyDidChange(session.id)
    }
    presenters[session.id] = presenter
    NSFileCoordinator.addFilePresenter(presenter)
    let monitor = DirectoryMonitor(
      url: session.workingCopyURL.deletingLastPathComponent()
    ) { [weak self] in
      self?.workingCopyDidChange(session.id)
    }
    do {
      try monitor.start()
      monitors[session.id] = monitor
    } catch {
      errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
    }
  }

  private func workingCopyDidChange(_ id: UUID) {
    guard let session = sessions.first(where: { $0.id == id }),
      let revision = try? workingCopyRevision(at: session.workingCopyURL),
      revision != session.lastSyncedRevision
    else { return }
    update(id) {
      $0.state = .unsynced
      $0.updatedAt = .now
    }
    scheduleSynchronization(for: id)
  }

  private func scheduleSynchronization(for id: UUID) {
    debounceTasks[id]?.cancel()
    debounceTasks[id] = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(700))
        guard let self, let session = self.sessions.first(where: { $0.id == id }) else { return }
        let firstRevision = try self.workingCopyRevision(at: session.workingCopyURL)
        try await Task.sleep(for: .milliseconds(250))
        let stableRevision = try self.workingCopyRevision(at: session.workingCopyURL)
        guard firstRevision == stableRevision else {
          return
        }
        await self.synchronize(id: id, force: false)
      } catch is CancellationError {
      } catch {
        self?.fail(id: id, error: error)
      }
    }
  }

  private func synchronize(id: UUID, force: Bool) async {
    guard let index = sessions.firstIndex(where: { $0.id == id }),
      let provider = providers[sessions[index].providerID]
    else { return }
    let session = sessions[index]
    guard let revision = try? workingCopyRevision(at: session.workingCopyURL),
      revision != session.lastSyncedRevision
    else { return }
    update(id) { $0.state = .syncing }
    do {
      let remote = try await provider.item(at: session.remoteLocation)
      guard force || session.baseline.matches(remote) else {
        update(id) { $0.state = .conflict }
        conflictSessionID = id
        return
      }
      try await provider.uploadWorkingCopySafely(
        from: session.workingCopyURL,
        to: session.remoteLocation)
      let uploaded = try await provider.item(at: session.remoteLocation)
      guard let uploaded else {
        throw RemoteEditControllerError.uploadedFileMissing
      }
      update(id) {
        $0.baseline = RemoteEditBaseline(item: uploaded)
        $0.lastSyncedRevision = revision
        $0.state = .synced
        $0.updatedAt = .now
      }
    } catch {
      fail(id: id, error: error)
    }
  }

  private func downloadLatest(for id: UUID) async {
    guard let index = sessions.firstIndex(where: { $0.id == id }),
      let provider = providers[sessions[index].providerID]
    else { return }
    let session = sessions[index]
    do {
      guard let remote = try await provider.item(at: session.remoteLocation) else {
        throw RemoteEditControllerError.remoteFileMissing
      }
      try await provider.downloadWorkingCopy(for: remote, to: session.workingCopyURL)
      let revision = try workingCopyRevision(at: session.workingCopyURL)
      update(id) {
        $0.baseline = RemoteEditBaseline(item: remote)
        $0.lastSyncedRevision = revision
        $0.state = .synced
        $0.updatedAt = .now
      }
    } catch {
      fail(id: id, error: error)
    }
  }

  private func update(_ id: UUID, _ mutate: (inout RemoteEditSession) -> Void) {
    guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
    mutate(&sessions[index])
    persist()
  }

  private func fail(id: UUID, error: Error) {
    update(id) { $0.state = .failed }
    errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
  }

  private func persist() {
    do {
      try store.save(sessions)
    } catch {
      errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
    }
  }

  private func workingCopyRevision(at url: URL) throws -> String {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let size = values.fileSize ?? 0
    let date = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
    return "\(size):\(date)"
  }

  private func cleanupExpiredWorkingCopies() {
    let expiration = Date.now.addingTimeInterval(-7 * 24 * 60 * 60)
    for session in sessions where session.state == .synced && session.updatedAt < expiration {
      try? FileManager.default.removeItem(at: session.workingCopyURL.deletingLastPathComponent())
    }
    sessions.removeAll {
      $0.state == .synced && $0.updatedAt < expiration
    }
    persist()
  }
}

private final class RemoteEditFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
  let presentedItemURL: URL?
  let presentedItemOperationQueue: OperationQueue
  private let onChange: @MainActor () -> Void

  init(url: URL, onChange: @escaping @MainActor () -> Void) {
    presentedItemURL = url
    presentedItemOperationQueue = OperationQueue.main
    self.onChange = onChange
  }

  func presentedItemDidChange() {
    Task { @MainActor in
      onChange()
    }
  }

  func presentedItemDidMove(to newURL: URL) {
    Task { @MainActor in
      onChange()
    }
  }
}

enum RemoteEditControllerError: LocalizedError {
  case remoteFileMissing
  case uploadedFileMissing

  var errorDescription: String? {
    switch self {
    case .remoteFileMissing:
      "リモートファイルが見つかりません。"
    case .uploadedFileMissing:
      "アップロード後のリモートファイルを確認できません。"
    }
  }
}
