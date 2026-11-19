actor SFTPSessionCredentialCache {
  private struct Key: Hashable {
    let hop: SFTPHopIdentity
    let kind: SFTPCredentialKind
  }

  private var secrets: [Key: String] = [:]

  func secret(for hop: SFTPHopIdentity, kind: SFTPCredentialKind) -> String? {
    secrets[Key(hop: hop, kind: kind)]
  }

  func store(_ secret: String, for hop: SFTPHopIdentity, kind: SFTPCredentialKind) {
    secrets[Key(hop: hop, kind: kind)] = secret
  }

  func remove(for hop: SFTPHopIdentity, kind: SFTPCredentialKind) {
    secrets[Key(hop: hop, kind: kind)] = nil
  }
}
