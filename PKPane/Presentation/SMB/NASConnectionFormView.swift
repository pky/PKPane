import SwiftUI

struct NASConnectionFormView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: NASConnectionFormModel
  private let title: LocalizedStringKey
  private let confirmationTitle: LocalizedStringKey
  private let submit: (NASConnectionProfile) -> Void

  init(
    profile: NASConnectionProfile? = nil,
    title: LocalizedStringKey = "NAS接続",
    confirmationTitle: LocalizedStringKey = "接続",
    submit: @escaping (NASConnectionProfile) -> Void = { _ in }
  ) {
    _model = State(initialValue: NASConnectionFormModel(profile: profile))
    self.title = title
    self.confirmationTitle = confirmationTitle
    self.submit = submit
  }

  var body: some View {
    Form {
      NASConnectionFormFields(model: model)
    }
    .formStyle(.grouped)
    .padding()
    .frame(width: 420)
    .navigationTitle(title)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("キャンセル") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button(confirmationTitle) {
          if let profile = model.makeProfile() {
            submit(profile)
            dismiss()
          }
        }
      }
    }
  }
}

/// NAS接続フォームの入力項目のみを切り出したビュー。ConnectPanelView(統合パネル)から
/// 差し込みとして再利用するため、シート枠・タイトル・ボタン行を持たない。
struct NASConnectionFormFields: View {
  @Environment(\.themePalette) private var themePalette
  @Bindable var model: NASConnectionFormModel

  var body: some View {
    TextField("接続名", text: $model.displayName, prompt: Text("空欄なら自動設定"))
      .accessibilityIdentifier("nas-connection-name")
    TextField("サーバー", text: $model.host, prompt: Text("nas.local または smb://nas.local/共有名"))
      .accessibilityIdentifier("nas-connection-host")
    TextField("共有名", text: $model.shareName, prompt: Text("空欄なら接続時に共有を選択"))
      .accessibilityIdentifier("nas-connection-share")
    Text("共有名を空欄にすると、接続時にmacOSの画面で共有フォルダを選べます。smb://サーバー/共有名の形式で入力すると共有名を自動設定します。")
      .font(.caption)
      .foregroundStyle(.secondary)

    if let errorMessage = model.errorMessage {
      Text(errorMessage)
        .foregroundStyle(themePalette.error)
    }
    if let testResultMessage = model.testResultMessage {
      Text(testResultMessage)
        .foregroundStyle(themePalette.success)
    }
  }
}
