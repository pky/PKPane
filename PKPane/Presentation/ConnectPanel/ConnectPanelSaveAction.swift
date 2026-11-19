enum ConnectPanelSaveStep: Equatable {
  case reloadList
  /// 接続パネルのシートが閉じきってから接続を始める。閉じるアニメーション中に接続を
  /// 始めると、初回接続で必要になる資格情報ダイアログやホスト鍵承認が閉じかけのシートと
  /// 重なって潰れ、キャンセル扱い(認証失敗)になるため。
  case connectAfterDismiss
}

enum ConnectPanelSaveAction {
  static func actions(for connectionProtocol: ConnectPanelProtocol) -> [ConnectPanelSaveStep] {
    switch connectionProtocol {
    case .nas:
      [.connectAfterDismiss]
    case .sftp, .ftp:
      [.reloadList, .connectAfterDismiss]
    }
  }
}
