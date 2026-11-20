import Citadel
import Crypto
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing

@testable import PKPane

struct CitadelSFTPConnectionServiceChainTests {
  @Test("踏み台から最終ホストの順に接続して最後のホップでSFTPを開く")
  func connectsHopsInOrderAndOpensSFTPOnLastHop() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanUp() }
    let target = try twoHopTarget()

    _ = try await fixture.service.connect(to: target, intent: .userInitiated, hopProgress: nil)

    #expect(await fixture.recorder.connectedAddresses() == ["gateway:2222", "files.example:22"])
    #expect(await fixture.recorder.openedAddresses() == ["files.example:22"])
  }

  @Test("2段目の接続失敗時は接続済みの1段目を閉じる")
  func failureOnSecondHopClosesFirstTransport() async throws {
    let fixture = try makeFixture(failingAddress: "files.example:22")
    defer { fixture.cleanUp() }
    let target = try twoHopTarget()

    let error = await capturedAnyConnectionError {
      _ = try await fixture.service.connect(
        to: target,
        intent: .userInitiated,
        hopProgress: nil)
    }

    #expect(await fixture.recorder.closedAddresses() == ["gateway:2222"])
    let connectionError = try #require(error as? SFTPHopConnectionError)
    #expect(connectionError.hop == target.finalHop)
    #expect((connectionError.underlying as? POSIXError)?.code == .ECONNREFUSED)
  }

  @Test("チェーンを閉じるとSFTPの後にトランスポートを逆順で閉じる")
  func closingChainedSessionClosesTransportsInReverse() async throws {
    let recorder = HopTransportRecorder()
    let network = FakeHopNetwork(recorder: recorder)
    let relay = FakeSSHHopTransport(address: "gateway:2222", network: network)
    let destination = FakeSSHHopTransport(address: "files.example:22", network: network)
    let base = MinimalSFTPClientSession(recorder: recorder)
    let session = SFTPChainedClientSession(
      base: base,
      transports: [relay, destination])

    try await session.close()

    #expect(await recorder.sessionCloseCount() == 1)
    #expect(await recorder.closedAddresses() == ["files.example:22", "gateway:2222"])
  }

  @Test("バックグラウンド接続では資格情報ダイアログを呼ばない")
  func backgroundIntentDoesNotPrompt() async throws {
    let fixture = try makeFixture(authenticationMode: .requireOffer)
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "gateway", port: 2222, username: "ops")

    await #expect(throws: SFTPConnectionServiceError.self) {
      _ = try await fixture.service.connect(to: target, intent: .background, hopProgress: nil)
    }

    #expect(await fixture.prompter.requests().isEmpty)
  }

  @Test("保存指定の入力パスワードを対象ホップのKeychain項目へ保存する")
  func promptAnswerWithSaveStoresIntoKeychainForThatHop() async throws {
    for succeeds in [true, false] {
      let answer = SFTPCredentialAnswer(secret: "entered", saveToKeychain: true)
      let fixture = try makeFixture(
        authenticationMode: .singleOfferPerDial,
        promptAnswers: [answer],
        authenticationFailures: succeeds ? [:] : ["gateway:2222": [1]])
      defer { fixture.cleanUp() }
      let target = try SFTPConnectionTarget(host: "gateway", port: 2222, username: "ops")

      if succeeds {
        _ = try await fixture.service.connect(to: target, intent: .userInitiated, hopProgress: nil)
      } else {
        _ = await capturedConnectionError {
          _ = try await fixture.service.connect(
            to: target, intent: .userInitiated, hopProgress: nil)
        }
      }

      let requests = await fixture.prompter.requests()
      #expect(requests.first?.hop == target.finalHop)
      #expect(requests.first?.kind == .password)
      let events = fixture.events.value
      #expect(events.first == "prompt:password")
      #expect(events.dropFirst().first == "dial:gateway:2222")
      if succeeds {
        #expect(requests.count == 1)
        #expect(fixture.keychain.password(forAccount: "gateway:2222:ops") == "entered")
        let authenticated = try #require(events.firstIndex(of: "authenticated:gateway:2222"))
        let saved = try #require(events.firstIndex(of: "save:gateway:2222:ops"))
        #expect(authenticated < saved)
      } else {
        #expect(fixture.keychain.password(forAccount: "gateway:2222:ops") == nil)
        #expect(!events.contains("save:gateway:2222:ops"))
      }
    }
  }

  @Test("拒否された保存済みパスワードはKeychainにもキャッシュにも残す")
  func rejectedStoredPasswordIsKeptInKeychainAndCache() async throws {
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      authenticationFailures: ["gateway:2222": [1]])
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "gateway", port: 2222, username: "ops")
    try fixture.passwordStore.save("rejected", for: target.finalHop, kind: .password)
    await fixture.credentialCache.store("rejected", for: target.finalHop, kind: .password)

    let error = await capturedConnectionError {
      _ = try await fixture.service.connect(to: target, intent: .background, hopProgress: nil)
    }

    #expect(error == .hopAuthenticationFailed(target.finalHop, reason: nil))
    #expect(
      try fixture.passwordStore.secret(for: target.finalHop, kind: .password) == "rejected")
    #expect(
      await fixture.credentialCache.secret(for: target.finalHop, kind: .password) == "rejected")
    #expect(await fixture.recorder.directAddresses() == ["gateway:2222"])
    #expect(await fixture.recorder.offers(for: "gateway:2222") == [.password])
    #expect(await fixture.prompter.requests().isEmpty)
  }

  @Test("未信頼ホスト鍵の承認要求は失敗したホップのホストとポートを持つ")
  func hostKeyErrorCarriesHopIdentity() async throws {
    let fixture = try makeFixture(validateHostKey: true)
    defer { fixture.cleanUp() }
    let target = try twoHopTarget()

    let error = await capturedConnectionError {
      _ = try await fixture.service.connect(
        to: target,
        intent: .userInitiated,
        hopProgress: nil)
    }

    guard case .hostKeyRequiresApproval(let request) = error else {
      Issue.record("未信頼ホスト鍵がhostKeyRequiresApprovalへ変換されませんでした。")
      return
    }
    #expect(
      request
        == SFTPHostKeyApprovalRequest(
          host: "gateway",
          port: 2222,
          publicKey: request.publicKey))
    #expect(!request.publicKey.isEmpty)
    #expect(await fixture.recorder.openedAddresses().isEmpty)
    #expect(await fixture.recorder.directAddresses() == ["gateway:2222"])
  }

  @Test("鍵の認証失敗後は同じホップを保存パスワードで再ダイヤルする")
  func redialsSameHopWithNextCandidateAfterAuthenticationFailure() async throws {
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      authenticationFailures: ["gateway:2222": [1]])
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "gateway", port: 2222, username: "ops")
    let privateKeyURL = try makePrivateKeyURL()
    defer { try? FileManager.default.removeItem(at: privateKeyURL) }
    try fixture.privateKeys.save(privateKeyURL, for: target.finalHop)
    let keyPassphrase = "key-passphrase"
    let loginPassword = "login-password"
    try fixture.keychain.save(
      password: keyPassphrase,
      service: "テスト専用",
      account: SFTPPasswordStore.account(
        for: target.finalHop,
        kind: .passphrase(keyPath: privateKeyURL.path)))
    try fixture.keychain.save(
      password: loginPassword,
      service: "テスト専用",
      account: SFTPPasswordStore.account(for: target.finalHop, kind: .password))

    do {
      _ = try await fixture.service.connect(to: target, intent: .userInitiated, hopProgress: nil)
    } catch {
      Issue.record("鍵が拒否された後に保存パスワードで接続できませんでした。")
    }

    #expect(await fixture.recorder.directAddresses() == ["gateway:2222", "gateway:2222"])
    #expect(await fixture.recorder.offers(for: "gateway:2222") == [.privateKey, .password])
    #expect(await fixture.recorder.openedAddresses() == ["gateway:2222"])
    #expect(await fixture.prompter.requests().isEmpty)
  }

  @Test("鍵の復号に使う保存値をログインパスワードとして提示しない")
  func passphraseUsedForKeyDecryptionIsNeverOfferedAsLoginPassword() async throws {
    for hasSeparatePassphrase in [false, true] {
      let passphrase = UUID().uuidString
      let fixture = try makeFixture(
        authenticationMode: .singleOfferPerDial,
        authenticationFailures: ["gateway:2222": [1]],
        keyLoader: { _, suppliedPassphrase in
          guard suppliedPassphrase == passphrase else { throw ChainTestError.passphraseRequired }
          return NIOSSHPrivateKey(ed25519Key: .init())
        })
      defer { fixture.cleanUp() }
      let target = try SFTPConnectionTarget(host: "gateway", port: 2222, username: "ops")
      let privateKeyURL = try makePrivateKeyURL()
      defer { try? FileManager.default.removeItem(at: privateKeyURL) }
      try fixture.privateKeys.save(privateKeyURL, for: target.finalHop)
      let loginPassword = UUID().uuidString
      try fixture.passwordStore.save(
        hasSeparatePassphrase ? loginPassword : passphrase,
        for: target.finalHop,
        kind: .password)
      if hasSeparatePassphrase {
        try fixture.keychain.save(
          password: passphrase,
          service: "テスト専用",
          account: SFTPPasswordStore.account(
            for: target.finalHop,
            kind: .passphrase(keyPath: privateKeyURL.path)))
      }

      // 復号用の保存値の扱いだけを検証し、入力による別候補は追加しない。
      _ = try? await fixture.service.connect(to: target, intent: .background, hopProgress: nil)

      if hasSeparatePassphrase {
        #expect(await fixture.recorder.directAddresses() == ["gateway:2222", "gateway:2222"])
        #expect(await fixture.recorder.offers(for: "gateway:2222") == [.privateKey, .password])
        let offeredOnlyLoginPassword = await fixture.recorder.passwordOffersMatch(
          [loginPassword], for: "gateway:2222")
        #expect(offeredOnlyLoginPassword)
        #expect(await fixture.recorder.openedAddresses() == ["gateway:2222"])
      } else {
        #expect(await fixture.recorder.directAddresses() == ["gateway:2222"])
        #expect(await fixture.recorder.offers(for: "gateway:2222") == [.privateKey])
        #expect(await fixture.recorder.openedAddresses().isEmpty)
      }
      #expect(await fixture.prompter.requests().isEmpty)
    }
  }

  @Test("後段ホップの認証失敗時は接続済みの踏み台を再ダイヤルしない")
  func redialsOnlyFailingHopNotEarlierHops() async throws {
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      promptAnswers: [SFTPCredentialAnswer(secret: "entered", saveToKeychain: false)],
      authenticationFailures: ["files.example:22": [1]])
    defer { fixture.cleanUp() }
    let target = try twoHopTarget()
    let relay = try #require(target.hops.first)
    try fixture.passwordStore.save("gateway", for: relay, kind: .password)
    try fixture.passwordStore.save("rejected", for: target.finalHop, kind: .password)

    do {
      _ = try await fixture.service.connect(to: target, intent: .userInitiated, hopProgress: nil)
    } catch {
      Issue.record("後段ホップを再ダイヤルして接続できませんでした。")
    }

    #expect(await fixture.recorder.directAddresses() == ["gateway:2222"])
    #expect(await fixture.recorder.jumpedAddresses() == ["files.example:22", "files.example:22"])
    #expect(await fixture.recorder.offers(for: "files.example:22") == [.password, .password])
    #expect(await fixture.recorder.openedAddresses() == ["files.example:22"])
    #expect(await fixture.recorder.closedAddresses().isEmpty)
    #expect(await fixture.prompter.requests().map(\.hop) == [target.finalHop])
  }

  @Test("入力パスワードは1回だけ試し、拒否ならhopAuthenticationFailedで終わる")
  func promptsOnceAndFailsWhenEnteredPasswordIsRejected() async throws {
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      promptAnswers: [SFTPCredentialAnswer(secret: "a", saveToKeychain: false)],
      authenticationFailures: ["files.example:22": [1]])
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")

    let error = await capturedConnectionError {
      _ = try await fixture.service.connect(to: target, intent: .userInitiated, hopProgress: nil)
    }

    #expect(await fixture.prompter.requests().map(\.attempt) == [1])
    #expect(await fixture.recorder.directAddresses() == ["files.example:22"])
    #expect(await fixture.recorder.offers(for: "files.example:22") == [.password])
    #expect(await fixture.recorder.openedAddresses().isEmpty)
    #expect(error == .hopAuthenticationFailed(target.finalHop, reason: nil))
    #expect(fixture.events.value == ["prompt:password", "dial:files.example:22"])
  }

  @Test("A1: 拒否された保存パスワードの後に入力した値でKeychainを上書きする")
  func enteredPasswordOverwritesStaleStoredPasswordAfterSuccess() async throws {
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      promptAnswers: [SFTPCredentialAnswer(secret: "entered", saveToKeychain: true)],
      authenticationFailures: ["files.example:22": [1]])
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")
    try fixture.passwordStore.save("stale", for: target.finalHop, kind: .password)
    // 事前投入のsaveイベントを、認証成功後の保存順序の検証から外す。
    fixture.events.withValue { $0.removeAll() }

    _ = try await fixture.service.connect(to: target, intent: .userInitiated, hopProgress: nil)

    #expect(await fixture.prompter.requests().map(\.attempt) == [1])
    #expect(try fixture.passwordStore.secret(for: target.finalHop, kind: .password) == "entered")
    let events = fixture.events.value
    let authenticated = try #require(events.firstIndex(of: "authenticated:files.example:22"))
    let saved = try #require(events.firstIndex(of: "save:files.example:22:tester"))
    #expect(authenticated < saved)
    #expect(
      await fixture.recorder.directAddresses() == ["files.example:22", "files.example:22"])
    #expect(await fixture.recorder.offers(for: "files.example:22") == [.password, .password])
  }

  @Test("A2: 入力パスワードも拒否されたらダイアログは1回で止まり保存値は消えない")
  func rejectedEnteredPasswordStopsAfterOnePromptAndKeepsStoredValue() async throws {
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      promptAnswers: [SFTPCredentialAnswer(secret: "entered", saveToKeychain: false)],
      authenticationFailures: ["files.example:22": [1, 2]])
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")
    try fixture.passwordStore.save("stale", for: target.finalHop, kind: .password)

    let error = await capturedConnectionError {
      _ = try await fixture.service.connect(to: target, intent: .userInitiated, hopProgress: nil)
    }

    #expect(error == .hopAuthenticationFailed(target.finalHop, reason: nil))
    #expect(await fixture.prompter.requests().count == 1)
    #expect(try fixture.passwordStore.secret(for: target.finalHop, kind: .password) == "stale")
    #expect(
      await fixture.credentialCache.secret(for: target.finalHop, kind: .password) == nil)
  }

  @Test("A3: ダイアログをキャンセルしても保存パスワードは消えない")
  func cancelledPromptKeepsStoredPassword() async throws {
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      authenticationFailures: ["files.example:22": [1]])
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")
    try fixture.passwordStore.save("stale", for: target.finalHop, kind: .password)

    let error = await capturedConnectionError {
      _ = try await fixture.service.connect(to: target, intent: .userInitiated, hopProgress: nil)
    }

    #expect(error == .authenticationCancelled)
    #expect(await fixture.prompter.requests().count == 1)
    #expect(try fixture.passwordStore.secret(for: target.finalHop, kind: .password) == "stale")
  }

  @Test("A4: 踏み台の保存パスワード拒否でもKeychainを残し後続ホップへ進まない")
  func rejectedJumpHostPasswordIsKeptAndChainStops() async throws {
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      authenticationFailures: ["gateway:2222": [1]])
    defer { fixture.cleanUp() }
    let target = try twoHopTarget()
    let relay = try #require(target.hops.first)
    try fixture.passwordStore.save("stale", for: relay, kind: .password)
    // 最終ホップの認証準備でダイアログが先に呼ばれて経路が変わらないよう保存しておく。
    try fixture.passwordStore.save("final", for: target.finalHop, kind: .password)

    let error = await capturedConnectionError {
      _ = try await fixture.service.connect(to: target, intent: .userInitiated, hopProgress: nil)
    }

    #expect(error == .authenticationCancelled)
    #expect(await fixture.recorder.directAddresses() == ["gateway:2222"])
    #expect(await fixture.recorder.jumpedAddresses().isEmpty)
    #expect(try fixture.passwordStore.secret(for: relay, kind: .password) == "stale")
  }

  @Test("A5: 入力して成功した値は同一セッションの再接続で保存値より優先される")
  func sessionCachedPasswordTakesPrecedenceOverStaleKeychainValue() async throws {
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      promptAnswers: [SFTPCredentialAnswer(secret: "entered", saveToKeychain: false)],
      authenticationFailures: ["files.example:22": [1]])
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")
    try fixture.passwordStore.save("stale", for: target.finalHop, kind: .password)

    _ = try await fixture.service.connect(to: target, intent: .userInitiated, hopProgress: nil)
    _ = try await fixture.service.connect(to: target, intent: .userInitiated, hopProgress: nil)

    #expect(await fixture.prompter.requests().count == 1)
    #expect(
      await fixture.recorder.passwordOffersMatch(
        ["stale", "entered", "entered"], for: "files.example:22"))
    // 別の値で成功した時点で古いKeychain値は確定的に無効なので削除される。
    #expect(try fixture.passwordStore.secret(for: target.finalHop, kind: .password) == nil)
    #expect(
      await fixture.credentialCache.secret(for: target.finalHop, kind: .password) == "entered")
  }

  @Test("A6: 拒否済みの保存パスワードはバックグラウンド再接続で再送しない")
  func rejectedPasswordIsNotResentByBackgroundReconnect() async throws {
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      authenticationFailures: ["files.example:22": [1]])
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")
    try fixture.passwordStore.save("stale", for: target.finalHop, kind: .password)

    let first = await capturedConnectionError {
      _ = try await fixture.service.connect(to: target, intent: .userInitiated, hopProgress: nil)
    }
    let second = await capturedConnectionError {
      _ = try await fixture.service.connect(to: target, intent: .background, hopProgress: nil)
    }

    #expect(first == .authenticationCancelled)
    #expect(second == .hopAuthenticationFailed(target.finalHop, reason: nil))
    #expect(await fixture.recorder.directAddresses() == ["files.example:22"])
    #expect(await fixture.recorder.offers(for: "files.example:22") == [.password])
    #expect(try fixture.passwordStore.secret(for: target.finalHop, kind: .password) == "stale")
  }

  @Test("A7: キャッシュが拒否されたらKeychainの保存パスワードを続けて試す")
  func keychainPasswordIsTriedAfterCachedPasswordIsRejected() async throws {
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      authenticationFailures: ["files.example:22": [1]])
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")
    try fixture.passwordStore.save("stored", for: target.finalHop, kind: .password)
    await fixture.credentialCache.store("cached", for: target.finalHop, kind: .password)

    _ = try await fixture.service.connect(to: target, intent: .userInitiated, hopProgress: nil)

    #expect(await fixture.prompter.requests().isEmpty)
    #expect(
      await fixture.recorder.passwordOffersMatch(["cached", "stored"], for: "files.example:22"))
    #expect(
      await fixture.credentialCache.secret(for: target.finalHop, kind: .password) == "cached")
    #expect(try fixture.passwordStore.secret(for: target.finalHop, kind: .password) == "stored")
  }

  @Test("A9: 同じ値を保存しないで入力して成功しても保存値は消えない")
  func enteringSameValueWithoutSavingKeepsStoredPassword() async throws {
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      promptAnswers: [SFTPCredentialAnswer(secret: "same", saveToKeychain: false)],
      authenticationFailures: ["files.example:22": [1]])
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")
    try fixture.passwordStore.save("same", for: target.finalHop, kind: .password)

    _ = try await fixture.service.connect(to: target, intent: .userInitiated, hopProgress: nil)

    #expect(await fixture.prompter.requests().count == 1)
    #expect(try fixture.passwordStore.secret(for: target.finalHop, kind: .password) == "same")
    #expect(
      await fixture.credentialCache.secret(for: target.finalHop, kind: .password) == "same")
    #expect(
      await fixture.recorder.passwordOffersMatch(["same", "same"], for: "files.example:22"))
  }

  @Test("A8: 入力して成功したら拒否の印が解除されバックグラウンドでも接続できる")
  func successClearsRejectionSoBackgroundReconnectConnects() async throws {
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      promptAnswers: [SFTPCredentialAnswer(secret: "entered", saveToKeychain: true)],
      authenticationFailures: ["files.example:22": [1]])
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")
    try fixture.passwordStore.save("stale", for: target.finalHop, kind: .password)

    _ = try await fixture.service.connect(to: target, intent: .userInitiated, hopProgress: nil)
    _ = try await fixture.service.connect(to: target, intent: .background, hopProgress: nil)

    #expect(
      await fixture.recorder.passwordOffersMatch(
        ["stale", "entered", "entered"], for: "files.example:22"))
    #expect(try fixture.passwordStore.secret(for: target.finalHop, kind: .password) == "entered")
    #expect(await fixture.prompter.requests().count == 1)
  }

  @Test("通信エラーでは認証候補を切り替えて再ダイヤルしない")
  func nonAuthenticationErrorDoesNotRedial() async throws {
    let fixture = try makeFixture(
      failingAddress: "files.example:22",
      authenticationMode: .singleOfferPerDial,
      promptAnswers: [SFTPCredentialAnswer(secret: "unused", saveToKeychain: false)])
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")
    try fixture.passwordStore.save("stored", for: target.finalHop, kind: .password)

    let error = await capturedAnyConnectionError {
      _ = try await fixture.service.connect(to: target, intent: .userInitiated, hopProgress: nil)
    }

    #expect(await fixture.recorder.directAddresses() == ["files.example:22"])
    #expect(await fixture.prompter.requests().isEmpty)
    let connectionError = try #require(error as? SFTPHopConnectionError)
    #expect(connectionError.hop == target.finalHop)
  }

  @Test("ホップの通信エラーは自動再接続の対象に残る")
  func transportErrorIsNotReconnectFutile() async throws {
    let fixture = try makeFixture(
      failingAddress: "gateway:2222", authenticationMode: .singleOfferPerDial)
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "gateway", port: 2222, username: "ops")
    try fixture.passwordStore.save("stored", for: target.finalHop, kind: .password)

    let error = try #require(
      await capturedAnyConnectionError {
        _ = try await fixture.service.connect(to: target, intent: .background, hopProgress: nil)
      })

    let connectionError = try #require(error as? SFTPHopConnectionError)
    #expect(connectionError.hop == target.finalHop)
    #expect((connectionError.underlying as? POSIXError)?.code == .ECONNREFUSED)
    #expect(TransferReconnectionPolicy.isEligibleForAutoReconnect(error))
    #expect(await fixture.recorder.directAddresses() == ["gateway:2222"])
    #expect(await fixture.prompter.requests().isEmpty)
  }

  @Test("読めない鍵はダイヤル候補から外して保存パスワードへ進み理由を保持する")
  func unreadableKeyFallsThroughToPasswordWithReason() async throws {
    for passwordSucceeds in [true, false] {
      let loads = ChainLockedValue<[String?]>([])
      let fixture = try makeFixture(
        authenticationMode: .singleOfferPerDial,
        authenticationFailures: passwordSucceeds ? [:] : ["gateway:2222": [1]],
        keyLoader: { _, passphrase in
          loads.withValue { $0.append(passphrase) }
          throw SFTPConnectionServiceError.privateKeyNotFound
        })
      defer { fixture.cleanUp() }
      let target = try SFTPConnectionTarget(host: "gateway", port: 2222, username: "ops")
      let keyURL = URL(filePath: "/fixture/unreadable-key")
      try fixture.privateKeys.save(keyURL, for: target.finalHop)
      try fixture.passwordStore.save("login", for: target.finalHop, kind: .password)

      if passwordSucceeds {
        _ = try await fixture.service.connect(to: target, intent: .background, hopProgress: nil)
        #expect(await fixture.recorder.openedAddresses() == ["gateway:2222"])
      } else {
        let error = await capturedConnectionError {
          _ = try await fixture.service.connect(to: target, intent: .background, hopProgress: nil)
        }
        guard case .hopAuthenticationFailed(let hop, let reason) = error else {
          Issue.record("候補が尽きた鍵の読込失敗がホップ認証エラーになりませんでした。")
          continue
        }
        #expect(hop == target.finalHop)
        #expect(reason == SFTPConnectionServiceError.privateKeyNotFound.localizedDescription)
      }

      #expect(!loads.value.isEmpty)
      #expect(await fixture.recorder.directAddresses() == ["gateway:2222"])
      #expect(await fixture.recorder.offers(for: "gateway:2222") == [.password])
      #expect(await fixture.recorder.passwordOffersMatch(["login"], for: "gateway:2222"))
      #expect(await fixture.prompter.requests().isEmpty)
    }
  }

  @Test("最終ホップの旧パスワード項目で鍵を復号して専用項目へ移行する")
  func encryptedKeyPromptsPassphraseBeforeDialAndMigratesLegacySlot() async throws {
    let loads = ChainLockedValue<[String?]>([])
    let passphrase = UUID().uuidString
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      keyLoader: { _, suppliedPassphrase in
        loads.withValue { $0.append(suppliedPassphrase) }
        guard suppliedPassphrase == passphrase else { throw ChainTestError.passphraseRequired }
        return NIOSSHPrivateKey(ed25519Key: .init())
      })
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "gateway", port: 2222, username: "ops")
    let keyURL = URL(filePath: "/fixture/encrypted-legacy-key")
    try fixture.privateKeys.save(keyURL, for: target.finalHop)
    try fixture.passwordStore.save(passphrase, for: target.finalHop, kind: .password)

    _ = try await fixture.service.connect(to: target, intent: .userInitiated, hopProgress: nil)

    #expect(loads.value.contains(passphrase))
    #expect(try fixture.passwordStore.secret(for: target.finalHop, kind: .password) == nil)
    #expect(
      try fixture.passwordStore.secret(
        for: target.finalHop, kind: .passphrase(keyPath: keyURL.path))
        == passphrase)
    #expect(await fixture.recorder.directAddresses() == ["gateway:2222"])
    #expect(await fixture.recorder.offers(for: "gateway:2222") == [.privateKey])
    #expect(await fixture.recorder.passwordOffersMatch([], for: "gateway:2222"))
    #expect(await fixture.prompter.requests().isEmpty)
  }

  @Test("暗号化鍵のパスフレーズはダイヤル前に1回聞いて成功後に保存する")
  func encryptedKeyWithoutPassphrasePromptsOnce() async throws {
    let events = ChainLockedValue<[String]>([])
    let loads = ChainLockedValue<[String?]>([])
    let passphrase = UUID().uuidString
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      promptAnswers: [SFTPCredentialAnswer(secret: passphrase, saveToKeychain: true)],
      events: events,
      keyLoader: { _, suppliedPassphrase in
        loads.withValue { $0.append(suppliedPassphrase) }
        guard suppliedPassphrase == passphrase else { throw ChainTestError.passphraseRequired }
        events.withValue { $0.append("keyLoaded") }
        return NIOSSHPrivateKey(ed25519Key: .init())
      })
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "gateway", port: 2222, username: "ops")
    let keyURL = URL(filePath: "/fixture/encrypted-prompt-key")
    try fixture.privateKeys.save(keyURL, for: target.finalHop)

    _ = try await fixture.service.connect(to: target, intent: .userInitiated, hopProgress: nil)

    let requests = await fixture.prompter.requests()
    #expect(requests.count == 1)
    #expect(requests.first?.hop == target.finalHop)
    #expect(requests.first?.kind == .passphrase(keyPath: keyURL.path))
    #expect(requests.first?.attempt == 1)
    #expect(loads.value.first == .some(nil))
    #expect(loads.value.last == .some(passphrase))
    let prompt = try #require(events.value.firstIndex(of: "prompt:passphrase"))
    let loaded = try #require(events.value.firstIndex(of: "keyLoaded"))
    let dial = try #require(events.value.firstIndex(of: "dial:gateway:2222"))
    #expect(prompt < loaded)
    #expect(loaded < dial)
    #expect(
      try fixture.passwordStore.secret(
        for: target.finalHop, kind: .passphrase(keyPath: keyURL.path))
        == passphrase)
    #expect(try fixture.passwordStore.secret(for: target.finalHop, kind: .password) == nil)
    #expect(await fixture.recorder.offers(for: "gateway:2222") == [.privateKey])
  }

  @Test("バックグラウンドで暗号化鍵を復号できなければ入力もダイヤルもしない")
  func backgroundIntentWithEncryptedKeyFailsWithoutPrompt() async throws {
    let loads = ChainLockedValue<[String?]>([])
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      keyLoader: { _, passphrase in
        loads.withValue { $0.append(passphrase) }
        throw ChainTestError.passphraseRequired
      })
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "gateway", port: 2222, username: "ops")
    try fixture.privateKeys.save(
      URL(filePath: "/fixture/encrypted-background-key"), for: target.finalHop)

    let error = await capturedConnectionError {
      _ = try await fixture.service.connect(to: target, intent: .background, hopProgress: nil)
    }

    guard case .hopAuthenticationFailed(let hop, let reason) = error else {
      Issue.record("バックグラウンドの復号失敗がホップ認証エラーになりませんでした。")
      return
    }
    #expect(hop == target.finalHop)
    #expect(reason?.isEmpty == false)
    #expect(!loads.value.isEmpty)
    #expect(await fixture.prompter.requests().isEmpty)
    #expect(await fixture.recorder.directAddresses().isEmpty)
  }

  @Test("鍵の復号に使えなかった旧パスワード項目はログイン候補に残す")
  func legacyPasswordSlotRemainsCandidateWhenNotUsedForDecryption() async throws {
    let loads = ChainLockedValue<[String?]>([])
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      keyLoader: { _, passphrase in
        loads.withValue { $0.append(passphrase) }
        throw ChainTestError.passphraseRequired
      })
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "gateway", port: 2222, username: "ops")
    let keyURL = URL(filePath: "/fixture/encrypted-login-password-key")
    try fixture.privateKeys.save(keyURL, for: target.finalHop)
    try fixture.passwordStore.save("login-password", for: target.finalHop, kind: .password)

    _ = try await fixture.service.connect(to: target, intent: .background, hopProgress: nil)

    #expect(loads.value == [nil, "login-password"])
    #expect(await fixture.recorder.directAddresses() == ["gateway:2222"])
    #expect(await fixture.recorder.offers(for: "gateway:2222") == [.password])
    #expect(
      await fixture.recorder.passwordOffersMatch(["login-password"], for: "gateway:2222"))
    #expect(await fixture.recorder.openedAddresses() == ["gateway:2222"])
    #expect(await fixture.prompter.requests().isEmpty)
  }

  @Test("接続キャンセルをホップ通信エラーで包まない")
  func cancellationIsNotWrappedAsHopConnectionError() async throws {
    let fixture = try makeFixture(
      cancellingAddress: "gateway:2222",
      authenticationMode: .singleOfferPerDial)
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "gateway", port: 2222, username: "ops")
    try fixture.passwordStore.save("stored", for: target.finalHop, kind: .password)

    let error = try #require(
      await capturedAnyConnectionError {
        _ = try await fixture.service.connect(to: target, intent: .background, hopProgress: nil)
      })

    #expect(error is CancellationError)
    #expect(!(error is SFTPHopConnectionError))
    #expect(await fixture.recorder.directAddresses() == ["gateway:2222"])
  }

  @Test("本番用の鍵読込は1回の復号結果を再利用する")
  func productionKeyLoadDecryptsOnce() async throws {
    let loadCount = ChainLockedValue(0)
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      keyLoader: { _, _ in
        loadCount.withValue { $0 += 1 }
        return NIOSSHPrivateKey(ed25519Key: .init())
      })
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "gateway", port: 2222, username: "ops")
    try fixture.privateKeys.save(URL(filePath: "/fixture/plain-key"), for: target.finalHop)

    _ = try await fixture.service.connect(to: target, intent: .background, hopProgress: nil)

    #expect(loadCount.value == 1)
    #expect(await fixture.recorder.offers(for: "gateway:2222") == [.privateKey])
  }

  @Test("本番の鍵読込は保存済みパスフレーズで暗号化Ed25519鍵を使って接続する")
  func productionLoaderUsesStoredPassphraseForEncryptedEd25519Key() async throws {
    let fixture = try makeFixture(authenticationMode: .singleOfferPerDial, keyLoader: nil)
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "gateway", port: 2222, username: "ops")
    let keyURL = try writeOpenSSHKeyFixture(Self.encryptedEd25519Key)
    defer { try? FileManager.default.removeItem(at: keyURL) }
    try fixture.privateKeys.save(keyURL, for: target.finalHop)
    try fixture.passwordStore.save(
      Self.fixturePassphrase, for: target.finalHop, kind: .passphrase(keyPath: keyURL.path))

    let session = try await fixture.service.connect(
      to: target, intent: .background, hopProgress: nil)
    try await session.close()

    #expect(await fixture.recorder.directAddresses() == ["gateway:2222"])
    #expect(await fixture.recorder.offers(for: "gateway:2222") == [.privateKey])
    #expect(await fixture.prompter.requests().isEmpty)
  }

  @Test("本番の鍵読込は暗号化Ed25519鍵のパスフレーズを対話接続で1回だけ求める")
  func productionLoaderPromptsOnceForEncryptedEd25519Key() async throws {
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      promptAnswers: [SFTPCredentialAnswer(secret: Self.fixturePassphrase, saveToKeychain: false)],
      keyLoader: nil)
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "gateway", port: 2222, username: "ops")
    let keyURL = try writeOpenSSHKeyFixture(Self.encryptedEd25519Key)
    defer { try? FileManager.default.removeItem(at: keyURL) }
    try fixture.privateKeys.save(keyURL, for: target.finalHop)

    let session = try await fixture.service.connect(
      to: target, intent: .userInitiated, hopProgress: nil)
    try await session.close()

    let requests = await fixture.prompter.requests()
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.hop == target.finalHop)
    #expect(request.kind == .passphrase(keyPath: keyURL.path))
    #expect(request.attempt == 1)
    #expect(await fixture.recorder.directAddresses() == ["gateway:2222"])
    #expect(await fixture.recorder.offers(for: "gateway:2222") == [.privateKey])
  }

  @Test("本番の鍵読込は暗号化されていないOpenSSH ECDSA P-256鍵で接続する")
  func productionLoaderUsesUnencryptedECDSAP256Key() async throws {
    let fixture = try makeFixture(authenticationMode: .singleOfferPerDial, keyLoader: nil)
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "gateway", port: 2222, username: "ops")
    let keyURL = try writeOpenSSHKeyFixture(Self.unencryptedECDSAP256Key)
    defer { try? FileManager.default.removeItem(at: keyURL) }
    try fixture.privateKeys.save(keyURL, for: target.finalHop)

    let session = try await fixture.service.connect(
      to: target, intent: .background, hopProgress: nil)
    try await session.close()

    #expect(await fixture.recorder.directAddresses() == ["gateway:2222"])
    #expect(await fixture.recorder.offers(for: "gateway:2222") == [.privateKey])
  }

  @Test("直接接続と踏み台経由の各ホップでAES-128-CTRだけを追加する")
  func addsOnlyAES128CTRToEveryHop() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanUp() }
    let target = try twoHopTarget()

    let session = try await fixture.service.connect(
      to: target, intent: .background, hopProgress: nil)
    try await session.close()

    let settingsByHop = await fixture.recorder.dialSettings()
    #expect(settingsByHop.map { "\($0.host):\($0.port)" } == ["gateway:2222", "files.example:22"])
    for settings in settingsByHop {
      let address = "\(settings.host):\(settings.port)"
      let keepsDefaultKeyExchange = settings.algorithms.keyExchangeAlgorithms == nil
      let keepsDefaultPublicKeys = settings.algorithms.publicKeyAlgorihtms == nil
      #expect(keepsDefaultKeyExchange, "\(address)")
      #expect(keepsDefaultPublicKeys, "\(address)")
      guard case .add(let schemes) = settings.algorithms.transportProtectionSchemes else {
        Issue.record("\(address) の暗号設定に追加指定がありません。")
        continue
      }
      #expect(
        schemes.map { ObjectIdentifier($0) } == [ObjectIdentifier(AES128CTR.self)], "\(address)")
    }
  }

  // 使い捨てのテスト専用鍵。
  private static let fixturePassphrase = "pkpane-test-passphrase"
  private static let openSSHPrivateKeyHeader = "-----BEGIN OPENSSH " + "PRIVATE KEY-----"

  private static let encryptedEd25519Key = """
    \(openSSHPrivateKeyHeader)
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBUCKZKSW
    +njxALCIO9Bs61AAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIJgasoiihOkOiuvH
    jSdBo2SrRDyFgjmXF0rov8HKGRdUAAAAoHtT26lrcaipUXeqwcdMAX+fKWrv8XGh57Sgi0
    AydseHAx04tVZYig6yrF5txk718HeVeEQ5YcydfunxPy749zkUGarifcPGBVTMHx9fZ56I
    X4MfrrzSqt9gF7NHScsSucALUAgno+OXzm1wVCzWghD7gyRPzL2+jkj5z3HRO15iZlEk3E
    j/rQSBkPa6r8bcJiBpDgzaBgd8mBuQBRQBCoM=
    -----END OPENSSH PRIVATE KEY-----
    """ + "\n"

  private static let unencryptedECDSAP256Key = """
    \(openSSHPrivateKeyHeader)
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
    1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQQ8bamcRsesrfFmezCIUp8lgxi+lrK7
    bjqW/ttEPKMSrveE51Id5nSHOK9aq3vE+IjWpQVyFs8SIQb13RcrCoYEAAAAsLXzWkG181
    pBAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBDxtqZxGx6yt8WZ7
    MIhSnyWDGL6WsrtuOpb+20Q8oxKu94TnUh3mdIc4r1qre8T4iNalBXIWzxIhBvXdFysKhg
    QAAAAgWjzzjSGitMNkjJh60jIfPexc1dsKnMpB1/Xqw5drAisAAAATcGtwYW5lLXRlc3Qt
    Zml4dHVyZQECAwQF
    -----END OPENSSH PRIVATE KEY-----
    """ + "\n"

  private func writeOpenSSHKeyFixture(_ key: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "pkpane-key-\(UUID())")
    try #require(
      FileManager.default.createFile(
        atPath: url.path,
        contents: Data(key.utf8),
        attributes: [.posixPermissions: 0o600]))
    return url
  }

  private func makePrivateKeyURL() throws -> URL {
    // テスト専用の鍵をリポジトリ内のビルド領域に生成し、実ユーザーの鍵を参照しない。
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent(".derived-data/chain-test-key-\(UUID().uuidString)")
    let key = Curve25519.Signing.PrivateKey().makeSSHRepresentation()
    try #require(
      FileManager.default.createFile(
        atPath: url.path,
        contents: Data(key.utf8),
        attributes: [.posixPermissions: 0o600]))
    return url
  }

  private func makeFixture(
    failingAddress: String? = nil,
    cancellingAddress: String? = nil,
    authenticationMode: FakeAuthenticationMode = .none,
    promptAnswers: [SFTPCredentialAnswer?] = [],
    validateHostKey: Bool = false,
    authenticationFailures: [String: Set<Int>] = [:],
    availableMethods: NIOSSHAvailableUserAuthenticationMethods = [.publicKey, .password],
    events: ChainLockedValue<[String]> = ChainLockedValue([]),
    keyLoader: (@Sendable (URL, String?) throws -> NIOSSHPrivateKey)? = { url, passphrase in
      let key = try String(contentsOf: url, encoding: .utf8)
      return NIOSSHPrivateKey(
        ed25519Key: try .init(sshEd25519: key, decryptionKey: passphrase.map { Data($0.utf8) }))
    }
  ) throws -> ConnectionServiceFixture {
    let keychain = InMemoryChainKeychainPasswordDataStore(events: events)
    let passwordStore = SFTPPasswordStore(keychain: keychain)
    let privateKeys = InMemoryChainPrivateKeyBookmarkRepository()
    let recorder = HopTransportRecorder()
    let prompter = RecordingChainCredentialPrompter(answers: promptAnswers, events: events)
    let network = FakeHopNetwork(
      recorder: recorder,
      failingAddress: failingAddress,
      cancellingAddress: cancellingAddress,
      authenticationMode: authenticationMode,
      validateHostKey: validateHostKey,
      authenticationFailures: authenticationFailures,
      availableMethods: availableMethods,
      events: events)
    let (defaults, suiteName) = isolatedDefaults()
    let trustStore = SFTPHostKeyTrustStore(defaults: defaults)
    let credentialCache = SFTPSessionCredentialCache()
    let validatorFactory = CitadelSFTPHostKeyValidatorFactory(trustStore: trustStore)
    let hopConnector: SSHHopConnector = { settings in try await network.connect(settings: settings)
    }
    let service: CitadelSFTPConnectionService
    if let keyLoader {
      service = CitadelSFTPConnectionService(
        passwordStore: passwordStore,
        privateKeyRepository: privateKeys,
        hostKeyValidatorFactory: validatorFactory,
        hopConnector: hopConnector,
        credentialPrompter: prompter,
        credentialCache: credentialCache,
        keyLoader: keyLoader)
    } else {
      service = CitadelSFTPConnectionService(
        passwordStore: passwordStore,
        privateKeyRepository: privateKeys,
        hostKeyValidatorFactory: validatorFactory,
        hopConnector: hopConnector,
        credentialPrompter: prompter,
        credentialCache: credentialCache)
    }

    if authenticationMode == .none {
      // 認証自体を対象にしない既存チェーンテストには保存済み資格情報を用意する。
      try passwordStore.save(
        "fixture",
        for: SFTPHopIdentity(host: "gateway", port: 2222, username: "ops"),
        kind: .password)
      try passwordStore.save(
        "fixture",
        for: SFTPHopIdentity(host: "files.example", port: 22, username: "tester"),
        kind: .password)
    }

    return ConnectionServiceFixture(
      service: service,
      passwordStore: passwordStore,
      keychain: keychain,
      privateKeys: privateKeys,
      recorder: recorder,
      prompter: prompter,
      credentialCache: credentialCache,
      events: events,
      defaults: defaults,
      defaultsSuiteName: suiteName)
  }

  private func twoHopTarget() throws -> SFTPConnectionTarget {
    let relay = try SFTPJumpHost(host: "gateway", port: 2222, username: "ops", label: "踏み台")
    return try SFTPConnectionTarget(
      host: "files.example",
      port: 22,
      username: "tester",
      jumpHosts: [relay])
  }

  private func isolatedDefaults() -> (UserDefaults, String) {
    let suiteName = "CitadelSFTPConnectionServiceChainTests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
  }
}

