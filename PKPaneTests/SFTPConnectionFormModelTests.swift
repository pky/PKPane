import Citadel
import Foundation
import Testing

@testable import PKPane

@MainActor
struct SFTPConnectionFormModelTests {
  @Test("登録済みの踏み台候補から編集中の接続と他の行を除外する")
  func registeredCandidatesExcludeSelfAndExistingRows() throws {
    let relay = try SFTPConnectionTarget(host: "gateway", port: 22, username: "ops")
    let destination = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")
    let gateway = try SFTPConnectionTarget(host: "gw", port: 2222, username: "admin")
    let store = SFTPConnectionProfileStore(defaults: isolatedDefaults())
    store.save(relay)
    store.save(destination)
    store.save(gateway)
    let model = SFTPConnectionFormModel(
      target: destination,
      passwordStore: SFTPPasswordStore(keychain: InMemoryKeychainPasswordDataStore()),
      profileStore: store,
      privateKeyRepository: RecordingPrivateKeyRepository())
    model.addJumpHost()
    model.jumpHosts[0].host = relay.host
    model.jumpHosts[0].port = String(relay.port)
    model.jumpHosts[0].username = relay.username
    model.addJumpHost()
    let emptyDraftID = try #require(model.jumpHosts.last?.id)

    let candidates = model.registeredJumpHostCandidates(excluding: emptyDraftID)

    #expect(candidates.map(\.identity) == [gateway.finalHop])

    // 編集前の接続に加え、現在入力中の接続も自身として除外する。
    model.host = gateway.host
    model.port = String(gateway.port)
    model.username = gateway.username
    #expect(model.registeredJumpHostCandidates(excluding: emptyDraftID).isEmpty)
  }

  @Test("登録済みの踏み台を適用すると入力欄と保存済みの鍵を復元する")
  func applyingCandidateFillsRowAndRestoresKey() throws {
    let gateway = try SFTPConnectionTarget(host: "gw", port: 2222, username: "admin")
    let keyURL = URL(filePath: "/fixture/gateway-key")
    let repository = RecordingPrivateKeyRepository(restoredURLsByHop: [gateway.finalHop: keyURL])
    let store = SFTPConnectionProfileStore(defaults: isolatedDefaults())
    store.save(gateway)
    let model = SFTPConnectionFormModel(
      passwordStore: SFTPPasswordStore(keychain: InMemoryKeychainPasswordDataStore()),
      profileStore: store,
      privateKeyRepository: repository)
    model.addJumpHost()
    let draftID = try #require(model.jumpHosts.first?.id)
    model.jumpHosts[0].host = "previous-gateway"
    model.jumpHosts[0].username = "previous-user"
    model.jumpHosts[0].password = "previous-fixture-password"
    model.jumpHosts[0].privateKeyURL = URL(filePath: "/fixture/previous-key")
    let candidate = try #require(model.registeredJumpHostCandidates(excluding: draftID).first)

    model.applyRegisteredJumpHost(candidate, to: draftID)

    let draft = try #require(model.jumpHosts.first)
    #expect(draft.id == draftID)
    #expect(draft.host == "gw")
    #expect(draft.port == "2222")
    #expect(draft.username == "admin")
    #expect(draft.password.isEmpty)
    #expect(draft.privateKeyURL == keyURL)
    #expect(repository.savedURLsByHop.isEmpty)
    #expect(repository.removedHops.isEmpty)
    #expect(store.loadAll() == [gateway])
  }

  @Test("登録済みの踏み台への差し替えでは旧資格情報を変更しない")
  func applyingRegisteredJumpHostResetsOriginalIdentityAndRestoredKey() throws {
    let originalHop = try SFTPJumpHost(
      host: "gateway", port: 22, username: "old-user", label: "旧踏み台")
    let target = try SFTPConnectionTarget(
      host: "destination", port: 22, username: "tester", jumpHosts: [originalHop])
    let candidateTarget = try SFTPConnectionTarget(
      host: "gateway", port: 22, username: "new-user")
    let passwordStore = SFTPPasswordStore(keychain: InMemoryKeychainPasswordDataStore())
    try passwordStore.save("old-password", for: originalHop.identity, kind: .password)
    let repository = RecordingPrivateKeyRepository(restoredURLsByHop: [
      originalHop.identity: URL(filePath: "/fixture/original-key")
    ])
    let store = SFTPConnectionProfileStore(defaults: isolatedDefaults())
    store.save(candidateTarget)
    let model = SFTPConnectionFormModel(
      target: target,
      passwordStore: passwordStore,
      profileStore: store,
      privateKeyRepository: repository)
    let draftID = try #require(model.jumpHosts.first?.id)
    let candidate = try #require(
      model.registeredJumpHostCandidates(excluding: draftID).first)

    model.applyRegisteredJumpHost(candidate, to: draftID)
    let updated = try #require(model.savePassword())

