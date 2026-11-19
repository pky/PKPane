import AppKit
import Observation
import SwiftUI

enum PKPaneSettingsTab: String, CaseIterable, Identifiable {
  case general
  case transfer
  case keyboard
  case licenses

  var id: Self { self }

  var title: String {
    switch self {
    case .general:
      String(localized: "一般")
    case .transfer:
      String(localized: "転送")
    case .keyboard:
      String(localized: "キーボード")
    case .licenses:
      String(localized: "ライセンス")
    }
  }

  var systemImage: String {
    switch self {
    case .general:
      "gearshape"
    case .transfer:
      "arrow.left.arrow.right"
    case .keyboard:
      "keyboard"
    case .licenses:
      "doc.text"
    }
  }
}

@Observable
@MainActor
final class PKPaneSettingsModel {
  private(set) var appearancePreference: AppAppearancePreference
  private let themeModel: AppThemeModel
  private let appearanceStore: AppearancePreferencesStore
  private let applyAppearance: @MainActor (NSAppearance.Name?) -> Void
  private let transferPreferencesStore: TransferPreferencesStore
  private let transferRateLimiter: TransferRateLimiter
  private let archivePreferencesStore: ArchivePreferencesStore
  private let keymapStore: KeymapPreferencesStore
  private let menuShortcutInventory: Set<KeymapShortcut>
  private let cacheDirectories: [URL]
  private let removeArchiveCache: @Sendable () async -> Void
  private let removeRemotePreviewCache: @Sendable () async -> Void
  private let removeThumbnailCache: @MainActor () -> Void
  private let removeIconCache: @MainActor () -> Void
  private(set) var keymap: KeyboardCommandMap
  private(set) var keymapValidationMessage: String?
  private(set) var defaultArchiveFormat: ArchiveFormat
  private(set) var cacheUsageBytes: UInt64?
  private(set) var isDeletingCaches = false
  private var cacheUsageGeneration = UUID()

  init(
    appearanceStore: AppearancePreferencesStore = AppearancePreferencesStore(),
    applyAppearance: @escaping @MainActor (NSAppearance.Name?) -> Void = { name in
      AppThemeApplier.applyAppearance(named: name)
    },
    transferPreferencesStore: TransferPreferencesStore = .shared,
    transferRateLimiter: TransferRateLimiter = .shared,
    archivePreferencesStore: ArchivePreferencesStore = .shared,
    keymapStore: KeymapPreferencesStore = .shared,
    menuShortcutInventory: Set<KeymapShortcut> = AppMenuCommands.shortcutInventory,
    cacheDirectories: [URL] = [
      ArchiveExtractionCache.defaultRootURL(), RemotePreviewCache.defaultRootURL(),
    ],
    removeArchiveCache: @escaping @Sendable () async -> Void = {
      await ArchiveExtractionCache.shared.removeAll()
    },
    removeRemotePreviewCache: @escaping @Sendable () async -> Void = {
      await RemotePreviewCache.shared.removeAll()
    },
    removeThumbnailCache: @escaping @MainActor () -> Void = {
      FileThumbnailService.shared.removeAll()
    },
    removeIconCache: @escaping @MainActor () -> Void = {
      FileIconProvider.shared.removeAll()
    },
    themeModel: AppThemeModel = .shared
  ) {
    self.themeModel = themeModel
    self.appearanceStore = appearanceStore
    self.applyAppearance = applyAppearance
    self.transferPreferencesStore = transferPreferencesStore
    self.transferRateLimiter = transferRateLimiter
    self.archivePreferencesStore = archivePreferencesStore
    self.keymapStore = keymapStore
    self.menuShortcutInventory = menuShortcutInventory
    self.cacheDirectories = cacheDirectories
    self.removeArchiveCache = removeArchiveCache
    self.removeRemotePreviewCache = removeRemotePreviewCache
    self.removeThumbnailCache = removeThumbnailCache
    self.removeIconCache = removeIconCache
    appearancePreference = appearanceStore.load()
    defaultArchiveFormat = archivePreferencesStore.defaultFormat
    keymap = keymapStore.current
  }