extension CitadelSFTPConnectionServiceChainTests {
  private typealias AuthMethodsProber =
    @Sendable (SSHClientSettings, (any SSHHopTransport)?) async -> SSHAuthMethodsProbeResult

  @Test("U1: 保存パスワードが拒否され、対応方式が空ならダイアログもKeychainの変更もない")
  func emptyProbedMethodsAfterStoredPasswordRejection() async throws {
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      authenticationFailures: ["files.example:22": [1]])
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")
    try fixture.passwordStore.save("stored", for: target.finalHop, kind: .password)
    let events = fixture.events
    events.withValue { $0.removeAll() }
    let service = makeProbedService(fixture) { _, _ in
      events.withValue { $0.append("probe") }
      return .methods([])
    }

    let error = await capturedConnectionError {
      _ = try await service.connect(to: target, intent: .userInitiated, hopProgress: nil)
    }

    #expect(error == .unsupportedAuthenticationMethods(target.finalHop))
    #expect(await fixture.prompter.requests().isEmpty)
    #expect(await fixture.recorder.offers(for: "files.example:22") == [.password])
    #expect(events.value == ["dial:files.example:22", "probe"])
    #expect(try fixture.passwordStore.secret(for: target.finalHop, kind: .password) == "stored")
  }

  @Test("U2: 保存資格情報がなく公開鍵のみ提示されたらダイアログなしで秘密鍵を求める")
  func probedPublicKeyOnlyWithNoStoredCredentials() async throws {
    let fixture = try makeFixture(authenticationMode: .singleOfferPerDial)
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")
    let service = makeProbedService(fixture) { _, _ in .methods([.publicKey]) }

    let error = await capturedConnectionError {
      _ = try await service.connect(to: target, intent: .userInitiated, hopProgress: nil)
    }

    #expect(error == .publicKeyAuthenticationRequired(target.finalHop))
    #expect(await fixture.prompter.requests().isEmpty)
    #expect(await fixture.recorder.connectedAddresses().isEmpty)
  }

  @Test("U3: パスワード認証が提示されたらダイアログを1回出す")
  func probedPasswordPromptsOnce() async throws {
    let fixture = try makeFixture(authenticationMode: .singleOfferPerDial)
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")
    let events = fixture.events
    let service = makeProbedService(fixture) { _, _ in
      events.withValue { $0.append("probe") }
      return .methods([.password])
    }

    let error = await capturedConnectionError {
      _ = try await service.connect(to: target, intent: .userInitiated, hopProgress: nil)
    }

    #expect(error == .authenticationCancelled)
    #expect(await fixture.prompter.requests().map(\.attempt) == [1])
    #expect(events.value == ["probe", "prompt:password"])
  }

  @Test("U4: 認証方式が不明ならダイアログを1回出す")
  func unknownProbeResultPromptsOnce() async throws {
    let fixture = try makeFixture(authenticationMode: .singleOfferPerDial)
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")
    let events = fixture.events
    let service = makeProbedService(fixture) { _, _ in
      events.withValue { $0.append("probe") }
      return .unknown
    }

    let error = await capturedConnectionError {
      _ = try await service.connect(to: target, intent: .userInitiated, hopProgress: nil)
    }

    #expect(error == .authenticationCancelled)
    #expect(await fixture.prompter.requests().map(\.attempt) == [1])
    #expect(events.value == ["probe", "prompt:password"])
  }

  @Test("U5: 秘密鍵または保存パスワードで認証できたらプローブを呼ばない", arguments: [true, false])
  func successfulStoredAuthenticationDoesNotProbe(usePrivateKey: Bool) async throws {
    let fixture = try makeFixture(authenticationMode: .singleOfferPerDial)
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")
    if usePrivateKey {
      try fixture.privateKeys.save(URL(filePath: "/fixture/probe-key"), for: target.finalHop)
    } else {
      try fixture.passwordStore.save("stored", for: target.finalHop, kind: .password)
    }
    let probes = ChainLockedValue(0)
    let service = makeProbedService(fixture) { _, _ in
      probes.withValue { $0 += 1 }
      return .methods([])
    }

    let session = try await service.connect(to: target, intent: .userInitiated, hopProgress: nil)
    try await session.close()

    let expectedOffer: ChainAuthenticationOfferKind = usePrivateKey ? .privateKey : .password
    #expect(await fixture.recorder.offers(for: "files.example:22") == [expectedOffer])
    #expect(probes.value == 0)
    #expect(await fixture.prompter.requests().isEmpty)
  }

  @Test("U6: バックグラウンド接続ではプローブもダイアログもなく認証失敗を返す")
  func backgroundAuthenticationFailureDoesNotProbe() async throws {
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      authenticationFailures: ["files.example:22": [1]])
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")
    try fixture.passwordStore.save("stored", for: target.finalHop, kind: .password)
    let probes = ChainLockedValue(0)
    let service = makeProbedService(fixture) { _, _ in
      probes.withValue { $0 += 1 }
      return .methods([])
    }

    let error = await capturedConnectionError {
      _ = try await service.connect(to: target, intent: .background, hopProgress: nil)
    }

    #expect(error == .hopAuthenticationFailed(target.finalHop, reason: nil))
    #expect(await fixture.recorder.offers(for: "files.example:22") == [.password])
    #expect(probes.value == 0)
    #expect(await fixture.prompter.requests().isEmpty)
  }

  @Test("U7: 2段目のプローブに接続先のホップと接続済みの踏み台を渡す")
  func secondHopProbeReceivesDestinationAndPreviousTransport() async throws {
    let fixture = try makeFixture(authenticationMode: .singleOfferPerDial)
    defer { fixture.cleanUp() }
    let jump = try SFTPJumpHost(host: "gateway", port: 2222, username: "ops", label: "踏み台")
    let target = try SFTPConnectionTarget(
      host: "destination.example", port: 2207, username: "destination-user", jumpHosts: [jump])
    let relay = try #require(target.hops.first)
    try fixture.passwordStore.save("relay-password", for: relay, kind: .password)
    let calls = ChainLockedValue<[(SSHClientSettings, ObjectIdentifier?)]>([])
    let service = makeProbedService(fixture) { settings, previous in
      let identifier = (previous as? FakeSSHHopTransport).map(ObjectIdentifier.init)
      calls.withValue { $0.append((settings, identifier)) }
      return .methods([.password])
    }

    let error = await capturedConnectionError {
      _ = try await service.connect(to: target, intent: .userInitiated, hopProgress: nil)
    }

    #expect(error == .authenticationCancelled)
    #expect(await fixture.prompter.requests().map(\.hop) == [target.finalHop])
    #expect(await fixture.recorder.connectedAddresses() == ["gateway:2222"])
    let recordedCalls = calls.value
    try #require(recordedCalls.count == 1)
    let (settings, previousIdentifier) = try #require(recordedCalls.first)
    #expect(settings.host == target.finalHop.host)
    #expect(settings.port == target.finalHop.port)
    #expect(try probeUsername(from: settings) == target.finalHop.username)
    let relayIdentifier = try #require(await fixture.recorder.directTransportIdentifier())
    #expect(previousIdentifier == relayIdentifier)
  }

  @Test("U8: 新しい認証エラーに接続先が入り、案内文言はエラーの説明と一致する")
  func probeErrorsIncludeHostAndPortInGuidance() throws {
    let hop = SFTPHopIdentity(host: "files.example", port: 2207, username: "tester")
    let errors: [SFTPConnectionServiceError] = [
      .unsupportedAuthenticationMethods(hop), .publicKeyAuthenticationRequired(hop),
    ]

    for error in errors {
      let description = try #require(error.errorDescription)
      #expect(description.contains("files.example:2207"))
      #expect(ConnectionErrorClassifier.classify(error) == .authenticationFailed)
      #expect(ConnectionErrorClassifier.guidanceMessage(for: error) == description)
    }
  }

  @Test("U9: hopConnectorのみを注入した構成は認証方式が不明の場合と同様にダイアログを1回出す")
  func injectedConnectorWithoutProberPromptsOnce() async throws {
    let fixture = try makeFixture(authenticationMode: .singleOfferPerDial, keyLoader: nil)
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(
      host: "no-network.invalid", port: 2207, username: "tester")

    let error = await capturedConnectionError {
      _ = try await fixture.service.connect(to: target, intent: .userInitiated, hopProgress: nil)
    }

    #expect(error == .authenticationCancelled)
    #expect(await fixture.prompter.requests().map(\.attempt) == [1])
    #expect(await fixture.recorder.connectedAddresses().isEmpty)
  }

  @Test("U10: 設定済みの鍵が拒否されて公開鍵のみ提示されたらダイアログなしでホップ認証失敗を返す")
  func rejectedConfiguredKeyWithPublicKeyOnlyReturnsHopAuthenticationFailure() async throws {
    let fixture = try makeFixture(
      authenticationMode: .singleOfferPerDial,
      authenticationFailures: ["files.example:22": [1]])
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")
    try fixture.privateKeys.save(URL(filePath: "/fixture/probe-key"), for: target.finalHop)
    let events = fixture.events
    let service = makeProbedService(fixture) { _, _ in
      events.withValue { $0.append("probe") }
      return .methods([.publicKey])
    }

    let error = await capturedConnectionError {
      _ = try await service.connect(to: target, intent: .userInitiated, hopProgress: nil)
    }

    #expect(error == .hopAuthenticationFailed(target.finalHop, reason: nil))
    #expect(await fixture.prompter.requests().isEmpty)
    #expect(await fixture.recorder.offers(for: "files.example:22") == [.privateKey])
    #expect(events.value == ["dial:files.example:22", "probe"])
  }

  @Test("U11: 認証方式が不明でも未承認または変更されたホスト鍵のエラーを先に返す", arguments: [false, true])
  func unknownProbeResultReturnsHostKeyError(hasTrustedKey: Bool) async throws {
    let fixture = try makeFixture(authenticationMode: .singleOfferPerDial)
    defer { fixture.cleanUp() }
    let target = try SFTPConnectionTarget(host: "files.example", port: 2207, username: "tester")
    if hasTrustedKey {
      let trustedKey = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
      SFTPHostKeyTrustStore(defaults: fixture.defaults)
        .trust(openSSHPublicKey: String(openSSHPublicKey: trustedKey), for: target)
    }
    let presentedPublicKey = ChainLockedValue<String?>(nil)
    let service = makeProbedService(fixture) { settings, _ in
      let hostKey = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
      presentedPublicKey.withValue { $0 = String(openSSHPublicKey: hostKey) }
      let eventLoop = EmbeddedEventLoop()
      let promise = eventLoop.makePromise(of: Void.self)
      settings.hostKeyValidator.validateHostKey(
        hostKey: hostKey, validationCompletePromise: promise)
      eventLoop.run()
      return .unknown
    }

    let error = await capturedConnectionError {
      _ = try await service.connect(to: target, intent: .userInitiated, hopProgress: nil)
    }

    let request = SFTPHostKeyApprovalRequest(
      host: target.finalHop.host,
      port: target.finalHop.port,
      publicKey: try #require(presentedPublicKey.value))
    let expectedError: SFTPConnectionServiceError =
      hasTrustedKey ? .hostKeyChanged(request) : .hostKeyRequiresApproval(request)
    #expect(error == expectedError)
    #expect(await fixture.prompter.requests().isEmpty)
    #expect(await fixture.recorder.directAddresses().isEmpty)
  }

  private func makeProbedService(
    _ fixture: ConnectionServiceFixture,
    authMethodsProber: @escaping AuthMethodsProber
  ) -> CitadelSFTPConnectionService {
    CitadelSFTPConnectionService(
      passwordStore: fixture.passwordStore,
      privateKeyRepository: fixture.privateKeys,
      hostKeyValidatorFactory: fixture.service.hostKeyValidatorFactory,
      hopConnector: fixture.service.hopConnector,
      authMethodsProber: authMethodsProber,
      credentialPrompter: fixture.prompter,
      credentialCache: fixture.credentialCache,
      keyLoader: { _, _ in NIOSSHPrivateKey(ed25519Key: .init()) })
  }

  private func probeUsername(from settings: SSHClientSettings) throws -> String {
    // SSHClientSettingsでは認証デリゲートの提示内容からユーザー名を確認する。
    let eventLoop = EmbeddedEventLoop()
    let promise = eventLoop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
    let result = ChainLockedValue<Result<NIOSSHUserAuthenticationOffer?, Error>?>(nil)
    promise.futureResult.whenComplete { completion in
      result.withValue { $0 = completion }
    }
    settings.authenticationMethod().nextAuthenticationType(
      availableMethods: [.publicKey, .password], nextChallengePromise: promise)
    eventLoop.run()
    let completion = try #require(result.value)
    let offer = try #require(try completion.get())
    return offer.username
  }
}

