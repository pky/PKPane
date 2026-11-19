/// 拒否された保存値を再送しないための、メモリだけの印。
/// 保存値は誤りと断定できず消せないので、バックグラウンド再接続が同じ値を
/// サーバーへ送り続けて締め出されるのを、削除ではなく印で防ぐ。
actor SFTPRejectionLedger {
  private struct Entry: Hashable {
    let hop: SFTPHopIdentity
    let kind: SFTPCredentialKind
  }

  private var rejected: [Entry: Set<String>] = [:]

  func markRejected(_ value: String, for hop: SFTPHopIdentity, kind: SFTPCredentialKind) {
    rejected[Entry(hop: hop, kind: kind), default: []].insert(value)
  }

  func isRejected(_ value: String, for hop: SFTPHopIdentity, kind: SFTPCredentialKind) -> Bool {
    rejected[Entry(hop: hop, kind: kind)]?.contains(value) == true
  }

  func clearRejections(for hop: SFTPHopIdentity, kind: SFTPCredentialKind) {
    rejected[Entry(hop: hop, kind: kind)] = nil
  }
}
