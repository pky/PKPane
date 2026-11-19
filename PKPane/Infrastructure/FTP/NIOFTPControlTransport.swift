import Foundation
import NIO
import NIOTLS
import Synchronization

enum FTPTransportError: LocalizedError, Equatable {
  case connectionClosed
  case concurrentRead
  case timedOut
  case invalidTextEncoding
  case lineTooLong
  case tlsHostnameValidationFailed
  case tlsCertificateValidationFailed
  case tlsHandshakeFailed
  case plaintextAfterTLSUpgrade

  var errorDescription: String? {
    switch self {
    case .connectionClosed:
      "FTPサーバーとの接続が閉じられました。"
    case .concurrentRead:
      "FTP接続で複数の読み取りが同時に要求されました。"
    case .timedOut:
      "FTPサーバーからの応答がタイムアウトしました。"
    case .invalidTextEncoding:
      "FTPサーバーの応答文字列を解釈できません。"
    case .lineTooLong:
      "FTPサーバーの応答行が許容サイズを超えました。"
    case .tlsHostnameValidationFailed:
      "FTPS証明書のホスト名が接続先と一致しません。"
    case .tlsCertificateValidationFailed:
      "FTPS証明書の有効期限または信頼チェーンを検証できませんでした。"
    case .tlsHandshakeFailed:
      "FTPSのTLS接続を確立できませんでした。"
    case .plaintextAfterTLSUpgrade:
      "TLS切替前に不正な平文データを受信したため接続を中止しました"
    }
  }
}

enum FTPTLSErrorMapper {
  static func map(_ error: Error) -> Error {
    if error is FTPTransportError { return error }
    return error
  }
}

private struct FTPNIOInboundElement: Sendable {
  let buffer: ByteBuffer
  let generation: Int
}

private final class FTPNIOInboundGeneration: @unchecked Sendable {
  private let value = Mutex(0)

  func current() -> Int {
    value.withLock { $0 }
  }

  func sealPlaintext() -> Int {
    value.withLock {
      $0 += 1
      return $0
    }
  }
}

/// NIOのAsyncIteratorはSwift 6のactor分離へ直接保持できないための単一読取ラッパーです。
/// 呼び出し側actorが同時読取を拒否し、ここへは常に1件だけ到達させます。
final class FTPNIOIteratorBox: @unchecked Sendable {
  private var iterator: AsyncThrowingStream<FTPNIOInboundElement, Error>.Iterator

  fileprivate init(_ iterator: AsyncThrowingStream<FTPNIOInboundElement, Error>.Iterator) {
    self.iterator = iterator
  }

  fileprivate func next() async throws -> FTPNIOInboundElement? {
    try await iterator.next()
  }
}

/// テスト注入用の未タグ付きストリームは、全要素をTLS切替前の平文として扱います。
private final class FTPNIOPlaintextIteratorBox: @unchecked Sendable {
  private var iterator: AsyncThrowingStream<ByteBuffer, Error>.Iterator

  init(_ iterator: AsyncThrowingStream<ByteBuffer, Error>.Iterator) {
    self.iterator = iterator
  }

  func next() async throws -> FTPNIOInboundElement? {
    guard let buffer = try await iterator.next() else { return nil }
    return FTPNIOInboundElement(buffer: buffer, generation: 0)
  }
}

final class FTPNIOInboundHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer

  private let continuation: AsyncThrowingStream<FTPNIOInboundElement, Error>.Continuation
  private let generation: FTPNIOInboundGeneration

  fileprivate init(
    continuation: AsyncThrowingStream<FTPNIOInboundElement, Error>.Continuation,
    generation: FTPNIOInboundGeneration
  ) {
    self.continuation = continuation
    self.generation = generation
  }

  func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
    continuation.yield(
      FTPNIOInboundElement(
        buffer: unwrapInboundIn(data),
        generation: generation.current()))
  }

  func channelInactive(context: ChannelHandlerContext) {
    continuation.finish()
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    continuation.finish(throwing: FTPTLSErrorMapper.map(error))
    context.close(promise: nil)
  }
}

