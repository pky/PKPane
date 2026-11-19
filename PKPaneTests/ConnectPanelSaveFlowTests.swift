import Testing

@testable import PKPane

struct ConnectPanelSaveFlowTests {
  @Test("SFTPの保存後は一覧を再読込し、シートが閉じてから接続する")
  func savingSFTPConnectsAfterReloadAndDismiss() {
    #expect(ConnectPanelSaveAction.actions(for: .sftp) == [.reloadList, .connectAfterDismiss])
  }

  @Test("FTPの保存後は一覧を再読込し、シートが閉じてから接続する")
  func savingFTPConnectsAfterReloadAndDismiss() {
    #expect(ConnectPanelSaveAction.actions(for: .ftp) == [.reloadList, .connectAfterDismiss])
  }

  @Test("NASの保存後はシートが閉じてから接続する")
  func savingNASConnectsAfterDismiss() {
    #expect(ConnectPanelSaveAction.actions(for: .nas) == [.connectAfterDismiss])
  }
}
