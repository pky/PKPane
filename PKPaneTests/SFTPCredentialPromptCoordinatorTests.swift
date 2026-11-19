import Testing

@testable import PKPane

@MainActor
struct SFTPCredentialPromptCoordinatorTests {
  @Test("資格情報の要求を1件ずつ表示する")
  func requestsAreShownOneAtATime() async throws {
    let coordinator = SFTPCredentialPromptCoordinator(presentsUI: true)
    let firstRequest = SFTPCredentialRequest(
      hop: SFTPHopIdentity(host: "gateway", port: 2222, username: "ops"),
      kind: .password,
      attempt: 1,
      label: "踏み台")
    let secondRequest = SFTPCredentialRequest(
      hop: SFTPHopIdentity(host: "files.example", port: 22, username: "tester"),
      kind: .password,
      attempt: 1,
      label: nil)

    let firstTask = Task {
      await coordinator.requestCredential(firstRequest)
    }
    await waitUntil("最初の資格情報要求が表示されなかった") {
      coordinator.current?.request == firstRequest
    }

    let secondTask = Task {
      await coordinator.requestCredential(secondRequest)
    }
    await Task.yield()

    #expect(coordinator.current?.request == firstRequest)

    coordinator.submit(secret: "gateway-password", saveToKeychain: true)
    let firstAnswer = await firstTask.value
    await waitUntil("2件目の資格情報要求が表示されなかった") {
      coordinator.current?.request == secondRequest
    }

    #expect(
      firstAnswer
        == SFTPCredentialAnswer(secret: "gateway-password", saveToKeychain: true))

    coordinator.submit(secret: "target-password", saveToKeychain: false)
    let secondAnswer = await secondTask.value

    #expect(
      secondAnswer
        == SFTPCredentialAnswer(secret: "target-password", saveToKeychain: false))
    #expect(coordinator.current == nil)
  }

  @Test("資格情報入力のキャンセルはnilを返す")
  func cancelReturnsNil() async throws {
    let coordinator = SFTPCredentialPromptCoordinator(presentsUI: true)
    let request = SFTPCredentialRequest(
      hop: SFTPHopIdentity(host: "gateway", port: 2222, username: "ops"),
      kind: .password,
      attempt: 1,
      label: "踏み台")
    let task = Task {
      await coordinator.requestCredential(request)
    }
    await waitUntil("資格情報要求が表示されなかった") {
      coordinator.current?.request == request
    }

    coordinator.cancel()

    #expect(await task.value == nil)
    #expect(coordinator.current == nil)
  }
}