private struct ConnectionServiceFixture {
  let service: CitadelSFTPConnectionService
  let passwordStore: SFTPPasswordStore
  let keychain: InMemoryChainKeychainPasswordDataStore
  let privateKeys: InMemoryChainPrivateKeyBookmarkRepository
  let recorder: HopTransportRecorder
  let prompter: RecordingChainCredentialPrompter
  let credentialCache: SFTPSessionCredentialCache
  let events: ChainLockedValue<[String]>
  let defaults: UserDefaults
  let defaultsSuiteName: String

  func cleanUp() {
    defaults.removePersistentDomain(forName: defaultsSuiteName)
  }
}

private enum FakeAuthenticationMode: Equatable, Sendable {
  case none
  case requireOffer
  case rejectFirstOffer
  case singleOfferPerDial
}

private enum ChainAuthenticationOfferKind: Equatable, Sendable {
  case privateKey
  case password
  case other
}

private final class FakeHopNetwork: @unchecked Sendable {
  let recorder: HopTransportRecorder
  private let failingAddress: String?
  private let cancellingAddress: String?
  private let authenticationMode: FakeAuthenticationMode
  private let validateHostKey: Bool
  private let authenticationFailures: [String: Set<Int>]
  private let availableMethods: NIOSSHAvailableUserAuthenticationMethods
  private let events: ChainLockedValue<[String]>

