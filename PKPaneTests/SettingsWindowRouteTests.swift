import AppKit
import Foundation
import Synchronization
import Testing

@testable import PKPane

@MainActor
struct SettingsWindowRouteTests {
  @Test("一般タブでクリームを選ぶと保存してAquaを即時適用する")
  func creamSelectionReachesStoreAndApplication() {
    let suiteName = "SettingsWindowRouteTests-cream-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AppearancePreferencesStore(defaults: defaults)
    var appliedNames: [NSAppearance.Name?] = []
    let model = PKPaneSettingsModel(
      appearanceStore: store,
      applyAppearance: { appliedNames.append($0) })
    let generalTab = GeneralSettingsView(model: model)

    generalTab.appearanceSelection.wrappedValue = .cream

    #expect(model.appearancePreference == .cream)
    #expect(defaults.string(forKey: "appearance-preference") == "cream")
    #expect(store.load() == .cream)
    #expect(appliedNames == [.aqua])
  }

  @Test("一般タブの外観変更を注入したテーマモデルへ反映しライトで元に戻す")
  func appearanceSelectionUpdatesInjectedThemeModel() {
    let suiteName = "SettingsWindowRouteTests-theme-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AppearancePreferencesStore(defaults: defaults)
    let themeModel = AppThemeModel()
    let model = PKPaneSettingsModel(
      appearanceStore: store,
      applyAppearance: { _ in },
      themeModel: themeModel)
    let generalTab = GeneralSettingsView(model: model)

    generalTab.appearanceSelection.wrappedValue = .cream
    #expect(themeModel.palette == .cream)

    generalTab.appearanceSelection.wrappedValue = .light
    #expect(themeModel.palette == .standard)
    #expect(store.load() == .light)
  }

  @Test("設定シーンは一般・転送・キーボード・ライセンスの4タブを公開する")
  func exposesInitialTabs() {
    #expect(PKPaneSettingsView.tabs == [.general, .transfer, .keyboard, .licenses])
  }