  var bandwidthLimitBytesPerSecond: Int64? {
    transferPreferencesStore.current.bandwidthLimitBytesPerSecond
  }

  func refreshCacheUsage() async {
    guard !isDeletingCaches else { return }
    let generation = UUID()
    cacheUsageGeneration = generation
    cacheUsageBytes = nil
    let bytes = await CacheDiskUsage.totalBytes(in: cacheDirectories)
    guard cacheUsageGeneration == generation else { return }
    cacheUsageBytes = bytes
  }

  func deleteCaches() async {
    guard !isDeletingCaches else { return }
    isDeletingCaches = true
    let generation = UUID()
    cacheUsageGeneration = generation
    cacheUsageBytes = nil
    async let archiveRemoval: Void = removeArchiveCache()
    async let remotePreviewRemoval: Void = removeRemotePreviewCache()
    _ = await (archiveRemoval, remotePreviewRemoval)
    removeThumbnailCache()
    removeIconCache()
    cacheUsageBytes = await CacheDiskUsage.totalBytes(in: cacheDirectories)
    isDeletingCaches = false
  }

  func setAppearancePreference(_ preference: AppAppearancePreference) {
    appearancePreference = preference
    appearanceStore.save(preference)
    applyCurrentAppearance()
  }

  /// `AppearancePreferencesStore`を直接`save`または`remove`した呼び出し元は、
  /// モデルの表示値を同期するため、ストア操作後に必ずこのメソッドを呼ぶこと。
  func reloadAppearancePreference() {
    appearancePreference = appearanceStore.load()
  }

  func setDefaultArchiveFormat(_ format: ArchiveFormat) {
    defaultArchiveFormat = format
    archivePreferencesStore.save(format)
  }

  func reloadDefaultArchiveFormat() {
    defaultArchiveFormat = archivePreferencesStore.defaultFormat
  }

  func setBandwidthLimitBytesPerSecond(_ value: Int64?) {
    let normalized = TransferBandwidthOptions.normalized(value)
    transferPreferencesStore.save(
      TransferPreferences(bandwidthLimitBytesPerSecond: normalized))
    Task { [transferRateLimiter] in
      await transferRateLimiter.setBytesPerSecond(normalized)
    }
  }

  @discardableResult
  func assignShortcut(_ shortcut: KeymapShortcut, to command: KeyboardCommand) -> Bool {
    saveKeymap(keymap.replacingBindings(for: command, with: shortcut))
  }

  @discardableResult
  func restoreDefaultShortcut(for command: KeyboardCommand) -> Bool {
    saveKeymap(keymap.restoringDefault(for: command))
  }

  func restoreAllDefaultShortcuts() {
    keymapStore.remove()
    keymap = keymapStore.current
    keymapValidationMessage = nil
  }

  func reloadKeymap() {
    keymap = keymapStore.current
    keymapValidationMessage = nil
  }

  func shortcutDisplayText(for command: KeyboardCommand) -> String {
    keymap.bindings(for: command).map(\.shortcut.displayText).joined(separator: " / ")
  }

  func menuConflictMessage(for command: KeyboardCommand) -> String? {
    guard keymap.bindings(for: command) != KeyboardCommandMap.defaults.bindings(for: command)
    else {
      return nil
    }
    let conflictingShortcuts = keymap.bindings(for: command)
      .map(\.shortcut)
      .filter(menuShortcutInventory.contains)
    guard !conflictingShortcuts.isEmpty else { return nil }
    let shortcuts = conflictingShortcuts.map(\.displayText).joined(separator: "、")
    return String.localizedStringWithFormat(
      String(localized: "%@ はメニューバーのショートカットと重複しています。メニューが優先されます。"),
      shortcuts)
  }