  init(
    recorder: HopTransportRecorder,
    failingAddress: String? = nil,
    cancellingAddress: String? = nil,
    authenticationMode: FakeAuthenticationMode = .none,
    validateHostKey: Bool = false,
    authenticationFailures: [String: Set<Int>] = [:],
    availableMethods: NIOSSHAvailableUserAuthenticationMethods = [.publicKey, .password],
    events: ChainLockedValue<[String]> = ChainLockedValue([])
  ) {
    self.recorder = recorder
    self.failingAddress = failingAddress
    self.cancellingAddress = cancellingAddress
    self.authenticationMode = authenticationMode
    self.validateHostKey = validateHostKey
    self.authenticationFailures = authenticationFailures
    self.availableMethods = availableMethods
    self.events = events
  }

  func connect(settings: SSHClientSettings) async throws -> any SSHHopTransport {
    try await makeTransport(settings: settings, isJump: false)
  }

  func jump(settings: SSHClientSettings) async throws -> any SSHHopTransport {
    try await makeTransport(settings: settings, isJump: true)
  }

  private func makeTransport(
    settings: SSHClientSettings,
    isJump: Bool
  ) async throws -> any SSHHopTransport {
    let address = "\(settings.host):\(settings.port)"
    events.withValue { $0.append("dial:\(address)") }
    let dial = await recorder.recordConnection(settings, isJump: isJump)

    if validateHostKey {
      try validate(settings: settings)
    }
    if failingAddress == address {
      throw POSIXError(.ECONNREFUSED)
    }
    if cancellingAddress == address {
      throw CancellationError()
    }
    try await simulateAuthentication(settings: settings, address: address)
    if authenticationFailures[address]?.contains(dial) == true {
      throw SSHClientError.allAuthenticationOptionsFailed
    }
    events.withValue { $0.append("authenticated:\(address)") }
    let transport = FakeSSHHopTransport(address: address, network: self)
    if !isJump {
      await recorder.recordDirectTransport(ObjectIdentifier(transport))
    }
    return transport
  }

