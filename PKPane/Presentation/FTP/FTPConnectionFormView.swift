import SwiftUI

struct FTPConnectionFormView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: FTPConnectionFormModel
  private let title: String
  private let confirmationTitle: String
  private let onSaved: (FTPConnectionTarget) -> Void

  init(
    target: FTPConnectionTarget? = nil,
    title: String = "FTP/FTPS接続",
    confirmationTitle: String = "保存",
    onSaved: @escaping (FTPConnectionTarget) -> Void = { _ in }
  ) {
    _model = State(initialValue: FTPConnectionFormModel(target: target))
    self.title = title
    self.confirmationTitle = confirmationTitle
    self.onSaved = onSaved
  }

  var body: some View {
    Form {
      FTPConnectionFormFields(model: model)
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
          if let target = model.savePassword() {
            onSaved(target)
            dismiss()
          }
        }
      }
      ToolbarItem {
        Button("接続をテスト") { model.testConnection() }
          .disabled(model.isTestingConnection)
          .accessibilityIdentifier("ftp-connection-test")
      }
    }
  }
}

struct FTPConnectionFormFields: View {
  @Environment(\.themePalette) private var themePalette
  @Bindable var model: FTPConnectionFormModel

  var body: some View {
    Picker("接続方式", selection: $model.security) {
      ForEach(FTPConnectionSecurity.allCases, id: \.self) { security in
        Text(security.displayName).tag(security)
      }
    }
    .pickerStyle(.segmented)
    .accessibilityIdentifier("ftp-connection-security")
    TextField("サーバー", text: $model.host)
      .accessibilityIdentifier("ftp-connection-host")
    TextField("ポート", text: $model.port)
      .accessibilityIdentifier("ftp-connection-port")
    TextField("ユーザー名", text: $model.username)
      .accessibilityIdentifier("ftp-connection-username")
    TextField("開始ディレクトリ", text: $model.startDirectory)
      .accessibilityIdentifier("ftp-connection-start-directory")
    SecureField("パスワード", text: $model.password)
      .accessibilityIdentifier("ftp-connection-password")

    if let warning = model.security.warningMessage {
      Label(warning, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(themePalette.warning)
        .accessibilityIdentifier("ftp-unencrypted-warning")
    }
    if let errorMessage = model.errorMessage {
      Text(errorMessage).foregroundStyle(themePalette.error)
    }
    if let testResultMessage = model.testResultMessage {
      Text(testResultMessage).foregroundStyle(themePalette.success)
    }
  }
}