  private func applyCurrentAppearance() {
    AppThemeApplier.apply(
      appearancePreference, to: themeModel, applyAppearance: applyAppearance)
  }

  private func saveKeymap(_ candidate: KeyboardCommandMap) -> Bool {
    switch keymapStore.save(candidate) {
    case .saved:
      keymap = keymapStore.current
      keymapValidationMessage = nil
      return true
    case .duplicate(let conflicts):
      let shortcuts = conflicts.map(\.shortcut.displayText).joined(separator: "、")
      keymapValidationMessage = String.localizedStringWithFormat(
        String(localized: "%@ は別の一覧操作に割り当て済みです。"),
        shortcuts)
      return false
    case .encodingFailed:
      keymapValidationMessage = String(localized: "キー割り当てを保存できませんでした。")
      return false
    }
  }
}

struct PKPaneSettingsView: View {
  static let tabs = PKPaneSettingsTab.allCases

  let model: PKPaneSettingsModel
  @State private var selectedTab: PKPaneSettingsTab = .general

  var body: some View {
    TabView(selection: $selectedTab) {
      ForEach(Self.tabs) { tab in
        tabContent(tab)
          .tabItem {
            Label(tab.title, systemImage: tab.systemImage)
          }
          .tag(tab)
      }
    }
    .frame(
      width: selectedTab == .keyboard ? 620 : 520,
      height: preferredHeight)
  }

  @ViewBuilder
  private func tabContent(_ tab: PKPaneSettingsTab) -> some View {
    switch tab {
    case .general:
      GeneralSettingsView(model: model)
    case .transfer:
      TransferSettingsView(model: model)
    case .keyboard:
      KeyboardSettingsView(model: model)
    case .licenses:
      ThirdPartyLicensesView()
    }
  }

  private var preferredHeight: Double {
    switch selectedTab {
    case .general:
      500
    case .transfer:
      220
    case .keyboard:
      420
    case .licenses:
      500
    }
  }
}

struct GeneralSettingsView: View {
  @Environment(\.themePalette) private var themePalette
  static let cacheSectionTitle = String(localized: "キャッシュ")
  static let cacheDeleteButtonTitle = String(localized: "キャッシュを削除")
  static let cacheDescription = String(localized: "再取得可能なキャッシュのみ削除します。")

  let model: PKPaneSettingsModel
  @State private var sshConfigAccessModel = SSHConfigAccessSettingsModel.live()