  private func validate(settings: SSHClientSettings) throws {
    let eventLoop = EmbeddedEventLoop()
    let promise = eventLoop.makePromise(of: Void.self)
    let result = ChainLockedValue<Result<Void, Error>?>(nil)
    promise.futureResult.whenComplete { completion in
      result.withValue { $0 = completion }
    }
    let hostKey = NIOSSHPrivateKey(ed25519Key: .init()).publicKey

    settings.hostKeyValidator.validateHostKey(
      hostKey: hostKey,
      validationCompletePromise: promise)
    try waitForPromise(result, eventLoop: eventLoop).get()
  }

  private func simulateAuthentication(settings: SSHClientSettings, address: String) async throws {
    guard authenticationMode != .none else { return }
    let authentication = settings.authenticationMethod()
    let first = try authenticationOffer(from: authentication)
    guard first != nil else {
      throw ChainTestError.authenticationRejected
    }
    if let first {
      let kind: ChainAuthenticationOfferKind
      switch first.offer {
      case .privateKey: kind = .privateKey
      case .password(let password):
        kind = .password
        await recorder.recordPassword(password.password, for: address)
      default: kind = .other
      }
      await recorder.recordOffer(kind, for: address)
    }
    // このモードでは実Citadelと同様、1ダイヤルでデリゲートを1回だけ呼ぶ。
    guard authenticationMode == .rejectFirstOffer else { return }

    _ = try authenticationOffer(from: authentication)
    throw ChainTestError.authenticationRejected
  }

