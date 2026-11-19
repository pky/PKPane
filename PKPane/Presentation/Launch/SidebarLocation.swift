import Foundation

enum SidebarLocationSource: String, Equatable {
  case local
  case nas
  case sftp
  case ftp
  case volume
  case cloud

  var displayName: String {
    switch self {
    case .local: "ローカル"
    case .nas: "NAS"
    case .sftp: "SFTP"
    case .ftp: "FTP/FTPS"
    case .volume: "ボリューム"
    case .cloud: "クラウド"
    }
  }

  var systemImage: String {
    switch self {
    case .local: "folder"
    case .nas: "externaldrive"
    case .sftp: "server.rack"
    case .ftp: "network"
    case .volume: "externaldrive"
    case .cloud: "cloud"
    }
  }
}

struct SidebarLocation: Identifiable, Equatable {
  enum Availability: Equatable {
    case available
    case reconnectable
    case unavailable
  }

  let id: String
  let title: String
  let source: SidebarLocationSource
  let availability: Availability
  let detail: String?
  /// 場所別アイコン(Finder風)。nilの場合は source.systemImage にフォールバックする。
  let systemImageOverride: String?

  init(
    id: String,
    title: String,
    source: SidebarLocationSource,
    availability: Availability = .available,
    detail: String? = nil,
    systemImageOverride: String? = nil
  ) {
    self.id = id
    self.title = title
    self.source = source
    self.availability = availability
    self.detail = detail
    self.systemImageOverride = systemImageOverride
  }

  var systemImage: String {
    systemImageOverride ?? source.systemImage
  }

  var isAvailable: Bool {
    availability != .unavailable
  }

  var isReconnectable: Bool {
    availability == .reconnectable
  }
}
