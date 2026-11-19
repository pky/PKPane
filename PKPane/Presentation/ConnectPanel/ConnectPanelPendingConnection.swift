/// 接続パネルで選ばれた(または保存された)接続先を、シートが閉じきるまで保留するための値。
/// 接続開始は `.sheet(onDismiss:)` で行い、資格情報ダイアログや共有選択などの後続UIが
/// 閉じかけのシートと重ならないようにする。
enum ConnectPanelPendingConnection {
  case nas(NASConnectionProfile, savesProfile: Bool)
  case sftp(SFTPConnectionTarget)
  case ftp(FTPConnectionTarget)
}