    #expect(!repository.removedHops.contains(originalHop.identity))
    #expect(
      try passwordStore.secret(for: candidateTarget.finalHop, kind: .password) == nil)
    #expect(updated.jumpHosts.first?.label == nil)
  }

  @Test("登録済みの踏み台を選んでもその接続の踏み台は引き継がない")
  func candidateDoesNotInheritItsOwnJumpHosts() throws {
    let innerHop = try SFTPJumpHost(host: "gateway", port: 22, username: "ops", label: nil)
    let gateway = try SFTPConnectionTarget(
      host: "gw", port: 2222, username: "admin", jumpHosts: [innerHop])
    let store = SFTPConnectionProfileStore(defaults: isolatedDefaults())
    store.save(gateway)
    let model = SFTPConnectionFormModel(
      passwordStore: SFTPPasswordStore(keychain: InMemoryKeychainPasswordDataStore()),
      profileStore: store,
      privateKeyRepository: RecordingPrivateKeyRepository())
    model.addJumpHost()
    let draftID = try #require(model.jumpHosts.first?.id)
    let candidate = try #require(model.registeredJumpHostCandidates(excluding: draftID).first)

    model.applyRegisteredJumpHost(candidate, to: draftID)

    #expect(candidate.identity == gateway.finalHop)
    #expect(model.jumpHosts.count == 1)
    #expect(model.jumpHosts.first?.id == draftID)
    #expect(model.jumpHosts.first?.host == "gw")
    #expect(model.jumpHosts.first?.port == "2222")
    #expect(model.jumpHosts.first?.username == "admin")
  }

  @Test("登録済みの踏み台候補は標準ポートだけ表示を省略する")
  func candidateTitleOmitsDefaultPort() throws {
    let relay = try SFTPConnectionTarget(host: "gateway", port: 22, username: "ops")
    let gateway = try SFTPConnectionTarget(host: "gw", port: 2222, username: "admin")
    let store = SFTPConnectionProfileStore(defaults: isolatedDefaults())
    store.save(relay)
    store.save(gateway)
    let model = SFTPConnectionFormModel(
      passwordStore: SFTPPasswordStore(keychain: InMemoryKeychainPasswordDataStore()),
      profileStore: store,
      privateKeyRepository: RecordingPrivateKeyRepository())
    model.addJumpHost()
    let draftID = try #require(model.jumpHosts.first?.id)

    let candidates = model.registeredJumpHostCandidates(excluding: draftID)
    let titlesByIdentity = Dictionary(
      uniqueKeysWithValues: candidates.map { ($0.identity, $0.title) })

    #expect(candidates.count == 2)
    #expect(titlesByIdentity[relay.finalHop] == "ops@gateway")
    #expect(titlesByIdentity[gateway.finalHop] == "admin@gw:2222")
  }

  @Test("取り込んだ最終ホストと踏み台の鍵はフォルダスコープ内で保存する")
  func savingImportedKeyOpensDirectoryScope() async throws {
    let folder = URL(filePath: "/Selected/.ssh")
    let recorder = SSHConfigScopeRecorder()
    let repository = RecordingPrivateKeyRepository(onSave: { url in
      recorder.record("save:\(url.lastPathComponent)")
      guard recorder.isActive else { throw CocoaError(.fileWriteNoPermission) }
    })
    let model = SFTPConnectionFormModel(
      passwordStore: SFTPPasswordStore(keychain: InMemoryKeychainPasswordDataStore()),
      profileStore: SFTPConnectionProfileStore(defaults: isolatedDefaults()),
      privateKeyRepository: repository, connectionService: SuccessfulSFTPConnector(),
      sshConfigReader: makeScopedSSHConfigReader(folderURL: folder, recorder: recorder))
    model.applyImport(sshConfigImportResult(folderURL: folder), folderURL: folder)
    #expect(recorder.events.isEmpty)

    _ = try #require(model.savePassword())

    #expect(model.errorMessage == nil)
    #expect(recorder.events.first == "start")
    #expect(recorder.events.last == "stop")
    #expect(
      recorder.events.filter { $0.hasPrefix("save:") } == ["save:id_relay", "save:id_files"])
    #expect(
      recorder.events.filter { $0 == "start" }.count
        == recorder.events.filter { $0 == "stop" }.count)
    #expect(recorder.accessedURLs.allSatisfy { $0 == folder })
    #expect(!recorder.isActive)

    recorder.reset()
    model.testConnection()
    await waitForConnectionTest(model)
    #expect(model.errorMessage == nil)
    #expect(model.testResultMessage != nil)
    #expect(recorder.events.first == "start")
    #expect(recorder.events.last == "stop")
    #expect(recorder.events.filter { $0.hasPrefix("save:") }.count == 2)
    #expect(!recorder.isActive)
  }

  @Test("許可フォルダ外のIdentityFileは既存鍵を保持して警告する")
  func importKeepsExistingKeyWhenIdentityFileOutsideFolderAndWarns() throws {
    let folder = URL(filePath: "/Users/test/.ssh")
    let jump = try SFTPJumpHost(host: "gateway.example", port: 2222, username: "ops", label: nil)
    let target = try SFTPConnectionTarget(
      host: "files.example", port: 2200, username: "tester", jumpHosts: [jump])
    let finalKey = folder.appending(path: "existing-final")
    let jumpKey = folder.appending(path: "existing-jump")
    let repository = RecordingPrivateKeyRepository(restoredURLsByHop: [
      target.finalHop: finalKey, jump.identity: jumpKey,
    ])
    let reader = SSHConfigReader(
      homeDirectory: folder.deletingLastPathComponent(),
      accessRepository: FormSSHDirectoryAccessFixture.makeRepository(), fileReader: { _ in "" })
    let model = SFTPConnectionFormModel(
      target: target,
      passwordStore: SFTPPasswordStore(keychain: InMemoryKeychainPasswordDataStore()),
      profileStore: SFTPConnectionProfileStore(defaults: isolatedDefaults()),
      privateKeyRepository: repository, sshConfigReader: reader)
    let result = SSHConfigImportResult(
      final: SSHConfigResolvedHop(
        alias: "target", hostName: target.host, port: target.port,
        username: target.username, identityFiles: ["/outside/final-key"]),
      jumpHops: [
        SSHConfigResolvedHop(
          alias: "gateway", hostName: jump.host, port: jump.port,
          username: jump.username, identityFiles: ["/outside/jump-key"])
      ], warnings: [])

    model.applyImport(result, folderURL: folder)

    #expect(model.privateKeyURL == finalKey)
    #expect(model.jumpHosts.first?.privateKeyURL == jumpKey)
    #expect(model.importWarnings.count == 2)
    #expect(
      model.importWarnings.contains(
        .identityFileOutsideAccessibleFolder(path: "/outside/final-key")))
    #expect(
      model.importWarnings.contains(.identityFileOutsideAccessibleFolder(path: "/outside/jump-key"))
    )
    _ = try #require(model.savePassword())
    #expect(repository.removedHops.isEmpty)
    #expect(try repository.restore(for: target) == finalKey)
    #expect(try repository.restore(for: jump.identity) == jumpKey)
  }

  @Test("IdentityFileがない取り込みでは既存鍵を維持する")
  func importWithoutIdentityFileKeepsExistingKey() throws {
    let folder = URL(filePath: "/Users/test/.ssh")
    let target = try SFTPConnectionTarget(
      host: "files.example", port: 2200, username: "tester")
    let existingKey = folder.appending(path: "existing-final")
    let repository = RecordingPrivateKeyRepository(restoredURLsByHop: [
      target.finalHop: existingKey
    ])
    let model = SFTPConnectionFormModel(
      target: target,
      passwordStore: SFTPPasswordStore(keychain: InMemoryKeychainPasswordDataStore()),
      profileStore: SFTPConnectionProfileStore(defaults: isolatedDefaults()),
      privateKeyRepository: repository)
    let result = SSHConfigImportResult(
      final: SSHConfigResolvedHop(
        alias: "files", hostName: target.host, port: target.port,
        username: target.username, identityFiles: []),
      jumpHops: [], warnings: [])

    model.applyImport(result, folderURL: folder)

    #expect(model.privateKeyURL == existingKey)
    #expect(model.importWarnings.isEmpty)
    _ = try #require(model.savePassword())
    #expect(repository.removedHops.isEmpty)
    #expect(try repository.restore(for: target) == existingKey)
  }

  @Test("読み込みとフォルダ保存のエラーは分類済み文言を表示する")
  func importErrorsAreClassifiedMessages() throws {
    let fixturePath = "/Users/someone/.ssh/config"
    let failure = NSError(
      domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
      userInfo: [
        NSLocalizedDescriptionKey: "読取失敗: \(fixturePath)", NSFilePathErrorKey: fixturePath,
      ])
    for failingBookmarkSave in [false, true] {
      let reader = SSHConfigReader(
        homeDirectory: URL(filePath: "/Users/test"),
        accessRepository: FormSSHDirectoryAccessFixture.makeRepository(
          createError: failingBookmarkSave ? failure : nil),
        fileReader: { _ in
          if failingBookmarkSave { throw CocoaError(.fileReadNoPermission) }
          throw failure
        })
      let model = SFTPConnectionFormModel(
        passwordStore: SFTPPasswordStore(keychain: InMemoryKeychainPasswordDataStore()),
        profileStore: SFTPConnectionProfileStore(defaults: isolatedDefaults()),
        privateKeyRepository: RecordingPrivateKeyRepository(), sshConfigReader: reader,
        presentFolderPicker: { URL(filePath: "/Selected/.ssh") })

      model.beginSSHConfigImport()

      let message = try #require(model.errorMessage)
      #expect(message == PKPaneErrorClassifier.classify(failure).displayMessage)
      #expect(!message.contains(fixturePath))
      #expect(!message.contains("/Users/"))
      #expect(model.sshConfigPicker == nil)
    }
  }

  @Test("接続フォームのパスワードをKeychainへ保存する")
  func savesPassword() {
    let keychain = RecordingKeychainPasswordDataStore()
    let model = SFTPConnectionFormModel(passwordStore: SFTPPasswordStore(keychain: keychain))
    model.host = "example.com"
    model.username = "tester"
    model.password = "password"

    model.savePassword()

    #expect(keychain.savedPassword == "password")
    #expect(model.errorMessage == nil)
  }

  @Test("秘密鍵を指定した接続を保存する")
  func savesPrivateKeyBookmark() throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let privateKeyURL = URL(filePath: "/private/keys/id_ed25519")
    let repository = RecordingPrivateKeyRepository()
    let suiteName = "SFTPConnectionFormModelPrivateKeyTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = SFTPConnectionFormModel(
      profileStore: SFTPConnectionProfileStore(defaults: defaults),
      privateKeyRepository: repository)
    model.host = target.host
    model.username = target.username
    model.privateKeyURL = privateKeyURL

    #expect(model.savePassword() == target)
    #expect(repository.savedURL == privateKeyURL)
    #expect(repository.savedTarget == target)
  }

  @Test("接続フォームは開始ディレクトリをプロファイルへ保存する")
  func savesStartDirectory() throws {
    let defaults = isolatedDefaults()
    let profileStore = SFTPConnectionProfileStore(defaults: defaults)
    let model = SFTPConnectionFormModel(
      passwordStore: SFTPPasswordStore(keychain: RecordingKeychainPasswordDataStore()),
      profileStore: profileStore)
    model.host = "example.com"
    model.username = "tester"
    model.password = "password"
    model.startDirectory = "/srv/projects"

    let target = try #require(model.savePassword())

    #expect(target.initialDirectory == "/srv/projects")
    #expect(profileStore.loadAll().first?.initialDirectory == "/srv/projects")
  }

  @Test("踏み台の資格情報を踏み台のKeychain項目へ保存する")
  func savesJumpHostCredentialsUnderJumpHopAccount() throws {
    let keychain = RecordingKeychainPasswordDataStore()
    let profileStore = SFTPConnectionProfileStore(defaults: isolatedDefaults())
    let model = SFTPConnectionFormModel(
      passwordStore: SFTPPasswordStore(keychain: keychain),
      profileStore: profileStore,
      privateKeyRepository: RecordingPrivateKeyRepository())
    model.host = "files.example"
    model.username = "tester"
    model.password = "m"
    model.addJumpHost()
    model.jumpHosts[0].host = "gateway"
    model.jumpHosts[0].username = "ops"
    model.jumpHosts[0].password = "r"

    let target = try #require(model.savePassword())

    #expect(keychain.savedPasswordsByAccount["gateway:22:ops"] == "r")
    #expect(keychain.savedPasswordsByAccount["files.example:22:tester"] == "m")
    #expect(target.jumpHosts.count == 1)
    #expect(
      target.jumpHosts.first?.identity
        == SFTPHopIdentity(host: "gateway", port: 22, username: "ops"))
    #expect(profileStore.loadAll().first?.jumpHosts.count == 1)
  }

  @Test("ユーザー名が空の踏み台は保存しない")
  func rejectsJumpHostWithEmptyUsername() {
    let profileStore = SFTPConnectionProfileStore(defaults: isolatedDefaults())
    let model = SFTPConnectionFormModel(
      passwordStore: SFTPPasswordStore(keychain: RecordingKeychainPasswordDataStore()),
      profileStore: profileStore,
      privateKeyRepository: RecordingPrivateKeyRepository())
    model.host = "files.example"
    model.username = "tester"
    model.password = "m"
    model.addJumpHost()
    model.jumpHosts[0].host = "gateway"
    model.jumpHosts[0].username = ""

    #expect(model.savePassword() == nil)
    #expect(model.errorMessage != nil)
    #expect(profileStore.loadAll().isEmpty)
  }

  @Test("既存の接続先を編集すると踏み台の入力値を復元する")
  func editingExistingTargetRestoresJumpHosts() throws {
    let jumpHost = try SFTPJumpHost(
      host: "gateway", port: 2222, username: "ops", label: "踏み台")
    let target = try SFTPConnectionTarget(
      host: "files.example",
      port: 22,
      username: "tester",
      jumpHosts: [jumpHost])
    let privateKeyURL = URL(filePath: "/private/keys/relay_ed25519")
    let repository = RecordingPrivateKeyRepository(
      restoredURLsByHop: [jumpHost.identity: privateKeyURL])

    let model = SFTPConnectionFormModel(
      target: target,
      passwordStore: SFTPPasswordStore(keychain: RecordingKeychainPasswordDataStore()),
      profileStore: SFTPConnectionProfileStore(defaults: isolatedDefaults()),
      privateKeyRepository: repository)

    let draft = try #require(model.jumpHosts.first)
    #expect(model.jumpHosts.count == 1)
    #expect(draft.host == "gateway")
    #expect(draft.port == "2222")
    #expect(draft.username == "ops")
    #expect(draft.password.isEmpty)
    #expect(draft.privateKeyURL == privateKeyURL)

    model.removeJumpHost(id: draft.id)

    #expect(model.jumpHosts.isEmpty)
  }

  @Test("鍵を操作していない踏み台の保存で共有ブックマークを削除しない")
  func savingWithoutTouchingKeyDoesNotRemoveSharedBookmark() throws {
    let profileA = try SFTPConnectionTarget(host: "bastion", port: 22, username: "ops")
    let keyURL = URL(filePath: "/fixture/shared-bastion-key")
    let repository = RecordingPrivateKeyRepository(
      restoredURLsByHop: [profileA.finalHop: keyURL])
    let model = SFTPConnectionFormModel(
      passwordStore: SFTPPasswordStore(keychain: InMemoryKeychainPasswordDataStore()),
      profileStore: SFTPConnectionProfileStore(defaults: isolatedDefaults()),
      privateKeyRepository: repository)
    model.host = "destination"
    model.username = "tester"
    model.password = "destination-password"
    model.addJumpHost()
    model.jumpHosts[0].host = "bastion"
    model.jumpHosts[0].username = "ops"
    #expect(model.jumpHosts[0].privateKeyURL == nil)

    _ = try #require(model.savePassword())

    #expect(try repository.restore(for: profileA) == keyURL)
    #expect(repository.removedHops.isEmpty)
  }

  @Test("復元済みの秘密鍵を解除したときだけブックマークを削除する")
  func clearingRestoredKeyRemovesBookmark() throws {
    let jumpHost = try SFTPJumpHost(host: "bastion", port: 22, username: "ops", label: nil)
    let target = try SFTPConnectionTarget(
      host: "destination", port: 22, username: "tester", jumpHosts: [jumpHost])
    let repository = RecordingPrivateKeyRepository(restoredURLsByHop: [
      target.finalHop: URL(filePath: "/fixture/destination-key"),
      jumpHost.identity: URL(filePath: "/fixture/bastion-key"),
    ])
    let model = SFTPConnectionFormModel(
      target: target,
      passwordStore: SFTPPasswordStore(keychain: InMemoryKeychainPasswordDataStore()),
      profileStore: SFTPConnectionProfileStore(defaults: isolatedDefaults()),
      privateKeyRepository: repository)
    #expect(model.privateKeyURL != nil)
    #expect(model.jumpHosts.first?.privateKeyURL != nil)
    model.privateKeyURL = nil
    model.jumpHosts[0].privateKeyURL = nil

    _ = try #require(model.savePassword())

    #expect(try repository.restore(for: target) == nil)
    #expect(try repository.restore(for: jumpHost.identity) == nil)
    #expect(Set(repository.removedHops) == Set([target.finalHop, jumpHost.identity]))
  }

  @Test("踏み台のユーザー名だけを編集したら空欄のパスワードを旧接続先から引き継ぐ")
  func jumpHostIdentityChangeCarriesPassword() throws {
    let originalHop = try SFTPJumpHost(host: "bastion", port: 22, username: "ops", label: nil)
    let target = try SFTPConnectionTarget(
      host: "destination", port: 22, username: "tester", jumpHosts: [originalHop])
    let passwordStore = SFTPPasswordStore(keychain: InMemoryKeychainPasswordDataStore())
    try passwordStore.save("existing-jump-password", for: originalHop.identity, kind: .password)
    let model = SFTPConnectionFormModel(
      target: target,
      passwordStore: passwordStore,
      profileStore: SFTPConnectionProfileStore(defaults: isolatedDefaults()),
      privateKeyRepository: RecordingPrivateKeyRepository())
    model.jumpHosts[0].username = "new-ops"
    #expect(model.jumpHosts[0].password.isEmpty)

    let updated = try #require(model.savePassword())
    let updatedHop = try #require(updated.jumpHosts.first?.identity)

    #expect(updatedHop == SFTPHopIdentity(host: "bastion", port: 22, username: "new-ops"))
    #expect(
      try passwordStore.secret(for: updatedHop, kind: .password) == "existing-jump-password")
    #expect(
      try passwordStore.secret(for: originalHop.identity, kind: .password)
        == "existing-jump-password")
  }

  @Test("踏み台のホストを変更したら旧接続先のパスワードを引き継がない")
  func jumpHostHostChangeDoesNotCarryPassword() throws {
    let originalHop = try SFTPJumpHost(host: "old-bastion", port: 22, username: "ops", label: nil)
    let target = try SFTPConnectionTarget(
      host: "destination", port: 22, username: "tester", jumpHosts: [originalHop])
    let passwordStore = SFTPPasswordStore(keychain: InMemoryKeychainPasswordDataStore())
    try passwordStore.save("old-password", for: originalHop.identity, kind: .password)
    let model = SFTPConnectionFormModel(
      target: target,
      passwordStore: passwordStore,
      profileStore: SFTPConnectionProfileStore(defaults: isolatedDefaults()),
      privateKeyRepository: RecordingPrivateKeyRepository())
    model.jumpHosts[0].host = "new-bastion"

    let updated = try #require(model.savePassword())
    let updatedHop = try #require(updated.jumpHosts.first?.identity)

    #expect(updatedHop == SFTPHopIdentity(host: "new-bastion", port: 22, username: "ops"))
    #expect(try passwordStore.secret(for: updatedHop, kind: .password) == nil)
    #expect(try passwordStore.secret(for: originalHop.identity, kind: .password) == "old-password")
  }

  @Test("踏み台のユーザー名変更時に変更先の保存済みパスワードを上書きしない")
  func jumpHostCarryDoesNotOverwriteExistingDestinationPassword() throws {
    let originalHop = try SFTPJumpHost(host: "bastion", port: 22, username: "ops", label: nil)
    let target = try SFTPConnectionTarget(
      host: "destination", port: 22, username: "tester", jumpHosts: [originalHop])
    let destination = SFTPHopIdentity(host: "bastion", port: 22, username: "new-ops")
    let passwordStore = SFTPPasswordStore(keychain: InMemoryKeychainPasswordDataStore())
    try passwordStore.save("source-password", for: originalHop.identity, kind: .password)
    try passwordStore.save("destination-password", for: destination, kind: .password)
    let model = SFTPConnectionFormModel(
      target: target,
      passwordStore: passwordStore,
      profileStore: SFTPConnectionProfileStore(defaults: isolatedDefaults()),
      privateKeyRepository: RecordingPrivateKeyRepository())
    model.jumpHosts[0].username = destination.username

    _ = try #require(model.savePassword())

    #expect(
      try passwordStore.secret(for: destination, kind: .password) == "destination-password")
    #expect(
      try passwordStore.secret(for: originalHop.identity, kind: .password) == "source-password")
  }

  @Test("先頭の踏み台行を削除しても次の行の資格情報を変更しない")
  func deletingFirstJumpRowDoesNotTouchSecondRowCredentials() throws {
    let first = try SFTPJumpHost(host: "gateway-a", port: 22, username: "ops-a", label: nil)
    let second = try SFTPJumpHost(host: "gateway-b", port: 2222, username: "ops-b", label: nil)
    let target = try SFTPConnectionTarget(
      host: "destination", port: 22, username: "tester", jumpHosts: [first, second])
    let firstKey = URL(filePath: "/fixture/gateway-a-key")
    let secondKey = URL(filePath: "/fixture/gateway-b-key")
    let repository = RecordingPrivateKeyRepository(restoredURLsByHop: [
      first.identity: firstKey,
      second.identity: secondKey,
    ])
    let passwordStore = SFTPPasswordStore(keychain: InMemoryKeychainPasswordDataStore())
    try passwordStore.save("first-password", for: first.identity, kind: .password)
    try passwordStore.save("second-password", for: second.identity, kind: .password)
    let model = SFTPConnectionFormModel(
      target: target,
      passwordStore: passwordStore,
      profileStore: SFTPConnectionProfileStore(defaults: isolatedDefaults()),
      privateKeyRepository: repository)
    let firstDraftID = try #require(model.jumpHosts.first?.id)

    model.removeJumpHost(id: firstDraftID)
    _ = try #require(model.savePassword())

    #expect(try passwordStore.secret(for: second.identity, kind: .password) == "second-password")
    #expect(try repository.restore(for: second.identity) == secondKey)
    #expect(!repository.removedHops.contains(first.identity))
  }

  @Test("並べ替えた踏み台の鍵解除は元の接続先のブックマークを削除する")
  func clearingKeyOnReorderedRowRemovesOriginalIdentityBookmark() throws {
    let first = try SFTPJumpHost(host: "gateway-a", port: 22, username: "ops-a", label: nil)
    let second = try SFTPJumpHost(host: "gateway-b", port: 2222, username: "ops-b", label: nil)
    let target = try SFTPConnectionTarget(
      host: "destination", port: 22, username: "tester", jumpHosts: [first, second])
    let firstKey = URL(filePath: "/fixture/gateway-a-key")
    let secondKey = URL(filePath: "/fixture/gateway-b-key")
    let repository = RecordingPrivateKeyRepository(restoredURLsByHop: [
      first.identity: firstKey,
      second.identity: secondKey,
    ])
    let model = SFTPConnectionFormModel(
      target: target,
      passwordStore: SFTPPasswordStore(keychain: InMemoryKeychainPasswordDataStore()),
      profileStore: SFTPConnectionProfileStore(defaults: isolatedDefaults()),
      privateKeyRepository: repository)

    model.jumpHosts.swapAt(0, 1)
    model.jumpHosts[0].privateKeyURL = nil
    _ = try #require(model.savePassword())

    #expect(try repository.restore(for: first.identity) == firstKey)
    #expect(try repository.restore(for: second.identity) == nil)
    #expect(repository.removedHops == [second.identity])
  }

  @Test("接続先編集時に空欄のパスワードは既存のKeychain値を引き継ぐ")
  func preservesExistingPasswordWhenEditing() throws {
    let existing = try SFTPConnectionTarget(host: "old.example.com", port: 22, username: "tester")
    let keychain = InMemoryKeychainPasswordDataStore()
    let passwordStore = SFTPPasswordStore(keychain: keychain)
    try passwordStore.save("existing-password", for: existing)
    let suiteName = "SFTPConnectionFormModelEditTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let profileStore = SFTPConnectionProfileStore(defaults: defaults)
    profileStore.save(existing)
    let model = SFTPConnectionFormModel(
      target: existing,
      passwordStore: passwordStore,
      profileStore: profileStore)
    model.host = "new.example.com"

    let updated = try #require(model.savePassword())

    #expect(try passwordStore.password(for: updated) == "existing-password")
    #expect(profileStore.loadAll() == [updated])
  }

  @Test("ssh_configの解決結果を接続フォームと踏み台行へ反映する")
  func applyImportFillsFormAndJumpDrafts() throws {
    let folderURL = URL(filePath: "/Users/test/.ssh", directoryHint: .isDirectory)
    let model = makeSSHConfigImportModel(folderURL: folderURL)
    let result = sshConfigImportResult(folderURL: folderURL)

    model.applyImport(result, folderURL: folderURL)

    #expect(model.host == "files.example")
    #expect(model.port == "2200")
    #expect(model.username == "tester")
    #expect(model.privateKeyURL == folderURL.appending(path: "id_files"))
    #expect(model.jumpHosts.count == 1)
    let jump = try #require(model.jumpHosts.first)
    #expect(jump.host == "gateway.example")
    #expect(jump.port == "2222")
    #expect(jump.username == "ops")
    #expect(jump.password.isEmpty)
    #expect(jump.privateKeyURL == folderURL.appending(path: "id_relay"))
    #expect(model.importWarnings == [.matchBlockIgnored(line: 7)])
  }

  @Test("ssh_configの適用だけでは接続プロファイルを保存しない")
  func importDoesNotTouchProfileStoreUntilSave() {
    let folderURL = URL(filePath: "/Users/test/.ssh", directoryHint: .isDirectory)
    let profileStore = SFTPConnectionProfileStore(defaults: isolatedDefaults())
    let keychain = RecordingKeychainPasswordDataStore()
    let privateKeyRepository = RecordingPrivateKeyRepository()
    let model = makeSSHConfigImportModel(
      folderURL: folderURL,
      profileStore: profileStore,
      keychain: keychain,
      privateKeyRepository: privateKeyRepository)

    model.applyImport(sshConfigImportResult(folderURL: folderURL), folderURL: folderURL)

    #expect(profileStore.loadAll().isEmpty)
    #expect(keychain.savedPasswordsByAccount.isEmpty)
    #expect(keychain.removedAccounts.isEmpty)
    #expect(privateKeyRepository.savedURLsByHop.isEmpty)
    #expect(privateKeyRepository.removedHops.isEmpty)
  }

  @Test("configへアクセスできない場合はフォルダ選択を一度だけ要求する")
  func unavailableAccessInvokesFolderPickerOnce() {
    let homeDirectory = URL(filePath: "/Users/test", directoryHint: .isDirectory)
    let reader = SSHConfigReader(
      homeDirectory: homeDirectory,
      accessRepository: FormSSHDirectoryAccessFixture.makeRepository(),
      fileReader: { _ in throw CocoaError(.fileReadNoPermission) })
    var pickerCallCount = 0
    let model = SFTPConnectionFormModel(
      passwordStore: SFTPPasswordStore(keychain: InMemoryKeychainPasswordDataStore()),
      profileStore: SFTPConnectionProfileStore(defaults: isolatedDefaults()),
      privateKeyRepository: RecordingPrivateKeyRepository(),
      sshConfigReader: reader,
      presentFolderPicker: {
        pickerCallCount += 1
        return nil
      })

    model.beginSSHConfigImport()

    #expect(pickerCallCount == 1)
    #expect(
      model.errorMessage
        == "~/.ssh フォルダへのアクセスを許可すると config を読み込めます")
  }

  @Test("接続テストでSFTPセッションを接続後に閉じる")
  func testsConnectionAndClosesSession() async throws {
    let keychain = InMemoryKeychainPasswordDataStore()
    let model = SFTPConnectionFormModel(
      passwordStore: SFTPPasswordStore(keychain: keychain),
      profileStore: SFTPConnectionProfileStore(defaults: isolatedDefaults()),
      connectionService: SuccessfulSFTPConnector())
    model.host = "example.com"
    model.username = "tester"
    model.password = "password"

    model.testConnection()
    await waitForConnectionTest(model)

    let testResultMessage = try #require(model.testResultMessage)
    #expect(testResultMessage.hasPrefix("応答 "))
    #expect(testResultMessage.hasSuffix("ms"))
    #expect(model.errorMessage == nil)
    #expect(!model.isTestingConnection)
  }

  @Test("接続テストの失敗はエラー分類器の文言で表示する")
  func testConnectionShowsClassifiedGuidanceOnFailure() async throws {
    let keychain = InMemoryKeychainPasswordDataStore()
    let model = SFTPConnectionFormModel(
      passwordStore: SFTPPasswordStore(keychain: keychain),
      profileStore: SFTPConnectionProfileStore(defaults: isolatedDefaults()),
      connectionService: FailingSFTPConnector())
    model.host = "example.com"
    model.username = "tester"
    model.password = "password"

    model.testConnection()
    await waitForConnectionTest(model)

    #expect(
      model.errorMessage
        == ConnectionErrorClassifier.guidanceMessage(
          for: SSHClientError.allAuthenticationOptionsFailed))
    #expect(model.testResultMessage == nil)
    #expect(!model.isTestingConnection)
  }

  private func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "SFTPConnectionFormModelTests-\(UUID().uuidString)")!
  }

  private func makeSSHConfigImportModel(
    folderURL: URL,
    profileStore: SFTPConnectionProfileStore? = nil,
    keychain: any KeychainPasswordDataStoring = InMemoryKeychainPasswordDataStore(),
    privateKeyRepository: any SFTPPrivateKeyBookmarkPersisting = RecordingPrivateKeyRepository()
  ) -> SFTPConnectionFormModel {
    let reader = SSHConfigReader(
      homeDirectory: folderURL.deletingLastPathComponent(),
      accessRepository: FormSSHDirectoryAccessFixture.makeRepository(),
      fileReader: { _ in "" })
    return SFTPConnectionFormModel(
      passwordStore: SFTPPasswordStore(keychain: keychain),
      profileStore: profileStore ?? SFTPConnectionProfileStore(defaults: isolatedDefaults()),
      privateKeyRepository: privateKeyRepository,
      sshConfigReader: reader,
      presentFolderPicker: { nil })
  }

  private func sshConfigImportResult(folderURL: URL) -> SSHConfigImportResult {
    SSHConfigImportResult(
      final: SSHConfigResolvedHop(
        alias: "files",
        hostName: "files.example",
        port: 2200,
        username: "tester",
        identityFiles: [folderURL.appending(path: "id_files").path]),
      jumpHops: [
        SSHConfigResolvedHop(
          alias: "gateway",
          hostName: "gateway.example",
          port: 2222,
          username: "ops",
          identityFiles: [folderURL.appending(path: "id_relay").path])
      ],
      warnings: [.matchBlockIgnored(line: 7)])
  }

  private func waitForConnectionTest(_ model: SFTPConnectionFormModel) async {
    await waitUntil("接続テストが期限内に完了しなかった") {
      !model.isTestingConnection
    }
  }
}