  var body: some View {
    Form {
      Picker("外観", selection: appearanceSelection) {
        ForEach(AppAppearancePreference.allCases) { preference in
          Text(preference.displayName)
            .tag(preference)
        }
      }
      .pickerStyle(.segmented)
      Section("アーカイブ") {
        Picker("既定の作成形式", selection: archiveFormatSelection) {
          ForEach(ArchiveFormat.creationFormats, id: \.self) { format in
            Text(format.displayName)
              .tag(format)
          }
        }
        .pickerStyle(.segmented)
      }
      Section(Self.cacheSectionTitle) {
        LabeledContent("使用容量") {
          Text(cacheUsageText)
        }
        Text(Self.cacheDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
        Button(Self.cacheDeleteButtonTitle) {
          Task {
            await model.deleteCaches()
          }
        }
        .disabled(model.isDeletingCaches)
      }
      Section("SSH設定ファイル") {
        Text(sshConfigAccessStatusText)
        if let errorMessage = sshConfigAccessModel.errorMessage {
          Text(errorMessage)
            .foregroundStyle(themePalette.error)
        }
        HStack {
          Button("フォルダを選択…") {
            chooseSSHConfigFolder()
          }
          if sshConfigAccessModel.state != .direct {
            Button("解除") {
              sshConfigAccessModel.revoke()
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .padding()
    .task {
      await model.refreshCacheUsage()
    }
    .onAppear {
      sshConfigAccessModel.refresh()
    }
  }

  var appearanceSelection: Binding<AppAppearancePreference> {
    Binding(
      get: { model.appearancePreference },
      set: { model.setAppearancePreference($0) })
  }

  var archiveFormatSelection: Binding<ArchiveFormat> {
    Binding(
      get: { model.defaultArchiveFormat },
      set: { model.setDefaultArchiveFormat($0) })
  }

  var cacheUsageText: String {
    guard let bytes = model.cacheUsageBytes else { return String(localized: "計測中…") }
    return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
  }

  private var sshConfigAccessStatusText: String {
    switch sshConfigAccessModel.state {
    case .direct:
      String(localized: "例外許可で読み取り中")
    case .bookmarked(let url):
      String.localizedStringWithFormat(
        String(localized: "%@ を選択済み"), url.lastPathComponent)
    case .unavailable:
      String(localized: "未設定")
    }
  }

  private func chooseSSHConfigFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.directoryURL = UserHomeDirectory.current.appending(
      path: ".ssh", directoryHint: .isDirectory)
    panel.prompt = String(localized: "選択")
    guard panel.runModal() == .OK, let folderURL = panel.url else { return }
    sshConfigAccessModel.chooseFolder(folderURL)
  }
}

struct TransferSettingsView: View {
  let model: PKPaneSettingsModel

  var body: some View {
    Form {
      Picker("帯域制限", selection: bandwidthLimitSelection) {
        ForEach(TransferBandwidthOptions.values, id: \.self) { bytesPerSecond in
          Text(TransferBandwidthOptions.label(for: bytesPerSecond))
            .tag(bytesPerSecond)
        }
      }
      Text("すべての転送を合計した速度へ即時に適用します。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
    .padding()
  }

  var bandwidthLimitSelection: Binding<Int64> {
    Binding(
      get: { model.bandwidthLimitBytesPerSecond ?? 0 },
      set: { model.setBandwidthLimitBytesPerSecond($0 == 0 ? nil : $0) })
  }
}

struct KeyboardSettingsView: View {
  @Environment(\.themePalette) private var themePalette
  let model: PKPaneSettingsModel
  @State private var selectedCommand: KeyboardCommand? = KeyboardCommand.allCases.first
  @State private var isRecording = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      List(selection: $selectedCommand) {
        ForEach(KeyboardCommand.allCases) { command in
          HStack {
            Text(command.displayName)
            Spacer()
            Text(model.shortcutDisplayText(for: command))
              .foregroundStyle(.secondary)
          }
          .tag(command)
        }
      }

      if let message = model.keymapValidationMessage {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(themePalette.error)
      } else if let selectedCommand,
        let message = model.menuConflictMessage(for: selectedCommand)
      {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(themePalette.warning)
      }

      Text("録音すると、現在の割り当てをすべて新しい1件へ置き換えます。「開く」の⌘O / ⌘↓も録音後は新しい1件だけになります。")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack {
        Button(isRecording ? "キーを入力してください…" : "新しいキーを録音") {
          isRecording = true
        }
        .disabled(selectedCommand == nil || isRecording)

        Button("録音をキャンセル") {
          isRecording = false
        }
        .disabled(!isRecording)

        Button("選択を既定に戻す") {
          if let selectedCommand {
            _ = model.restoreDefaultShortcut(for: selectedCommand)
          }
        }
        .disabled(selectedCommand == nil || isRecording)

        Spacer()

        Button("すべて既定に戻す") {
          model.restoreAllDefaultShortcuts()
        }
        .disabled(isRecording)
      }
    }
    .padding()
    .background(
      KeyboardShortcutRecorder(isRecording: $isRecording) { shortcut in
        guard let selectedCommand else { return }
        _ = record(shortcut, for: selectedCommand)
      })
  }

  @discardableResult
  func record(_ shortcut: KeymapShortcut, for command: KeyboardCommand) -> Bool {
    model.assignShortcut(shortcut, to: command)
  }
}
