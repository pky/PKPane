import Foundation
import Observation

struct FileProviderConnectionID: Hashable, Sendable, RawRepresentable {
  let rawValue: String

  static func smb(volumeURL: URL) -> Self {
    Self(rawValue: "smb-\(volumeURL.standardizedFileURL.path)")
  }
}

struct FileProviderDisconnection: Identifiable, Equatable {
  let id = UUID()
  let connectionID: FileProviderConnectionID
}

@Observable
@MainActor
final class FileProviderConnectionLifecycle {
  private(set) var latestDisconnection: FileProviderDisconnection?

  func didDisconnect(_ connectionID: FileProviderConnectionID) {
    latestDisconnection = FileProviderDisconnection(connectionID: connectionID)
  }
}
