import Foundation

/// 共有ごとに直接SMB転送エンジンを再利用し、Keychain照会と再認証を抑えます。
actor SMBDirectEngineCache: Sendable {
  static let shared = SMBDirectEngineCache()

  private struct Key: Hashable, Sendable {
    let host: String
    let shareName: String

    init(sharePath: SMBSharePath) {
      host = sharePath.host.lowercased()
      shareName = sharePath.shareName.lowercased()
    }
  }

  private struct StagedFileKey: Hashable, Sendable {
    let share: Key
    let path: String

    init(sharePath: SMBSharePath) {
      share = Key(sharePath: sharePath)
      path = sharePath.createPath
    }
  }

  private var engines: [Key: SMBDirectTransferEngine] = [:]
  private var unavailableKeys: Set<Key> = []
  private var stagedFileEngines: [StagedFileKey: SMBDirectTransferEngine] = [:]

  func transfer(
    for sharePath: SMBSharePath,
    preferredAccount: String?,
    credentialResolver: any SMBDirectCredentialResolving,
    engineMaking: SMBDirectTransferEngineMaking
  ) -> (engine: SMBDirectTransferEngine, path: String)? {
    let key = Key(sharePath: sharePath)
    guard !unavailableKeys.contains(key) else { return nil }
    if let engine = engines[key] {
      return (engine, sharePath.createPath)
    }
    guard
      let credentials =
        credentialResolver.credentials(
          forServer: sharePath.host,
          preferredAccount: preferredAccount)
    else {
      return nil
    }
    let target = SMBDirectTransferTarget(
      host: sharePath.host,
      shareName: sharePath.shareName,
      credentials: credentials)
    let engine = engineMaking(target)
    engines[key] = engine
    return (engine, sharePath.createPath)
  }

  func markUnavailable(for sharePath: SMBSharePath) {
    let key = Key(sharePath: sharePath)
    engines[key] = nil
    unavailableKeys.insert(key)
  }

  func registerDirectWrite(
    for sharePath: SMBSharePath,
    engine: SMBDirectTransferEngine
  ) {
    stagedFileEngines[StagedFileKey(sharePath: sharePath)] = engine
  }

  func registeredDirectWrite(
    for sharePath: SMBSharePath
  ) -> (engine: SMBDirectTransferEngine, path: String)? {
    guard let engine = stagedFileEngines[StagedFileKey(sharePath: sharePath)] else {
      return nil
    }
    return (engine, sharePath.createPath)
  }

  func withRegisteredDirectWrite(
    for sharePath: SMBSharePath,
    operation: @Sendable (SMBDirectTransferEngine, String) async throws -> Void
  ) async rethrows -> Bool {
    let key = StagedFileKey(sharePath: sharePath)
    guard let engine = stagedFileEngines[key] else { return false }
    defer { stagedFileEngines[key] = nil }
    try await operation(engine, sharePath.createPath)
    return true
  }

  func withRegisteredDirectWrite(
    from temporarySharePath: SMBSharePath,
    to destinationSharePath: SMBSharePath?,
    operation:
      @Sendable (
        SMBDirectTransferEngine,
        String,
        String
      ) async throws -> Void
  ) async rethrows -> Bool {
    let temporaryKey = StagedFileKey(sharePath: temporarySharePath)
    guard let engine = stagedFileEngines[temporaryKey] else { return false }
    defer { stagedFileEngines[temporaryKey] = nil }
    guard let destinationSharePath,
      temporaryKey.share == Key(sharePath: destinationSharePath)
    else { return false }
    try await operation(
      engine,
      temporarySharePath.createPath,
      destinationSharePath.createPath)
    return true
  }
}