private enum FormSSHDirectoryAccessFixture {
  static func makeRepository(createError: NSError? = nil) -> SSHDirectoryAccessRepository {
    SSHDirectoryAccessRepository(
      storage: Storage(),
      codec: Codec(createError: createError))
  }

  private final class Storage: SSHDirectoryBookmarkStoring, @unchecked Sendable {
    func loadBookmarkData() -> Data? { nil }
    func saveBookmarkData(_: Data) {}
    func removeBookmarkData() {}
  }

  private struct Codec: FolderBookmarkCoding {
    var createError: NSError? = nil

    func createBookmark(for url: URL) throws -> Data {
      if let createError { throw createError }
      return Data(url.path.utf8)
    }

    func resolveBookmark(_: Data) throws -> ResolvedFolderBookmark {
      throw CocoaError(.fileReadCorruptFile)
    }
  }
}

private final class RecordingKeychainPasswordDataStore: KeychainPasswordDataStoring {
  private(set) var savedPassword: String?
  private(set) var savedPasswordsByAccount: [String: String] = [:]
  private(set) var removedAccounts: [String] = []

  func save(password: String, service _: String, account: String) throws {
    savedPassword = password
    savedPasswordsByAccount[account] = password
  }

  func password(service _: String, account _: String) throws -> String? {
    nil
  }

