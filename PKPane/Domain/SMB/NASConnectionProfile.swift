import Foundation

enum NASConnectionProfileError: LocalizedError, Equatable {
  case invalidDisplayName

  var errorDescription: String? {
    switch self {
    case .invalidDisplayName:
      "NAS接続名が正しくありません。"
    }
  }
}

struct NASConnectionProfile: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let displayName: String
  let host: String
  let shareName: String

  init(
    id: UUID = UUID(),
    displayName: String,
    host: String,
    shareName: String
  ) throws {
    let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedDisplayName.isEmpty else {
      throw NASConnectionProfileError.invalidDisplayName
    }

    let share = try SMBShare(host: host, shareName: shareName, allowsServerOnly: true)
    self.id = id
    self.displayName = normalizedDisplayName
    self.host = share.host
    self.shareName = share.shareName
  }

  func smbShare() throws -> SMBShare {
    try SMBShare(host: host, shareName: shareName, allowsServerOnly: true)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case displayName
    case host
    case shareName
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(UUID.self, forKey: .id),
      displayName: container.decode(String.self, forKey: .displayName),
      host: container.decode(String.self, forKey: .host),
      shareName: container.decode(String.self, forKey: .shareName))
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(displayName, forKey: .displayName)
    try container.encode(host, forKey: .host)
    try container.encode(shareName, forKey: .shareName)
  }
}
