import SwiftUI

struct SFTPCredentialPromptPresentation: ViewModifier {
  let coordinator: SFTPCredentialPromptCoordinator

  func body(content: Content) -> some View {
    content.onDisappear { coordinator.cancelAll() }
      .sheet(
        item: Binding(
          get: { coordinator.current },
          // シートの切替終了通知で、次の要求をキャンセルしない。
          set: { _ in })
      ) { item in
        SFTPCredentialPromptSheet(item: item, coordinator: coordinator)
          .id(item.id)
      }
  }
}

struct SFTPCredentialPromptSheet: View {
  let item: SFTPCredentialPromptItem
  let coordinator: SFTPCredentialPromptCoordinator
  @State private var secret = ""
  @State private var saveToKeychain = true

  private var title: String {
    let request = item.request
    let name =
      request.label
      ?? "\(request.hop.username)@\(request.hop.host):\(request.hop.port)"
    switch request.kind {
    case .password: return name + String(localized: "のパスワード")
    case .passphrase: return name + String(localized: "の鍵のパスフレーズ")
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title)
        .font(.headline)
      SecureField(
        item.request.kind == .password ? String(localized: "パスワード") : String(localized: "鍵のパスフレーズ"),
        text: $secret
      )
      .onSubmit { submit() }
      Toggle("Keychain に保存", isOn: $saveToKeychain)
      HStack {
        Spacer()
        Button("キャンセル") {
          if coordinator.current?.id == item.id { coordinator.cancel() }
        }
        .keyboardShortcut(.cancelAction)
        Button("接続") { submit() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding()
    .frame(width: 420)
    .interactiveDismissDisabled()
    .onDisappear {
      if coordinator.current?.id == item.id { coordinator.cancel() }
    }
  }

  private func submit() {
    guard coordinator.current?.id == item.id else { return }
    coordinator.submit(secret: secret, saveToKeychain: saveToKeychain)
  }
}
