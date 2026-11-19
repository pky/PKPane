import AppKit
import SwiftUI
import ZIPFoundation

@main
struct PKPaneApp: App {
  @NSApplicationDelegateAdaptor(PKPaneAppDelegate.self) private var appDelegate
  @State private var appMenuModel = AppMenuModel()
  @State private var themeModel = AppThemeModel.shared
  @State private var settingsModel = PKPaneSettingsModel()

  init() {
    if ProcessInfo.processInfo.arguments.contains("-reset-folder-bookmark") {
      resetUITestDefaultsIfNeeded()
      UserDefaultsFolderBookmarkStore().removeBookmarkData()
      UserDefaultsFolderLocationListStore(key: "favorite-folder-bookmarks")
        .removeLocationListData()
      UserDefaultsFolderLocationListStore(key: "recent-folder-bookmarks")
        .removeLocationListData()
      SFTPFolderFavoriteRepository().removeAll()
      FileBrowserDisplayOptionsStore().remove()
      AppearancePreferencesStore().remove()
      TransferPreferencesStore.shared.remove()
      ArchivePreferencesStore.shared.remove()
      KeymapPreferencesStore.shared.remove()
      settingsModel.reloadAppearancePreference()
      settingsModel.reloadDefaultArchiveFormat()
      settingsModel.reloadKeymap()
      if ProcessInfo.processInfo.environment["PKPANE_UI_TESTING"] == "1" {
        RemoteEditController.shared.resetForUITesting()
      }
    }
    if testFolderPath != nil, let folderURL = try? makeUITestFolder() {
      try? FolderBookmarkRepository(
        storage: UserDefaultsFolderBookmarkStore(),
        codec: SystemFolderBookmarkCodec()
      ).save(folderURL)
    }
    if ProcessInfo.processInfo.arguments.contains("-ui-test-sftp-profile"),
      let target = try? SFTPConnectionTarget(
        host: "host-key-test.invalid",
        port: 22,
        username: "tester",
        initialDirectory: "/srv/projects")
    {
      SFTPConnectionProfileStore().save(target)
    }
    if ProcessInfo.processInfo.arguments.contains("-ui-test-favorite-location"),
      let folderURL = try? makeUITestFolder()
    {
      _ = try? FolderLocationListRepository(
        storage: UserDefaultsFolderLocationListStore(key: "favorite-folder-bookmarks"),
        codec: SystemFolderBookmarkCodec(),
        mode: .favorites
      ).add(folderURL.appending(path: "FavoriteFixture", directoryHint: .isDirectory))
    }
    if ProcessInfo.processInfo.arguments.contains("-ui-test-recent-nas-connection"),
      let connection = try? RecentSMBConnection(host: "ui-test.local", shareName: "TestShare")
    {
      RecentSMBConnectionStore().record(connection)
    }
    let transferPreferences = TransferPreferencesStore.shared.load()
    Task {
      await TransferRateLimiter.shared.setBytesPerSecond(
        transferPreferences.bandwidthLimitBytesPerSecond)
    }
  }

  private func resetUITestDefaultsIfNeeded() {
    guard ProcessInfo.processInfo.environment["PKPANE_UI_TESTING"] == "1",
      let defaults = UserDefaults(suiteName: "com.pky.PKPane.ui-tests")
    else {
      return
    }
    defaults.removePersistentDomain(forName: "com.pky.PKPane.ui-tests")
  }

