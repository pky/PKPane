import Foundation
import Observation

@MainActor
@Observable
final class SSHConfigAccessSettingsModel {
  private let reader: SSHConfigReader
  private let repository: SSHDirectoryAccessRepository

  private(set) var state: SSHConfigAccessState
  private(set) var errorMessage: String?

  init(reader: SSHConfigReader, repository: SSHDirectoryAccessRepository) {
    self.reader = reader
    self.repository = repository
    state = reader.accessState()
  }

  func chooseFolder(_ url: URL) {
    do {
      try repository.save(url)
      errorMessage = nil
    } catch {
      errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
    }
    refresh()
  }

  func revoke() {
    guard state != .direct else { return }
    repository.remove()
    errorMessage = nil
    refresh()
  }

  func refresh() {
    state = reader.accessState()
  }
}

extension SSHConfigAccessSettingsModel {
  static func live() -> SSHConfigAccessSettingsModel {
    let repository = SSHDirectoryAccessRepository()
    return SSHConfigAccessSettingsModel(
      reader: SSHConfigReader(accessRepository: repository),
      repository: repository)
  }
}
