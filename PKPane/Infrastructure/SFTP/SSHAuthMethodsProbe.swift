import Citadel
import NIO
import NIOSSH
import Synchronization

// NIOSSH の方式集合は UInt8 だけを保持する値型。
enum SSHAuthMethodsProbeResult: @unchecked Sendable {
  case methods(NIOSSHAvailableUserAuthenticationMethods)
  case unknown
}

typealias SSHAuthMethodsProber =
  @Sendable (SSHClientSettings, (any SSHHopTransport)?) async -> SSHAuthMethodsProbeResult

/// パスワード入力の直前に、SSH の none 要求でサーバーの提示方式を一度だけ確認する。
final class SSHAuthMethodsProbe: NIOSSHClientUserAuthenticationDelegate, Sendable {
  private struct State {
    var sentNone = false
    var channel: (any Channel)?
    var continuation: CheckedContinuation<SSHAuthMethodsProbeResult, Never>?
    var result: SSHAuthMethodsProbeResult?
  }

  private let username: String
  private let state = Mutex(State())

  init(username: String) {
    self.username = username
  }

  func run(
    settings: SSHClientSettings,
    previous: (any SSHHopTransport)?
  ) async -> SSHAuthMethodsProbeResult {
    let deadline = ContinuousClock.now + .seconds(10)
    return await withTaskCancellationHandler {
      guard !Task.isCancelled else { return .unknown }
      let timeout = Task {
        do {
          try await Task.sleep(until: deadline)
          finish(.unknown)
        } catch {
          // 確認が先に終わった。
        }
      }
      // NIO の接続待ちが残っていても、期限やキャンセルで先に呼び出し元へ返す。
      let connection = Task { await openChannel(settings: settings, previous: previous) }
      defer {
        timeout.cancel()
        connection.cancel()
      }
      return await withCheckedContinuation { continuation in
        let result = state.withLock { state in
          if state.result == nil { state.continuation = continuation }
          return state.result
        }
        if let result { continuation.resume(returning: result) }
      }
    } onCancel: {
      finish(.unknown)
    }
  }

  private func openChannel(
    settings: SSHClientSettings,
    previous: (any SSHHopTransport)?
  ) async {
    let initialize: @Sendable (any Channel) -> EventLoopFuture<Void> = { channel in
      self.installHandlers(on: channel, settings: settings)
    }
    do {
      try Task.checkCancellation()
      if let previous {
        _ = try await previous.openAuthProbeChannel(to: settings, initialize: initialize)
      } else {
        _ = try await ClientBootstrap(group: settings.group)
          .connectTimeout(.seconds(10))
          .channelInitializer(initialize)
          .connect(host: settings.host, port: settings.port).get()
      }
    } catch {
      finish(.unknown)
    }
  }

  private func installHandlers(
    on channel: any Channel,
    settings: SSHClientSettings
  ) -> EventLoopFuture<Void> {
    let attached = state.withLock { state in
      guard state.result == nil else { return false }
      state.channel = channel
      return true
    }
    guard attached else {
      return channel.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
    }

    var configuration = SSHClientConfiguration(
      userAuthDelegate: self, serverAuthDelegate: settings.hostKeyValidator)
    // Citadel の設定と同じ暗号を、公開されている NIOSSH の設定へ反映する。
    let schemes: [any NIOSSHTransportProtection.Type]
    switch settings.algorithms.transportProtectionSchemes {
    case .add(let additionalSchemes):
      schemes = additionalSchemes
      configuration.transportProtectionSchemes.append(contentsOf: schemes)
    case .replace(let replacementSchemes):
      schemes = replacementSchemes
      configuration.transportProtectionSchemes = schemes
    case nil:
      schemes = []
    }
    for scheme in schemes {
      NIOSSHAlgorithms.register(transportProtectionScheme: scheme)
    }
    do {
      try channel.pipeline.syncOperations.addHandlers(
        NIOSSHHandler(
          role: .client(configuration), allocator: channel.allocator,
          inboundChildChannelInitializer: nil),
        ProbeEventsHandler(probe: self))
      return channel.eventLoop.makeSucceededVoidFuture()
    } catch {
      return channel.eventLoop.makeFailedFuture(error)
    }
  }

  func nextAuthenticationType(
    availableMethods: NIOSSHAvailableUserAuthenticationMethods,
    nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
  ) {
    // NIOSSH がイベントループ上で呼び出すため、認証オファーをループ内で返せる。
    let challenge = nextChallengePromise.assumeIsolated()
    let sendNone = state.withLock { state in
      guard !state.sentNone, state.result == nil else { return false }
      state.sentNone = true
      return true
    }
    if sendNone {
      challenge.succeed(.init(username: username, serviceName: "", offer: .none))
    } else {
      // 打ち切りで発生する接続エラーより先に、取得した方式を確定する。
      finish(.methods(availableMethods))
      challenge.succeed(nil)
    }
  }

  fileprivate func finish(_ result: SSHAuthMethodsProbeResult) {
    let pending: ((any Channel)?, CheckedContinuation<SSHAuthMethodsProbeResult, Never>?)? =
      state.withLock { state in
        guard state.result == nil else { return nil }
        state.result = result
        let pending = (state.channel, state.continuation)
        state.channel = nil
        state.continuation = nil
        return pending
      }
    guard let (channel, continuation) = pending else { return }
    if let channel {
      // 認証デリゲートの呼び出し中にパイプラインへ再入しないよう次の処理に回す。
      channel.eventLoop.execute { channel.close(promise: nil) }
    }
    continuation?.resume(returning: result)
  }
}

private final class ProbeEventsHandler: ChannelInboundHandler {
  typealias InboundIn = Never
  private let probe: SSHAuthMethodsProbe

  init(probe: SSHAuthMethodsProbe) {
    self.probe = probe
  }

  func channelInactive(context: ChannelHandlerContext) {
    probe.finish(.unknown)
    context.fireChannelInactive()
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if event is UserAuthSuccessEvent { probe.finish(.unknown) }
    context.fireUserInboundEventTriggered(event)
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    probe.finish(.unknown)
  }
}