  private func authenticationOffer(
    from authentication: SSHAuthenticationMethod
  ) throws -> NIOSSHUserAuthenticationOffer? {
    let eventLoop = EmbeddedEventLoop()
    let promise = eventLoop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
    let result = ChainLockedValue<Result<NIOSSHUserAuthenticationOffer?, Error>?>(nil)
    promise.futureResult.whenComplete { completion in
      result.withValue { $0 = completion }
    }

    authentication.nextAuthenticationType(
      availableMethods: availableMethods,
      nextChallengePromise: promise)
    return try waitForPromise(result, eventLoop: eventLoop).get()
  }
}

private final class FakeSSHHopTransport: SSHHopTransport, @unchecked Sendable {
  private let address: String
  private let network: FakeHopNetwork

  init(address: String, network: FakeHopNetwork) {
    self.address = address
    self.network = network
  }

  func jump(to settings: SSHClientSettings) async throws -> any SSHHopTransport {
    try await network.jump(settings: settings)
  }

  func openSFTPSession() async throws -> any SFTPClientSession {
    await network.recorder.recordOpen(address)
    return MinimalSFTPClientSession(recorder: network.recorder)
  }

  func close() async throws {
    await network.recorder.recordClose(address)
  }
}

private actor HopTransportRecorder {
  private var settingsByHop: [SSHClientSettings] = []
  private var connected: [String] = []
  private var direct: [String] = []
  private var jumped: [String] = []
  private var authenticationOffers: [String: [ChainAuthenticationOfferKind]] = [:]
  private var passwordOffers: [String: [String]] = [:]
  private var opened: [String] = []
  private var closed: [String] = []
  private var baseSessionCloseCount = 0
  private var directTransport: ObjectIdentifier?

  func recordConnection(_ settings: SSHClientSettings, isJump: Bool) -> Int {
    let address = "\(settings.host):\(settings.port)"
    settingsByHop.append(settings)
    connected.append(address)
    if isJump {
      jumped.append(address)
    } else {
      direct.append(address)
    }
    return connected.filter { $0 == address }.count
  }

  func recordOffer(_ offer: ChainAuthenticationOfferKind, for address: String) {
    authenticationOffers[address, default: []].append(offer)
  }

  func recordPassword(_ password: String, for address: String) {
    passwordOffers[address, default: []].append(password)
  }

  func recordOpen(_ address: String) {
    opened.append(address)
  }

  func recordClose(_ address: String) {
    closed.append(address)
  }

  func recordSessionClose() {
    baseSessionCloseCount += 1
  }

  func recordDirectTransport(_ identifier: ObjectIdentifier) {
    directTransport = identifier
  }

  func directTransportIdentifier() -> ObjectIdentifier? { directTransport }
  func dialSettings() -> [SSHClientSettings] { settingsByHop }
  func connectedAddresses() -> [String] { connected }
  func directAddresses() -> [String] { direct }
  func jumpedAddresses() -> [String] { jumped }
  func offers(for address: String) -> [ChainAuthenticationOfferKind] {
    authenticationOffers[address, default: []]
  }
  func passwordOffersMatch(_ expected: [String], for address: String) -> Bool {
    passwordOffers[address, default: []] == expected
  }
  func openedAddresses() -> [String] { opened }
  func closedAddresses() -> [String] { closed }
  func sessionCloseCount() -> Int { baseSessionCloseCount }
}

