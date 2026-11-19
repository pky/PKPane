import Foundation

struct RecentSMBConnection: Codable, Identifiable, Equatable {
  let host: String
  let shareName: String

  var id: String { "\(host.lowercased())/\(shareName.lowercased())" }
  var displayName: String { "\(host)/\(shareName)" }

  init(host: String, shareName: String) throws {
    let share = try SMBShare(host: host, shareName: shareName)
    self.host = share.host
    self.shareName = share.shareName
  }

  init?(volume: SMBMountedVolume) {
    guard let host = volume.remountingURL.host else { return nil }
    let shareName = volume.remountingURL.lastPathComponent
    guard let connection = try? Self(host: host, shareName: shareName) else { return nil }
    self = connection
  }

  func smbShare() throws -> SMBShare {
    try SMBShare(host: host, shareName: shareName)
  }
}