private final class FTPTLSHandshakeObserver: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer

  private let promise: EventLoopPromise<Void>
  private var completed = false

  init(promise: EventLoopPromise<Void>) {
    self.promise = promise
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if case TLSUserEvent.handshakeCompleted = event, !completed {
      completed = true
      promise.succeed(())
    }
    context.fireUserInboundEventTriggered(event)
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    if !completed {
      completed = true
      promise.fail(error)
    }
    context.fireErrorCaught(error)
  }

  func channelInactive(context: ChannelHandlerContext) {
    if !completed {
      completed = true
      promise.fail(FTPTransportError.connectionClosed)
    }
    context.fireChannelInactive()
  }
}

/// EventLoopFutureはSwift Taskのキャンセルを監視しないため、TaskGroupで期限と競争させると
/// 期限切れ後も未完了の子タスクを待ち続ける。継続を一度だけ解決し、イベントループが停止した
/// テスト環境や通信断でも呼び出し元を確実に復帰させる。
private final class FTPFutureContinuationGate: @unchecked Sendable {
  private enum State {
    case pending
    case waiting(CheckedContinuation<Void, any Error>)
    case resolved(Result<Void, any Error>)
    case completed
  }

  private let state = Mutex<State>(.pending)

  func install(_ continuation: CheckedContinuation<Void, any Error>) {
    let result = state.withLock { state -> Result<Void, any Error>? in
      switch state {
      case .pending:
        state = .waiting(continuation)
        return nil
      case .resolved(let result):
        state = .completed
        return result
      case .waiting, .completed:
        return nil
      }
    }
    if let result {
      continuation.resume(with: result)
    }
  }

  func resolve(_ result: Result<Void, any Error>) {
    let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
      switch state {
      case .pending:
        state = .resolved(result)
        return nil
      case .waiting(let continuation):
        state = .completed
        return continuation
      case .resolved, .completed:
        return nil
      }
    }
    continuation?.resume(with: result)
  }
}

struct NIOFTPControlTransportConnector: FTPControlTransportConnecting {
  func connect(host: String, port: Int, timeout: Duration) async throws
    -> any FTPControlTransport
  {
    let stream = AsyncThrowingStream<FTPNIOInboundElement, Error>.makeStream()
    let inboundGeneration = FTPNIOInboundGeneration()
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .connectTimeout(Self.timeAmount(timeout))
      .channelInitializer { channel in
        channel.pipeline.addHandler(
          FTPNIOInboundHandler(
            continuation: stream.continuation,
            generation: inboundGeneration))
      }
      .connect(host: host, port: port)
      .get()
    return NIOFTPControlTransport(
      channel: channel,
      stream: stream.stream,
      inboundGeneration: inboundGeneration)
  }

  private static func timeAmount(_ duration: Duration) -> TimeAmount {
    let components = duration.components
    let seconds = max(0, components.seconds)
    let attoseconds = max(0, components.attoseconds)
    let nanoseconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    guard !nanoseconds.overflow else { return .nanoseconds(Int64.max) }
    let fractionalNanoseconds = attoseconds / 1_000_000_000
    return .nanoseconds(nanoseconds.partialValue + fractionalNanoseconds)
  }
}