private struct MinimalSFTPClientSession: SFTPClientSession {
  let recorder: HopTransportRecorder

  func contents(of _: String) async throws -> [SFTPDirectoryEntry] { [] }
  func createDirectory(at _: String) async throws {}
  func remove(at _: String, isDirectory _: Bool) async throws {}
  func rename(at _: String, to _: String) async throws {}
  func close() async throws { await recorder.recordSessionClose() }
}

private actor RecordingChainCredentialPrompter: SFTPCredentialPrompting {
  private var answers: [SFTPCredentialAnswer?]
  private var recordedRequests: [SFTPCredentialRequest] = []
  private let events: ChainLockedValue<[String]>

  init(answers: [SFTPCredentialAnswer?], events: ChainLockedValue<[String]>) {
    self.answers = answers
    self.events = events
  }

  func requestCredential(_ request: SFTPCredentialRequest) async -> SFTPCredentialAnswer? {
    recordedRequests.append(request)
    if case .password = request.kind {
      events.withValue { $0.append("prompt:password") }
    } else {
      events.withValue { $0.append("prompt:passphrase") }
    }
    guard !answers.isEmpty else { return nil }
    return answers.removeFirst()
  }

  func requests() -> [SFTPCredentialRequest] {
    recordedRequests
  }
}

