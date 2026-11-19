import Foundation
import Testing

@testable import PKPane

struct ConnectPanelRowTests {
  @Test("NAS/SFTP/FTPの接続を統合し表示名の昇順で並べる")
  func combinesAndSortsConnections() throws {
    let nasProfile = try NASConnectionProfile(
      displayName: "Zeta NAS", host: "nas.local", shareName: "Docs")
    let sftpTarget = try SFTPConnectionTarget(host: "example.com", port: 22, username: "alice")
    let ftpTarget = try FTPConnectionTarget(
      host: "ftp.example.com", username: "bob", security: .plain)

    let rows = ConnectPanelRow.rows(
      nasProfiles: [nasProfile], sftpTargets: [sftpTarget], ftpTargets: [ftpTarget])

    try #require(rows.count == 3)
    // "alice@example.com" < "Zeta NAS"(ローカライズ標準比較の昇順)
    #expect(rows.map(\.title) == ["alice@example.com", "bob@ftp.example.com", "Zeta NAS"])
    #expect(rows[0].protocolBadge == "SFTP")
    #expect(rows[1].protocolBadge == "FTP")
    #expect(rows[2].protocolBadge == "SMB")
  }

  @Test("検索語が空のときは全件を返す")
  func emptySearchReturnsAllRows() throws {
    let nasProfile = try NASConnectionProfile(
      displayName: "NAS", host: "nas.local", shareName: "Docs")
    let rows = ConnectPanelRow.rows(nasProfiles: [nasProfile], sftpTargets: [])

    #expect(ConnectPanelRow.filter(rows, matching: "").count == 1)
    #expect(ConnectPanelRow.filter(rows, matching: "   ").count == 1)
  }

  @Test("名前・ホスト・共有名/ディレクトリの部分一致(大文字小文字無視)で絞り込む")
  func filtersByNameHostAndShareOrDirectory() throws {
    let nasProfile = try NASConnectionProfile(
      displayName: "開発用NAS", host: "nas.example.local", shareName: "Projects")
    let sftpTarget = try SFTPConnectionTarget(
      host: "sftp.example.com", port: 22, username: "tester", initialDirectory: "/srv/reports")
    let ftpTarget = try FTPConnectionTarget(
      host: "ftp.example.com", username: "ftpuser", initialDirectory: "/releases")
    let rows = ConnectPanelRow.rows(
      nasProfiles: [nasProfile], sftpTargets: [sftpTarget], ftpTargets: [ftpTarget])
    let nasRowID = try #require(rows.first { $0.protocolBadge == "SMB" }).id

    #expect(ConnectPanelRow.filter(rows, matching: "開発用").map(\.id) == [nasRowID])
    #expect(ConnectPanelRow.filter(rows, matching: "PROJECTS").map(\.id) == [nasRowID])
    #expect(ConnectPanelRow.filter(rows, matching: "reports").count == 1)
    #expect(ConnectPanelRow.filter(rows, matching: "sftp.example.com").count == 1)
    #expect(ConnectPanelRow.filter(rows, matching: "releases").count == 1)
    #expect(ConnectPanelRow.filter(rows, matching: "FTPS").count == 1)
    #expect(ConnectPanelRow.filter(rows, matching: "no-match").isEmpty)
  }

  @Test("共有名のないSMB接続先はサーバーURLとして表示する")
  func displaysServerOnlySMBAddress() throws {
    let profile = try NASConnectionProfile(
      displayName: "共有を選ぶ", host: "nas.example.local", shareName: "")

    let row = try #require(
      ConnectPanelRow.rows(nasProfiles: [profile], sftpTargets: []).first)

    #expect(row.subtitle == "smb://nas.example.local")
    #expect(ConnectPanelRow.filter([row], matching: "nas.example.local") == [row])
  }

  @Test("SFTP接続のサブタイトルに踏み台の段数を表示する")
  func sftpRowSubtitleShowsJumpHopCount() throws {
    let jumpHost = try SFTPJumpHost(
      host: "gateway", port: 2222, username: "ops", label: "踏み台")
    let target = try SFTPConnectionTarget(
      host: "files.example",
      port: 22,
      username: "tester",
      jumpHosts: [jumpHost])

    let row = try #require(
      ConnectPanelRow.rows(nasProfiles: [], sftpTargets: [target]).first)

    #expect(row.subtitle == "ポート22・.・経由1段")
  }
}
