import SwiftUI

/// Connect Panelで選択可能な接続プロトコル。将来のプロトコル追加(S3等)を見越して
/// 配列駆動(allCases)でセグメントを組み立てる。
enum ConnectPanelProtocol: String, CaseIterable, Identifiable {
  case nas
  case sftp
  case ftp

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .nas: "NAS (SMB)"
    case .sftp: "SFTP"
    case .ftp: "FTP/FTPS"
    }
  }
}

/// Connect Panelの開始画面。⌘Kは一覧モード、⌘⇧Kのようなプロトコル直行の導線は
/// フォームモードで開く(この場合キャンセルはパネル全体を閉じる。一覧から
/// 「新規接続…」で遷移した場合はキャンセルの代わりに「戻る」で一覧へ戻る)。
enum ConnectPanelEntryMode: Equatable {
  case list
  case form(ConnectPanelProtocol)
}

/// NAS/SFTP/FTPの接続管理を1つのシートへ統合したConnect Panel(⌘K)。
/// 「接続一覧モード(検索付き)」と「新規接続フォームモード」の二部構成。
/// フォームの入力項目はプロトコルごとの既存モデルを差し込む。検証・ホスト鍵承認・
/// Keychain保存の挙動は各モデルに委譲したまま変えない。接続・編集・削除は既存の
/// 各ConnectionListModelを経由するため、一覧・サイドバーの両方が追従する。
struct ConnectPanelView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var mode: ConnectPanelEntryMode
  @State private var enteredFormDirectly: Bool
  @State private var nasModel = NASConnectionFormModel()
  @State private var sftpModel = SFTPConnectionFormModel.live()
  @State private var ftpModel = FTPConnectionFormModel()
  @State private var searchText = ""
  @State private var selectedRowID: String?
  @State private var pendingDeletion: ConnectPanelPendingDeletion?

  private let nasConnections: NASConnectionListModel
  private let sftpConnections: SFTPConnectionListModel
  private let ftpConnections: FTPConnectionListModel
  private let onSavedNAS: (NASConnectionProfile) -> Void
  private let onSavedSFTP: (SFTPConnectionTarget) -> Void
  private let onSavedFTP: (FTPConnectionTarget) -> Void
  private let onConnectNAS: (NASConnectionProfile) -> Void
  private let onConnectSFTP: (SFTPConnectionTarget) -> Void
  private let onConnectFTP: (FTPConnectionTarget) -> Void
  private let onEditNAS: (NASConnectionProfile) -> Void
  private let onEditSFTP: (SFTPConnectionTarget) -> Void
  private let onEditFTP: (FTPConnectionTarget) -> Void

  init(
    entryMode: ConnectPanelEntryMode = .list,
    nasConnections: NASConnectionListModel,
    sftpConnections: SFTPConnectionListModel,
    ftpConnections: FTPConnectionListModel,
    onSavedNAS: @escaping (NASConnectionProfile) -> Void = { _ in },
    onSavedSFTP: @escaping (SFTPConnectionTarget) -> Void = { _ in },
    onSavedFTP: @escaping (FTPConnectionTarget) -> Void = { _ in },
    onConnectNAS: @escaping (NASConnectionProfile) -> Void = { _ in },
    onConnectSFTP: @escaping (SFTPConnectionTarget) -> Void = { _ in },
    onConnectFTP: @escaping (FTPConnectionTarget) -> Void = { _ in },
    onEditNAS: @escaping (NASConnectionProfile) -> Void = { _ in },
    onEditSFTP: @escaping (SFTPConnectionTarget) -> Void = { _ in },
    onEditFTP: @escaping (FTPConnectionTarget) -> Void = { _ in }
  ) {
    _mode = State(initialValue: entryMode)
    if case .form = entryMode {
      _enteredFormDirectly = State(initialValue: true)
    } else {
      _enteredFormDirectly = State(initialValue: false)
    }
    self.nasConnections = nasConnections
    self.sftpConnections = sftpConnections
    self.ftpConnections = ftpConnections
    self.onSavedNAS = onSavedNAS
    self.onSavedSFTP = onSavedSFTP
    self.onSavedFTP = onSavedFTP
    self.onConnectNAS = onConnectNAS
    self.onConnectSFTP = onConnectSFTP
    self.onConnectFTP = onConnectFTP
    self.onEditNAS = onEditNAS
    self.onEditSFTP = onEditSFTP
    self.onEditFTP = onEditFTP
  }

  var body: some View {
    Group {
      switch mode {
      case .list:
        listView
      case .form:
        formView
      }
    }
    .frame(width: 460)
    .modifier(SFTPCredentialPromptPresentation(coordinator: sftpModel.credentialPrompter))
    .background(
      // シート全体を指す識別子。VStackへ直接accessibilityIdentifierを付けると、内側の
      // Picker/Form/Listがそれぞれ持つ個別の識別子を上書きしてしまう(SwiftUIのアクセシビリティ
      // 識別子は祖先の指定が子孫の指定へ伝播して勝つ)ため、兄弟レイヤーとして重ねた透明ビュー
      // 側にのみ識別子を持たせて回避する。
      Color.clear
        .accessibilityElement()
        .accessibilityIdentifier("connect-panel")
    )
  }

  // MARK: - 一覧モード

  private var allRows: [ConnectPanelRow] {
    ConnectPanelRow.rows(
      nasProfiles: nasConnections.profiles,
      sftpTargets: sftpConnections.targets,
      ftpTargets: ftpConnections.targets)
  }

  private var filteredRows: [ConnectPanelRow] {
    ConnectPanelRow.filter(allRows, matching: searchText)
  }

  private var listView: some View {
    listContent
      .frame(minHeight: 320)
      .navigationTitle("サーバへ接続")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("閉じる") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("新規接続…") { presentForm(.nas) }
        }
      }
      .alert(item: $pendingDeletion) { deletion in
        Alert(
          title: Text("\(deletion.title)を削除しますか？"),
          message: Text("この操作は取り消せません。"),
          primaryButton: .destructive(Text("削除")) { performDeletion(deletion.kind) },
          secondaryButton: .cancel(Text("キャンセル")))
      }
  }

  @ViewBuilder
  private var listContent: some View {
    if allRows.isEmpty {
      VStack(spacing: 12) {
        Spacer()
        Text("登録された接続はありません")
          .foregroundStyle(.secondary)
        Button("新規接続…") { presentForm(.nas) }
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 0) {
        TextField("検索", text: $searchText, prompt: Text("名前・ホスト・共有名で検索"))
          .textFieldStyle(.roundedBorder)
          .padding()
          .accessibilityIdentifier("connect-panel-search")
        Divider()
        List(selection: $selectedRowID) {
          ForEach(filteredRows) { row in
            connectPanelRow(row)
          }
        }
        .accessibilityIdentifier("connect-panel-list")
        .background(
          // List(selection:)はReturnキーで選択行を自動アクティブ化しないため、非表示ボタンの
          // defaultActionキーボードショートカットでReturn押下時の接続を実装する。
          Button("") { connectSelectedRow() }
            .keyboardShortcut(.defaultAction)
            .opacity(0)
            .accessibilityHidden(true)
        )
      }
    }
  }

  private func connectPanelRow(_ row: ConnectPanelRow) -> some View {
    HStack(spacing: 8) {
      Text(row.protocolBadge)
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
      VStack(alignment: .leading, spacing: 2) {
        Text(row.title)
        Text(row.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .contentShape(Rectangle())
    .padding(.vertical, 2)
    .tag(row.id)
    .onTapGesture(count: 2) { connect(row) }
    .accessibilityIdentifier("connect-panel-row-\(row.id)")
    .contextMenu {
      Button("接続") { connect(row) }
      Button("編集") { edit(row) }
      Divider()
      Button("削除", role: .destructive) {
        pendingDeletion = ConnectPanelPendingDeletion(title: row.title, kind: row.kind)
      }
    }
  }

  private func connectSelectedRow() {
    guard let selectedRowID, let row = filteredRows.first(where: { $0.id == selectedRowID })
    else { return }
    connect(row)
  }

  private func connect(_ row: ConnectPanelRow) {
    switch row.kind {
    case .nas(let profile):
      onConnectNAS(profile)
    case .sftp(let target):
      onConnectSFTP(target)
    case .ftp(let target):
      onConnectFTP(target)
    }
    dismiss()
  }

  private func edit(_ row: ConnectPanelRow) {
    switch row.kind {
    case .nas(let profile):
      onEditNAS(profile)
    case .sftp(let target):
      onEditSFTP(target)
    case .ftp(let target):
      onEditFTP(target)
    }
    dismiss()
  }

  private func performDeletion(_ kind: ConnectPanelRow.Kind) {
    switch kind {
    case .nas(let profile):
      nasConnections.remove(profile)
    case .sftp(let target):
      sftpConnections.remove(target)
    case .ftp(let target):
      ftpConnections.remove(target)
    }
  }

  private func presentForm(_ initialProtocol: ConnectPanelProtocol) {
    enteredFormDirectly = false
    mode = .form(initialProtocol)
  }

  // MARK: - フォームモード

  private var selectedProtocol: ConnectPanelProtocol {
    if case .form(let protocolValue) = mode { protocolValue } else { .nas }
  }

  private var protocolBinding: Binding<ConnectPanelProtocol> {
    Binding(
      get: { selectedProtocol },
      set: { mode = .form($0) })
  }

  private var formView: some View {
    VStack(spacing: 0) {
      Picker("プロトコル", selection: protocolBinding) {
        ForEach(ConnectPanelProtocol.allCases) { protocolCase in
          Text(protocolCase.displayName).tag(protocolCase)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding([.horizontal, .top])
      .accessibilityIdentifier("connect-panel-protocol")

      Form {
        switch selectedProtocol {
        case .nas:
          NASConnectionFormFields(model: nasModel)
        case .sftp:
          SFTPConnectionFormFields(model: sftpModel)
        case .ftp:
          FTPConnectionFormFields(model: ftpModel)
        }
      }
      .formStyle(.grouped)
    }
    .navigationTitle("サーバへ接続")
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button(enteredFormDirectly ? "キャンセル" : "戻る") {
          if enteredFormDirectly {
            dismiss()
          } else {
            mode = .list
          }
        }
        // ツールバーのナビゲーション「戻る」とタイトルが重複するため、UIテストが
        // 一意に参照できる識別子を付ける。
        .accessibilityIdentifier("connect-panel-back")
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("保存して接続") { saveAndConnect() }
      }
      ToolbarItem {
        switch selectedProtocol {
        case .nas:
          connectionTestButton(isTesting: nasModel.isTestingConnection) {
            nasModel.testConnection()
          }
          .accessibilityIdentifier("nas-connection-test")
        case .sftp:
          connectionTestButton(isTesting: sftpModel.isTestingConnection) {
            sftpModel.testConnection()
          }
          .accessibilityIdentifier("sftp-connection-test")
        case .ftp:
          connectionTestButton(isTesting: ftpModel.isTestingConnection) {
            ftpModel.testConnection()
          }
          .accessibilityIdentifier("ftp-connection-test")
        }
      }
    }
  }

  /// 全プロトコル共通の「接続をテスト」ボタン。実行中はスピナー付きで無効化する。
  @ViewBuilder
  private func connectionTestButton(isTesting: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      if isTesting {
        ProgressView()
          .controlSize(.small)
      } else {
        Text("接続をテスト")
      }
    }
    .disabled(isTesting)
  }

  private func saveAndConnect() {
    switch selectedProtocol {
    case .nas:
      if let profile = nasModel.makeProfile() {
        onSavedNAS(profile)
        dismiss()
      }
    case .sftp:
      if let target = sftpModel.savePassword() {
        onSavedSFTP(target)
        dismiss()
      }
    case .ftp:
      if let target = ftpModel.savePassword() {
        onSavedFTP(target)
        dismiss()
      }
    }
  }
}

private struct ConnectPanelPendingDeletion: Identifiable {
  let id = UUID()
  let title: String
  let kind: ConnectPanelRow.Kind
}
