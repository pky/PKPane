enum SFTPConnectionIntent: Sendable {
  case userInitiated
  case background
}

struct SFTPCredentialRequest: Sendable, Equatable {
  let hop: SFTPHopIdentity
  let kind: SFTPCredentialKind
  let attempt: Int
  let label: String?
}

struct SFTPCredentialAnswer: Sendable, Equatable {
  let secret: String
  let saveToKeychain: Bool
}

protocol SFTPCredentialPrompting: Sendable {
  func requestCredential(_ request: SFTPCredentialRequest) async -> SFTPCredentialAnswer?
}

struct SFTPNoPromptCredentialPrompter: SFTPCredentialPrompting {
  func requestCredential(_: SFTPCredentialRequest) async -> SFTPCredentialAnswer? {
    nil
  }
}
