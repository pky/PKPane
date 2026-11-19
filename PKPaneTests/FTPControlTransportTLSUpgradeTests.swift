import NIOCore
import NIOEmbedded
import Testing

@testable import PKPane

struct FTPControlTransportTLSUpgradeTests {
  @Test("TLS昇格時に受信済みの後続平文を拒否する")
  func rejectsBufferedPlaintextDuringTLSUpgrade() async throws {
    let fixture = makeFixture(response: "234 AUTH TLS OK\r\n250 injected\r\n")
    defer { fixture.finish() }

    let reply = try await fixture.transport.readLine(timeout: .seconds(1))
    #expect(reply == "234 AUTH TLS OK")

    await #expect(throws: FTPTransportError.plaintextAfterTLSUpgrade) {
      try await fixture.transport.upgradeToTLS(
        serverHostname: "example.com", timeout: .seconds(1))
    }
  }

  @Test("後続平文がないTLS昇格は平文残留エラーにしない")
  func doesNotReportBufferedPlaintextWhenBufferIsEmpty() async throws {
    let fixture = makeFixture(response: "234 AUTH TLS OK\r\n")
    defer { fixture.finish() }

    let reply = try await fixture.transport.readLine(timeout: .seconds(1))
    #expect(reply == "234 AUTH TLS OK")

    let upgrade = Task {
      try await fixture.transport.upgradeToTLS(
        serverHostname: "example.com", timeout: .seconds(1))
    }
    defer { upgrade.cancel() }
    await cancelAfterInstallingTLSHandler(upgrade, fixture: fixture)
    await #expect(throws: CancellationError.self) {
      try await upgrade.value
    }
  }

  @Test("TLS昇格前に別バッファへキューされた平文を拒否する")
  func rejectsPlaintextQueuedInSeparateBufferBeforeTLSUpgrade() async throws {
    let input = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
    input.continuation.yield(ByteBuffer(string: "234 AUTH TLS OK\r\n"))
    input.continuation.yield(ByteBuffer(string: "250 injected\r\n"))
    let channel = EmbeddedChannel()
    let fixture = FTPControlTransportTLSUpgradeFixture(
      transport: NIOFTPControlTransport(channel: channel, stream: input.stream),
      channel: channel,
      continuation: input.continuation)
    defer { fixture.finish() }

    let reply = try await fixture.transport.readLine(timeout: .seconds(1))
    #expect(reply == "234 AUTH TLS OK")

    // TLSハンドラの設置まで進め、成立しないハンドシェイクは期限切れを待たず取り消す。
    let upgrade = Task {
      try await fixture.transport.upgradeToTLS(
        serverHostname: "example.com", timeout: .seconds(1))
    }
    defer { upgrade.cancel() }
    await cancelAfterInstallingTLSHandler(upgrade, fixture: fixture)
    await #expect(throws: CancellationError.self) {
      try await upgrade.value
    }

    await #expect(throws: FTPTransportError.plaintextAfterTLSUpgrade) {
      try await fixture.transport.readLine(timeout: .seconds(1))
    }
  }

  private func cancelAfterInstallingTLSHandler(
    _ upgrade: Task<Void, any Error>, fixture: FTPControlTransportTLSUpgradeFixture
  ) async {
    await waitUntil(timeout: .seconds(1), "TLSハンドラが設置されなかった") {
      fixture.channel.embeddedEventLoop.run()
      return
        (try? fixture.channel.pipeline.syncOperations.context(
          handlerType: FTPSecureTransportHandler.self)) != nil
    }
    upgrade.cancel()
  }

  private func makeFixture(response: String) -> FTPControlTransportTLSUpgradeFixture {
    let input = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
    input.continuation.yield(ByteBuffer(string: response))
    let channel = EmbeddedChannel()
    return FTPControlTransportTLSUpgradeFixture(
      transport: NIOFTPControlTransport(channel: channel, stream: input.stream),
      channel: channel,
      continuation: input.continuation)
  }
}

private struct FTPControlTransportTLSUpgradeFixture {
  let transport: NIOFTPControlTransport
  let channel: EmbeddedChannel
  let continuation: AsyncThrowingStream<ByteBuffer, Error>.Continuation

  func finish() {
    continuation.finish()
    _ = try? channel.finish(acceptAlreadyClosed: true)
  }
}