  func remove(service _: String, account: String) throws {
    removedAccounts.append(account)
  }
}

private final class RecordingPrivateKeyRepository: SFTPPrivateKeyBookmarkPersisting {
  private let onSave: ((URL) throws -> Void)?
  private(set) var savedURL: URL?
  private(set) var savedTarget: SFTPConnectionTarget?
  private(set) var savedURLsByHop: [SFTPHopIdentity: URL] = [:]
  private var restoredURLsByHop: [SFTPHopIdentity: URL]
  private(set) var removedHops: [SFTPHopIdentity] = []

  init(restoredURLsByHop: [SFTPHopIdentity: URL] = [:], onSave: ((URL) throws -> Void)? = nil) {
    self.restoredURLsByHop = restoredURLsByHop
    self.onSave = onSave
  }

  func save(_ privateKeyURL: URL, for target: SFTPConnectionTarget) throws {
    try onSave?(privateKeyURL)
    savedURL = privateKeyURL
    savedTarget = target
    savedURLsByHop[target.finalHop] = privateKeyURL
    restoredURLsByHop[target.finalHop] = privateKeyURL
  }

  func restore(for target: SFTPConnectionTarget) throws -> URL? {
    restoredURLsByHop[target.finalHop]
  }

  func remove(for target: SFTPConnectionTarget) {
    remove(for: target.finalHop)
  }

