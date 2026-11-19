import Foundation

/// Connect Panel一覧モードの1行分(NAS/SFTP/FTP統合)。各接続の写像・並び順・検索フィルタは
/// ここへ集約し、View本体を介さず単体テストで検証できるようにする。
struct ConnectPanelRow: Identifiable, Equatable {
  enum Kind: Equatable {
    case nas(NASConnectionProfile)
    case sftp(SFTPConnectionTarget)
    case ftp(FTPConnectionTarget)
  }

  let id: String
  let kind: Kind
  let protocolBadge: String
  let title: String
  let subtitle: String
  let searchableText: String

  /// NAS/SFTP/FTPの接続一覧を統合し、表示名の昇順で並べた行の配列を返す。
  static func rows(
    nasProfiles: [NASConnectionProfile],
    sftpTargets: [SFTPConnectionTarget],
    ftpTargets: [FTPConnectionTarget] = []
  ) -> [ConnectPanelRow] {
    let nasRows = nasProfiles.map { profile in
      ConnectPanelRow(
        id: SidebarConnectionVisibilityStore.identifier(for: profile),
        kind: .nas(profile),
        protocolBadge: "SMB",
        title: profile.displayName,
        subtitle: profile.shareName.isEmpty
          ? "smb://\(profile.host)" : "smb://\(profile.host)/\(profile.shareName)",
        searchableText: "\(profile.displayName) \(profile.host) \(profile.shareName)")
    }
    let sftpRows = sftpTargets.map { target in
      let hopSuffix =
        target.jumpHosts.isEmpty
        ? ""
        : String(
          format: String(localized: "・経由%ld段"), target.jumpHosts.count)
      let jumpHostNames = target.jumpHosts.map(\.host).joined(separator: " ")
      return ConnectPanelRow(
        id: SidebarConnectionVisibilityStore.identifier(for: target),
        kind: .sftp(target),
        protocolBadge: "SFTP",
        title: "\(target.username)@\(target.host)",
        subtitle: "ポート\(target.port)・\(target.initialDirectory)\(hopSuffix)",
        searchableText:
          "\(target.username) \(target.host) \(target.initialDirectory) \(jumpHostNames)")
    }
    let ftpRows = ftpTargets.map { target in
      ConnectPanelRow(
        id: SidebarConnectionVisibilityStore.identifier(for: target),
        kind: .ftp(target),
        protocolBadge: target.security == .plain ? "FTP" : "FTPS",
        title: "\(target.username)@\(target.host)",
        subtitle: "\(target.security.displayName)・ポート\(target.port)・\(target.initialDirectory)",
        searchableText:
          "\(target.username) \(target.host) \(target.initialDirectory) \(target.security.displayName)"
      )
    }
    return (nasRows + sftpRows + ftpRows).sorted {
      $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
  }

  /// 名前・ホスト・共有名/ディレクトリの部分一致(大文字小文字無視)で行を絞り込む。
  /// 検索語が空文字(前後空白を除く)のときは全件を返す。
  static func filter(_ rows: [ConnectPanelRow], matching searchText: String) -> [ConnectPanelRow] {
    let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return rows }
    return rows.filter { $0.searchableText.localizedCaseInsensitiveContains(trimmed) }
  }
}
