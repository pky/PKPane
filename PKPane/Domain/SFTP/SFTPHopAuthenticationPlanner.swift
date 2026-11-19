import Foundation

enum SFTPAuthenticationCandidate: Equatable, Sendable {
  case privateKey(URL)
  case storedPassword(String)
  case promptPassword
}

enum SFTPHopAuthenticationPlanner {
  static func plan(
    privateKeyURL: URL?,
    storedPassword: String?,
    intent: SFTPConnectionIntent
  ) -> [SFTPAuthenticationCandidate] {
    var candidates: [SFTPAuthenticationCandidate] = []

    if let privateKeyURL {
      candidates.append(.privateKey(privateKeyURL))
    }
    if let storedPassword {
      candidates.append(.storedPassword(storedPassword))
    }
    if case .userInitiated = intent {
      candidates.append(.promptPassword)
    }

    return candidates
  }
}