  func save(_ privateKeyURL: URL, for hop: SFTPHopIdentity) throws {
    try onSave?(privateKeyURL)
    savedURLsByHop[hop] = privateKeyURL
    restoredURLsByHop[hop] = privateKeyURL
  }

  func restore(for hop: SFTPHopIdentity) throws -> URL? {
    restoredURLsByHop[hop]
  }

  func remove(for hop: SFTPHopIdentity) {
    removedHops.append(hop)
    restoredURLsByHop[hop] = nil
  }
}

private final class InMemoryKeychainPasswordDataStore: KeychainPasswordDataStoring {
  private var passwords: [String: String] = [:]

  func save(password: String, service: String, account: String) throws {
    passwords["\(service):\(account)"] = password
  }

  func password(service: String, account: String) throws -> String? {
    passwords["\(service):\(account)"]
  }
}

private struct SuccessfulSFTPConnector: SFTPConnecting {
  func connect(to _: SFTPConnectionTarget) async throws -> any SFTPClientSession {
    TestSFTPClientSession()
  }
}

private struct FailingSFTPConnector: SFTPConnecting {
  func connect(to _: SFTPConnectionTarget) async throws -> any SFTPClientSession {
    throw SSHClientError.allAuthenticationOptionsFailed
  }
}

private struct TestSFTPClientSession: SFTPClientSession {
  func contents(of _: String) async throws -> [SFTPDirectoryEntry] {
    []
  }

  func createDirectory(at _: String) async throws {}

  func remove(at _: String, isDirectory _: Bool) async throws {}

  func rename(at _: String, to _: String) async throws {}

  func close() async throws {}
}