  private var testFolderPath: String? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "-ui-test-folder-path"),
      arguments.indices.contains(index + 1)
    else {
      return nil
    }
    return arguments[index + 1]
  }

  private func makeUITestFolder() throws -> URL {
    let fileManager = FileManager.default
    // -ui-test-folder-pathが渡されていればその値(テストごとに一意な一時ディレクトリ)を
    // 使う。従来はこの値を無視して常に固定パスを使っていたため、過去のテスト実行の
    // 残骸ファイルが削除されず蓄積し続け、テスト間で意図しない状態共有が起きていた
    // (testFolderPathはnilチェックのためだけに参照され、値自体は使われていなかった)。
    let defaultFolderURL = fileManager.temporaryDirectory
      .appending(path: "PKPaneUITestFixture", directoryHint: .isDirectory)
    let folderURL = testFolderPath.map { URL(filePath: $0) } ?? defaultFolderURL
    let documentsURL = folderURL.appending(path: "Documents/caria", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
    if ProcessInfo.processInfo.arguments.contains("-ui-test-favorite-location") {
      try fileManager.createDirectory(
        at: folderURL.appending(path: "FavoriteFixture", directoryHint: .isDirectory),
        withIntermediateDirectories: true)
    }

    let linkURL = folderURL.appending(path: "caria-link", directoryHint: .notDirectory)
    if !fileManager.fileExists(atPath: linkURL.path) {
      try fileManager.createSymbolicLink(
        atPath: linkURL.path,
        withDestinationPath: "Documents/caria")
    }
    try fileManager.createDirectory(
      at: folderURL.appending(path: ".hidden-folder", directoryHint: .isDirectory),
      withIntermediateDirectories: true)

    let reportURL = folderURL.appending(path: "report.txt", directoryHint: .notDirectory)
    if !fileManager.fileExists(atPath: reportURL.path) {
      try Data("表示形式テスト".utf8).write(to: reportURL)
    }
    let deleteMeURL = folderURL.appending(path: "delete-me.txt", directoryHint: .notDirectory)
    if !fileManager.fileExists(atPath: deleteMeURL.path) {
      try Data("複数削除テスト".utf8).write(to: deleteMeURL)
    }
    let archiveURL = folderURL.appending(path: "archive.zip", directoryHint: .notDirectory)
    if ProcessInfo.processInfo.arguments.contains("-ui-test-zip-fixture") {
      try? fileManager.removeItem(at: archiveURL)
      let archive = try Archive(url: archiveURL, accessMode: .create)
      try archive.addEntry(with: "inside.txt", fileURL: reportURL, compressionMethod: .deflate)
    } else {
      try? fileManager.removeItem(at: archiveURL)
    }
    return folderURL
  }

  var body: some Scene {
    WindowGroup {
      LaunchView(
        appMenuModel: appMenuModel,
        applicationOpenRequestStore: appDelegate.applicationOpenRequestStore
      )
      .environment(\.themePalette, themeModel.palette)
    }
    // 初回起動時のウィンドウサイズ。最小サイズは LaunchView 側の frame(minWidth:minHeight:)
    // が別に定める(800x520)。この2つは意味が異なるため値を揃えないこと。
    .defaultSize(width: 1200, height: 760)
    .windowToolbarLabelStyle(fixed: .titleAndIcon)
    .commands {
      AppMenuCommands(model: appMenuModel)
    }

    WindowGroup("PKPane", id: FolderWindowRequest.sceneID, for: FolderWindowRequest.self) {
      request in
      LaunchView(
        initialFolderRequest: request.wrappedValue,
        appMenuModel: appMenuModel
      )
      .environment(\.themePalette, themeModel.palette)
    }
    .defaultSize(width: 1200, height: 760)
    .windowToolbarLabelStyle(fixed: .titleAndIcon)
    .commands {
      AppMenuCommands(model: appMenuModel)
    }

    Settings {
      PKPaneSettingsView(model: settingsModel)
        .environment(\.themePalette, themeModel.palette)
    }
  }
}

@MainActor
final class PKPaneAppDelegate: NSObject, NSApplicationDelegate {
  let applicationOpenRequestStore: ApplicationOpenRequestStore

  override init() {
    applicationOpenRequestStore = ApplicationOpenRequestStore()
    super.init()
  }

  init(applicationOpenRequestStore: ApplicationOpenRequestStore) {
    self.applicationOpenRequestStore = applicationOpenRequestStore
    super.init()
  }

  func applicationDidFinishLaunching(_: Notification) {
    let environment = ProcessInfo.processInfo.environment
    let preference =
      environment["PKPANE_UI_TESTING"] == "1"
        && environment["PKPANE_UI_TEST_APPEARANCE"] == "dark"
      ? AppAppearancePreference.dark
      : AppearancePreferencesStore().load()
    AppThemeApplier.apply(preference)
    Task {
      await RemotePreviewCache.shared.prepare()
    }
  }

  func application(_: NSApplication, open urls: [URL]) {
    applicationOpenRequestStore.receive(urls)
  }

  func applicationWillTerminate(_: Notification) {
    ArchiveExtractionCache.removeDefaultCacheDirectory()
  }

  func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
    guard RemoteEditController.shared.hasUnsyncedChanges else { return .terminateNow }
    let alert = NSAlert()
    alert.messageText = "未同期の外部編集があります"
    alert.informativeText = "作業コピーは保持され、次回起動後に同期を再開できます。"
    alert.addButton(withTitle: "作業コピーを保持して終了")
    alert.addButton(withTitle: "キャンセル")
    return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
  }
}
