enum SFTPCredentialKind: Hashable, Sendable {
  case password
  case passphrase(keyPath: String)
}