  @Test("実行時依存のライセンス文書を設定画面から参照できる")
  func exposesRuntimeDependencyLicenses() throws {
    let repositoryRoot = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let licensesRoot = repositoryRoot.appending(path: "PKPane/ThirdPartyLicenses")
    let resourceNames = Set(ThirdPartyLicenseEntry.all.map(\.resourceName))

    #expect(resourceNames.count == ThirdPartyLicenseEntry.all.count)
    #expect(resourceNames.contains("Citadel-LICENSE"))
    #expect(resourceNames.contains("UnRAR-LICENSE"))
    #expect(resourceNames.contains("SwiftCrypto-LICENSE"))
    for resourceName in resourceNames {
      #expect(
        FileManager.default.fileExists(
          atPath: licensesRoot.appending(path: "\(resourceName).txt").path))
    }
  }

  @Test("一般タブの外観Pickerからモデルとストアを経て即時適用する")
  func generalTabBindingReachesStoreAndApplication() {
    let suiteName = "SettingsWindowRouteTests-general-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AppearancePreferencesStore(defaults: defaults)
    var appliedNames: [NSAppearance.Name?] = []
    let model = PKPaneSettingsModel(
      appearanceStore: store,
      applyAppearance: { appliedNames.append($0) })
    let generalTab = GeneralSettingsView(model: model)

    generalTab.appearanceSelection.wrappedValue = .dark

    #expect(model.appearancePreference == .dark)
    #expect(store.load() == .dark)
    #expect(appliedNames == [.darkAqua])
  }

  @Test("一般タブの既定アーカイブ形式が保存されメニュー実行経路へ届く")
  func archiveFormatBindingReachesMenuCommand() throws {
    let suiteName = "SettingsWindowRouteTests-archive-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let archiveStore = ArchivePreferencesStore(defaults: defaults)
    let settingsModel = PKPaneSettingsModel(
      appearanceStore: AppearancePreferencesStore(defaults: defaults),
      applyAppearance: { _ in },
      archivePreferencesStore: archiveStore)
    let generalTab = GeneralSettingsView(model: settingsModel)
    let menuModel = AppMenuModel(archivePreferencesStore: archiveStore)
    var actions: [FileBrowserCommand.Action] = []
    menuModel.register(
      context: AppMenuContext(
        isBrowserAvailable: true,
        selectedItemCount: 1,
        canArchive: true)
    ) { actions.append($0) }

    #expect(archiveStore.defaultFormat == .zip)
    generalTab.archiveFormatSelection.wrappedValue = .sevenZip

    #expect(settingsModel.defaultArchiveFormat == .sevenZip)
    #expect(archiveStore.defaultFormat == .sevenZip)
    #expect(ArchivePreferencesStore(defaults: defaults).defaultFormat == .sevenZip)
    #expect(menuModel.menuTitle(for: .createArchive) == "選択項目を7zに圧縮")
    #expect(menuModel.alternateArchiveMenuTitle == "選択項目をZIPに圧縮")
    #expect(menuModel.archiveCreationFormats == [.sevenZip, .zip])

    menuModel.perform(.createArchive)
    menuModel.performCreateArchive(format: menuModel.alternateArchiveFormat)

    try #require(actions.count == 2)
    guard case .createArchive(format: .sevenZip) = actions[0] else {
      Issue.record("設定した7z形式がメニュー実行へ届いていません")
      return
    }
    guard case .createArchive(format: .zip) = actions[1] else {
      Issue.record("非既定のZIP形式がメニュー実行へ届いていません")
      return
    }
  }

  @Test("一般タブのキャッシュ目録は容量・説明・削除操作を公開する")
  func exposesCacheSectionInventory() {
    #expect(GeneralSettingsView.cacheSectionTitle == "キャッシュ")
    #expect(GeneralSettingsView.cacheDeleteButtonTitle == "キャッシュを削除")
    #expect(GeneralSettingsView.cacheDescription == "再取得可能なキャッシュのみ削除します。")
  }

  @Test("キャッシュ容量を実体から合算し削除後は4種の処理を経て0になる")
  func measuresAndDeletesOnlyConfiguredCaches() async throws {
    let base = FileManager.default.temporaryDirectory
      .appending(path: "settings-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: base) }
    let archiveRoot = base.appending(path: "ArchivePreviews", directoryHint: .isDirectory)
    let remoteRoot = base.appending(path: "RemotePreviews", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: archiveRoot.appending(path: "nested", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 3).write(to: archiveRoot.appending(path: "nested/a.cache"))
    try Data(repeating: 2, count: 5).write(to: remoteRoot.appending(path: ".remote.cache"))
    let calls = Mutex<Set<String>>([])
    let suiteName = "SettingsWindowRouteTests-cache-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = PKPaneSettingsModel(
      appearanceStore: AppearancePreferencesStore(defaults: defaults),
      applyAppearance: { _ in },
      transferPreferencesStore: TransferPreferencesStore(defaults: defaults),
      transferRateLimiter: TransferRateLimiter(),
      keymapStore: KeymapPreferencesStore(defaults: defaults),
      cacheDirectories: [archiveRoot, remoteRoot],
      removeArchiveCache: {
        calls.withLock { _ = $0.insert("archive") }
        try? FileManager.default.removeItem(at: archiveRoot)
      },
      removeRemotePreviewCache: {
        calls.withLock { _ = $0.insert("remote") }
        try? FileManager.default.removeItem(at: remoteRoot)
      },
      removeThumbnailCache: {
        calls.withLock { _ = $0.insert("thumbnail") }
      },
      removeIconCache: {
        calls.withLock { _ = $0.insert("icon") }
      })

    await model.refreshCacheUsage()

    #expect(model.cacheUsageBytes == 8)
    #expect(
      GeneralSettingsView(model: model).cacheUsageText
        == ByteCountFormatter.string(fromByteCount: 8, countStyle: .file))

    await model.deleteCaches()

    #expect(model.cacheUsageBytes == 0)
    #expect(calls.withLock { $0 } == ["archive", "remote", "thumbnail", "icon"])
  }

  @Test("AppMenuCommandsは標準設定メニューを置き換えない")
  func preservesStandardSettingsMenu() throws {
    let repositoryRoot = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = repositoryRoot.appending(path: "PKPane/App/AppMenuCommands.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let replacementPattern = #"CommandGroup\s*\(\s*replacing:\s*\.appSettings\b"#

    #expect(source.range(of: replacementPattern, options: .regularExpression) == nil)
  }

  @Test("転送タブは承認済みの帯域制限候補をすべて公開する")
  func exposesEveryBandwidthOption() {
    #expect(
      TransferBandwidthOptions.values
        == [0, 1_000_000, 5_000_000, 10_000_000, 25_000_000, 50_000_000])
  }

  @Test("設定タブと転送バーの帯域変更を共有ストア経由で双方向反映する")
  func transferTabAndActivityBarReflectEachOther() async throws {
    let suiteName = "SettingsWindowRouteTests-transfer-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transferStore = TransferPreferencesStore(defaults: defaults)
    let limiter = TransferRateLimiter()
    let settingsModel = PKPaneSettingsModel(
      appearanceStore: AppearancePreferencesStore(defaults: defaults),
      applyAppearance: { _ in },
      transferPreferencesStore: transferStore,
      transferRateLimiter: limiter)
    let activityModel = TransferActivityModel(
      transferQueue: TransferQueue(store: SettingsRouteTransferJobStore()),
      rateLimiter: limiter,
      preferencesStore: transferStore)
    let transferTab = TransferSettingsView(model: settingsModel)
    let activityBar = TransferActivityBar(model: activityModel)

    transferTab.bandwidthLimitSelection.wrappedValue = 25_000_000
    await waitForLimiter(limiter, expected: 25_000_000)
    #expect(activityModel.bandwidthLimitBytesPerSecond == 25_000_000)
    #expect(limiter.currentBytesPerSecond() == 25_000_000)

    activityBar.bandwidthLimitSelection.wrappedValue = 5_000_000
    await waitForLimiter(limiter, expected: 5_000_000)
    #expect(settingsModel.bandwidthLimitBytesPerSecond == 5_000_000)
    #expect(transferTab.bandwidthLimitSelection.wrappedValue == 5_000_000)
    #expect(
      transferStore.load()
        == TransferPreferences(bandwidthLimitBytesPerSecond: 5_000_000))
  }

  @Test("キーボードタブの録音経路がストアを通じてルーターへ即時反映する")
  func keyboardTabRecordingReachesRouterThroughStore() {
    let suiteName = "SettingsWindowRouteTests-keymap-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let keymapStore = KeymapPreferencesStore(defaults: defaults)
    let model = PKPaneSettingsModel(
      appearanceStore: AppearancePreferencesStore(defaults: defaults),
      applyAppearance: { _ in },
      keymapStore: keymapStore,
      menuShortcutInventory: AppMenuCommands.shortcutInventory)
    let keyboardTab = KeyboardSettingsView(model: model)
    let shortcut = KeymapShortcut(key: "u", modifiers: [.control, .option])

    #expect(keyboardTab.record(shortcut, for: .refresh))

    #expect(keymapStore.current.bindings(for: .refresh).map(\.shortcut) == [shortcut])
    #expect(
      KeyboardCommandRouter.command(
        characters: "u",
        modifiers: [.control, .option],
        handlesListCommands: true,
        keymap: keymapStore.current) == .refresh)
    #expect(
      KeyboardCommandRouter.command(
        characters: "r",
        modifiers: [.control],
        handlesListCommands: true,
        keymap: keymapStore.current) == nil)
  }

  @Test("キーボードタブは重複をインライン表示しメニュー衝突を警告に留める")
  func keyboardTabShowsDuplicateAndMenuConflictMessages() {
    let suiteName = "SettingsWindowRouteTests-keymap-message-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let menuShortcut = KeymapShortcut(key: "q", modifiers: [.command])
    let defaultOpenShortcut = KeymapShortcut(key: "o", modifiers: [.command])
    let model = PKPaneSettingsModel(
      appearanceStore: AppearancePreferencesStore(defaults: defaults),
      applyAppearance: { _ in },
      keymapStore: KeymapPreferencesStore(defaults: defaults),
      menuShortcutInventory: [menuShortcut, defaultOpenShortcut])
    let keyboardTab = KeyboardSettingsView(model: model)

    #expect(model.menuConflictMessage(for: .open) == nil)
    #expect(keyboardTab.record(menuShortcut, for: .refresh))
    #expect(model.menuConflictMessage(for: .refresh)?.contains("メニューが優先") == true)

    let duplicate = KeymapShortcut(key: "n", modifiers: [.control])
    #expect(!keyboardTab.record(duplicate, for: .refresh))
    #expect(model.keymapValidationMessage?.contains("割り当て済み") == true)
  }

  private func waitForLimiter(_ limiter: TransferRateLimiter, expected: Int64?) async {
    await waitUntil("帯域制限値が期限内に期待値にならなかった") {
      limiter.currentBytesPerSecond() == expected
    }
  }
}

private final class SettingsRouteTransferJobStore: TransferJobStore, @unchecked Sendable {
  func load() throws -> [TransferJob] { [] }
  func save(_: [TransferJob]) throws {}
}