actor NIOFTPControlTransport: FTPControlTransport {
  private static let maximumLineBytes = 64 * 1_024

  private let channel: Channel
  private let iteratorBox: FTPNIOIteratorBox?
  private let plaintextIteratorBox: FTPNIOPlaintextIteratorBox?
  private let inboundGeneration: FTPNIOInboundGeneration
  private var bufferedBytes: [UInt8] = []
  private var isReading = false
  private var readGeneration = 0
  private var timedOutGeneration: Int?
  private var negotiatedTLSSessionIdentifier: Data?

  init(channel: Channel, stream: AsyncThrowingStream<ByteBuffer, Error>) {
    self.channel = channel
    iteratorBox = nil
    plaintextIteratorBox = FTPNIOPlaintextIteratorBox(stream.makeAsyncIterator())
    inboundGeneration = FTPNIOInboundGeneration()
  }

  fileprivate init(
    channel: Channel,
    stream: AsyncThrowingStream<FTPNIOInboundElement, Error>,
    inboundGeneration: FTPNIOInboundGeneration
  ) {
    self.channel = channel
    iteratorBox = FTPNIOIteratorBox(stream.makeAsyncIterator())
    plaintextIteratorBox = nil
    self.inboundGeneration = inboundGeneration
  }

  func writeLine(_ line: String) async throws {
    try await channel.writeAndFlush(ByteBuffer(string: line + "\r\n")).get()
  }

  func readLine(timeout: Duration) async throws -> String {
    if let line = try takeBufferedLine() { return line }
    guard !isReading else { throw FTPTransportError.concurrentRead }
    isReading = true
    defer { isReading = false }

    readGeneration += 1
    let generation = readGeneration
    let timeoutTask = Task { [weak self] in
      do {
        try await Task.sleep(for: timeout)
        await self?.expireRead(generation: generation)
      } catch {
        // 正常な読み取り完了時のキャンセルです。
      }
    }
    defer { timeoutTask.cancel() }

    do {
      while true {
        try Task.checkCancellation()
        let nextElement = try await withTaskCancellationHandler {
          if let plaintextIteratorBox {
            return try await plaintextIteratorBox.next()
          }
          return try await iteratorBox?.next()
        } onCancel: {
          self.channel.close(promise: nil)
        }
        guard let nextElement else { throw FTPTransportError.connectionClosed }
        guard nextElement.generation >= inboundGeneration.current() else {
          channel.close(promise: nil)
          throw FTPTransportError.plaintextAfterTLSUpgrade
        }
        var nextBuffer = nextElement.buffer
        bufferedBytes.append(
          contentsOf: nextBuffer.readBytes(length: nextBuffer.readableBytes) ?? [])
        guard bufferedBytes.count <= Self.maximumLineBytes else {
          throw FTPTransportError.lineTooLong
        }
        if let line = try takeBufferedLine() { return line }
      }
    } catch {
      if timedOutGeneration == generation {
        throw FTPTransportError.timedOut
      }
      throw error
    }
  }

  func upgradeToTLS(serverHostname: String, timeout: Duration) async throws {
    guard bufferedBytes.isEmpty else {
      channel.close(promise: nil)
      throw FTPTransportError.plaintextAfterTLSUpgrade
    }

    do {
      let sessionIdentifier = Data(UUID().uuidString.utf8)
      let handshakePromise = channel.eventLoop.makePromise(of: Void.self)
      let observer = FTPTLSHandshakeObserver(promise: handshakePromise)
      let tlsChannel = channel
      let inboundGeneration = inboundGeneration
      let upgradeFuture = channel.pipeline.addHandler(observer, position: .first)
        .flatMapThrowing {
          let tlsHandler = try FTPSecureTransportHandler(
            serverHostname: serverHostname,
            sessionIdentifier: sessionIdentifier)
          try tlsChannel.pipeline.syncOperations.addHandler(tlsHandler, position: .first)
          _ = inboundGeneration.sealPlaintext()
        }
        .flatMap { handshakePromise.futureResult }
      try await waitForTLSHandshake(upgradeFuture, timeout: timeout)
      negotiatedTLSSessionIdentifier = sessionIdentifier
    } catch {
      // 昇格を開始した接続は再利用しない。別バッファに残る昇格前の平文も以後拒否する。
      _ = inboundGeneration.sealPlaintext()
      channel.close(promise: nil)
      throw FTPTLSErrorMapper.map(error)
    }
  }

  func tlsSessionIdentifier() -> Data? {
    negotiatedTLSSessionIdentifier
  }

  func close() async {
    channel.close(promise: nil)
  }

  private func expireRead(generation: Int) {
    guard readGeneration == generation else { return }
    timedOutGeneration = generation
    channel.close(promise: nil)
  }

  private func waitForTLSHandshake(
    _ future: EventLoopFuture<Void>,
    timeout: Duration
  ) async throws {
    let gate = FTPFutureContinuationGate()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        gate.install(continuation)
        future.whenComplete { result in
          gate.resolve(result)
        }
        Task {
          do {
            try await Task.sleep(for: timeout)
            gate.resolve(.failure(FTPTransportError.timedOut))
          } catch {
            // 呼び出し元の完了後に期限タスクが取り消された場合は処理不要です。
          }
        }
      }
    } onCancel: {
      gate.resolve(.failure(CancellationError()))
    }
  }

  private func takeBufferedLine() throws -> String? {
    guard let newlineIndex = bufferedBytes.firstIndex(of: 0x0A) else { return nil }
    var lineBytes = Array(bufferedBytes[..<newlineIndex])
    bufferedBytes.removeFirst(newlineIndex + 1)
    if lineBytes.last == 0x0D {
      lineBytes.removeLast()
    }
    guard let line = String(bytes: lineBytes, encoding: .utf8) else {
      throw FTPTransportError.invalidTextEncoding
    }
    return line
  }
}
