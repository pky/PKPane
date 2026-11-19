import AppKit
import SwiftUI

struct SFTPConnectionFormView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: SFTPConnectionFormModel
  private let title: String
  private let confirmationTitle: String
  private let onSaved: (SFTPConnectionTarget) -> Void

  init(
    target: SFTPConnectionTarget? = nil,
    title: String = "SFTP接続",
    confirmationTitle: String = "保存",
    onSaved: @escaping (SFTPConnectionTarget) -> Void = { _ in }
  ) {
    _model = State(initialValue: SFTPConnectionFormModel.live(target: target))
    self.title = title
    self.confirmationTitle = confirmationTitle
    self.onSaved = onSaved
  }

  var body: some View {
    Form {
      SFTPConnectionFormFields(model: model)
    }
    .formStyle(.grouped)
    .padding()
    .frame(width: 420)
    .navigationTitle(title)
    .modifier(SFTPCredentialPromptPresentation(coordinator: model.credentialPrompter))
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("キャンセル") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button(confirmationTitle) {
          if let target = model.savePassword() {
            onSaved(target)
            dismiss()
          }
        }
      }
      ToolbarItem {
        Button("接続をテスト") {
          model.testConnection()
        }
        .disabled(model.isTestingConnection)
        .accessibilityIdentifier("sftp-connection-test")
      }
    }
  }
}

/// SFTP接続フォームの入力項目のみを切り出したビュー。ConnectPanelView(統合パネル)から
/// 差し込みとして再利用するため、シート枠・タイトル・ボタン行を持たない。
struct SFTPConnectionFormFields: View {
  @Environment(\.themePalette) private var themePalette
  @Bindable var model: SFTPConnectionFormModel

  var body: some View {
    Button("~/.ssh/config から追加…") {
      model.beginSSHConfigImport()
    }
    .accessibilityIdentifier("sftp-connection-import-ssh-config")
    .sheet(item: $model.sshConfigPicker) { picker in
      SSHConfigHostPickerSheet(model: picker) { result, folderURL in
        model.applyImport(result, folderURL: folderURL)
        model.sshConfigPicker = nil
      }
    }

    TextField("サーバー", text: $model.host)
      .accessibilityIdentifier("sftp-connection-host")
    TextField("ポート", text: $model.port)
      .accessibilityIdentifier("sftp-connection-port")
    TextField("ユーザー名", text: $model.username)
      .accessibilityIdentifier("sftp-connection-username")
    TextField("開始ディレクトリ", text: $model.startDirectory, prompt: Text("ホームディレクトリ"))
      .accessibilityIdentifier("sftp-connection-start-directory")
    SecureField("パスワード", text: $model.password)
      .accessibilityIdentifier("sftp-connection-password")
    HStack {
      if let privateKeyURL = model.privateKeyURL {
        Text(privateKeyURL.lastPathComponent)
          .lineLimit(1)
        Spacer()
        Button("解除") {
          model.privateKeyURL = nil
        }
      } else {
        Text("秘密鍵を指定していません")
          .foregroundStyle(.secondary)
        Spacer()
      }
      Button("秘密鍵を選択") {
        selectPrivateKey()
      }
      .accessibilityIdentifier("sftp-connection-private-key")
    }

    Section("踏み台") {
      ForEach(Array(model.jumpHosts.enumerated()), id: \.element.id) { index, draft in
        jumpHostFields(index: index, id: draft.id)
      }
      Button("踏み台を追加") { model.addJumpHost() }
        .accessibilityIdentifier("sftp-jump-host-add")
    }

    if !model.importWarnings.isEmpty {
      ForEach(Array(model.importWarnings.enumerated()), id: \.offset) { _, warning in
        Text(warning.displayText)
          .font(.caption)
          .foregroundStyle(themePalette.caution)
      }
    }

    if let errorMessage = model.errorMessage {
      Text(errorMessage)
        .foregroundStyle(themePalette.error)
    }
    if let testResultMessage = model.testResultMessage {
      Text(testResultMessage)
        .foregroundStyle(themePalette.success)
    }
  }

  @ViewBuilder
  private func jumpHostFields(index: Int, id: UUID) -> some View {
    // 行の削除後に古いBindingが参照されても、別の行へ書き込まない。
    let draft = Binding(
      get: { model.jumpHosts.first { $0.id == id } ?? SFTPJumpHostDraft() },
      set: { value in
        guard let currentIndex = model.jumpHosts.firstIndex(where: { $0.id == id }) else { return }
        model.jumpHosts[currentIndex] = value
      })
    let candidates = model.registeredJumpHostCandidates(excluding: id)
    HStack {
      Spacer()
      Menu("登録済みから選択") {
        ForEach(candidates) { candidate in
          Button(candidate.title) {
            model.applyRegisteredJumpHost(candidate, to: id)
          }
        }
      }
      .disabled(candidates.isEmpty)
      .accessibilityIdentifier("sftp-jump-host-\(index)-registered")
    }
    TextField("サーバー", text: draft.host)
      .accessibilityIdentifier("sftp-jump-host-\(index)-host")
    TextField("ポート", text: draft.port)
      .accessibilityIdentifier("sftp-jump-host-\(index)-port")
    TextField("ユーザー名", text: draft.username)
      .accessibilityIdentifier("sftp-jump-host-\(index)-username")
    SecureField("パスワード", text: draft.password)
      .accessibilityIdentifier("sftp-jump-host-\(index)-password")
    HStack {
      if let privateKeyURL = draft.wrappedValue.privateKeyURL {
        Text(privateKeyURL.lastPathComponent)
          .lineLimit(1)
        Button("解除") { draft.wrappedValue.privateKeyURL = nil }
          .accessibilityIdentifier("sftp-jump-host-\(index)-private-key-clear")
      } else {
        Text("秘密鍵を指定していません")
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("秘密鍵を選択") {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "選択")
        if panel.runModal() == .OK,
          let currentIndex = model.jumpHosts.firstIndex(where: { $0.id == id })
        {
          model.jumpHosts[currentIndex].privateKeyURL = panel.url
        }
      }
      .accessibilityIdentifier("sftp-jump-host-\(index)-private-key")
      Button("削除") { model.removeJumpHost(id: id) }
        .accessibilityIdentifier("sftp-jump-host-\(index)-remove")
    }
    Text("選んだ接続の資格情報(パスワード・鍵)がそのまま使われます")
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  private func selectPrivateKey() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.prompt = "選択"
    if panel.runModal() == .OK {
      model.privateKeyURL = panel.url
    }
  }
}

extension SFTPConnectionFormModel {
  static func live(target: SFTPConnectionTarget? = nil) -> SFTPConnectionFormModel {
    let repository = SSHDirectoryAccessRepository()
    let reader = SSHConfigReader(accessRepository: repository)
    return SFTPConnectionFormModel(
      target: target,
      sshConfigReader: reader,
      presentFolderPicker: {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = UserHomeDirectory.current.appending(
          path: ".ssh", directoryHint: .isDirectory)
        panel.title = String(localized: "~/.ssh フォルダを選択")
        panel.prompt = String(localized: "選択")
        return panel.runModal() == .OK ? panel.url : nil
      })
  }
}
