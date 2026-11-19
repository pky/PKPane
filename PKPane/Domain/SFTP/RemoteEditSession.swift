import Foundation

enum RemoteEditState: String, Codable, Equatable, Sendable {
  case synced
  case unsynced
  case syncing
  case conflict
  case failed
}

struct RemoteEditBaseline: Codable, Equatable, Sendable {
  let size: Int64?
  let modifiedAt: Date?

  init(item: FileItem) {
    size = item.size
    modifiedAt = item.modifiedAt
  }

  func matches(_ item: FileItem?) -> Bool {
    guard let item else { return false }
    return size == item.size && modifiedAt == item.modifiedAt
  }
}

struct RemoteEditSession: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  var providerID: FileProviderID
  var remoteLocation: FileLocation
  var workingCopyPath: String
  var originalName: String
  var baseline: RemoteEditBaseline
  var lastSyncedRevision: String
  var state: RemoteEditState
  var updatedAt: Date

  var workingCopyURL: URL { URL(fileURLWithPath: workingCopyPath) }

  init(
    id: UUID = UUID(),
    providerID: FileProviderID,
    remoteLocation: FileLocation,
    workingCopyURL: URL,
    originalName: String,
    baseline: RemoteEditBaseline,
    lastSyncedRevision: String,
    state: RemoteEditState = .synced,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.providerID = providerID
    self.remoteLocation = remoteLocation
    workingCopyPath = workingCopyURL.path
    self.originalName = originalName
    self.baseline = baseline
    self.lastSyncedRevision = lastSyncedRevision
    self.state = state
    self.updatedAt = updatedAt
  }
}

enum RemoteEditConflictResolution: Equatable, Sendable {
  case overwrite
  case saveAs(String)
  case downloadLatest
  case keepLocal
}

protocol RemoteEditSessionStoring: Sendable {
  func load() throws -> [RemoteEditSession]
  func save(_ sessions: [RemoteEditSession]) throws
}

struct RemoteEditSessionStore: RemoteEditSessionStoring {
  let url: URL

  func load() throws -> [RemoteEditSession] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try JSONDecoder().decode([RemoteEditSession].self, from: Data(contentsOf: url))
  }

  func save(_ sessions: [RemoteEditSession]) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(sessions)
    try data.write(to: url, options: .atomic)
  }
}