private final class InMemoryChainKeychainPasswordDataStore: KeychainPasswordDataStoring,
  @unchecked Sendable
{
  private let entries = ChainLockedValue<[String: String]>([:])
  private let events: ChainLockedValue<[String]>

  init(events: ChainLockedValue<[String]>) {
    self.events = events
  }

  func save(password: String, service _: String, account: String) throws {
    events.withValue { $0.append("save:\(account)") }
    entries.withValue { $0[account] = password }
  }

  func password(service _: String, account: String) throws -> String? {
    entries.value[account]
  }

  func remove(service _: String, account: String) throws {
    events.withValue { $0.append("remove:\(account)") }
    entries.withValue { $0[account] = nil }
  }

  func password(forAccount account: String) -> String? {
    entries.value[account]
  }
}

private final class InMemoryChainPrivateKeyBookmarkRepository:
  SFTPPrivateKeyBookmarkPersisting, @unchecked Sendable
{
  private let entries = ChainLockedValue<[SFTPHopIdentity: URL]>([:])

  func save(_ privateKeyURL: URL, for target: SFTPConnectionTarget) throws {
    try save(privateKeyURL, for: target.finalHop)
  }

  func restore(for target: SFTPConnectionTarget) throws -> URL? {
    try restore(for: target.finalHop)
  }

  func remove(for target: SFTPConnectionTarget) {
    remove(for: target.finalHop)
  }

  func save(_ privateKeyURL: URL, for hop: SFTPHopIdentity) throws {
    entries.withValue { $0[hop] = privateKeyURL }
  }

  func restore(for hop: SFTPHopIdentity) throws -> URL? {
    entries.value[hop]
  }

  func remove(for hop: SFTPHopIdentity) {
    entries.withValue { $0[hop] = nil }
  }
}

private func capturedConnectionError(
  _ operation: () async throws -> Void
) async -> SFTPConnectionServiceError? {
  do {
    try await operation()
    Issue.record("接続が失敗せず完了しました。")
    return nil
  } catch let error as SFTPConnectionServiceError {
    return error
  } catch {
    Issue.record("想定外のエラー型でした: \(type(of: error))")
    return nil
  }
}

private func capturedAnyConnectionError(
  _ operation: () async throws -> Void
) async -> (any Error)? {
  do {
    try await operation()
    Issue.record("接続が失敗せず完了しました。")
    return nil
  } catch {
    return error
  }
}

private func waitForPromise<Value>(
  _ result: ChainLockedValue<Result<Value, Error>?>,
  eventLoop: EmbeddedEventLoop
) throws -> Result<Value, Error> {
  for _ in 0..<2_000 where result.value == nil {
    eventLoop.run()
    if result.value == nil {
      Thread.sleep(forTimeInterval: 0.001)
    }
  }
  eventLoop.run()
  guard let completion = result.value else {
    Issue.record("フェイクSSH処理のpromiseが期限内に完了しませんでした。")
    throw ChainTestError.promiseTimedOut
  }
  return completion
}

private final class ChainLockedValue<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: Value

  init(_ value: Value) {
    storedValue = value
  }

  var value: Value {
    lock.withLock { storedValue }
  }

  @discardableResult
  func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
    try lock.withLock {
      try body(&storedValue)
    }
  }
}

private enum ChainTestError: Error {
  case connectionFailed
  case authenticationRejected
  case promiseTimedOut
  case passphraseRequired
}
