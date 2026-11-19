import Darwin
import Foundation
import NIO
import Synchronization

struct FTPReceiveBufferConfigurationError: LocalizedError {
  let requestedBytes: Int
  let actualBytes: Int
  var errorDescription: String? { "FTP接続の受信容量を安全に設定できません。" }
}

protocol FTPDataTransport: Sendable {
  func readAll(timeout: Duration, maximumBytes: Int) async throws -> Data
  func readChunks(
    timeout: Duration,
    receive: @escaping @Sendable (Data) async throws -> Void
  ) async throws
  func writeChunks(
    _ chunks: AsyncThrowingStream<Data, Error>,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws
  func close() async
}

extension FTPDataTransport {
  func readChunks(
    timeout: Duration,
    receive: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    try await receive(readAll(timeout: timeout, maximumBytes: 256 * 1_024 * 1_024))
  }

  func writeChunks(
    _: AsyncThrowingStream<Data, Error>,
    progress _: @escaping @Sendable (Int64) -> Void
  ) async throws {
    throw FTPTransportError.connectionClosed
  }
}

protocol FTPDataTransportConnecting: Sendable {
  func connect(to endpoint: FTPPassiveEndpoint, timeout: Duration) async throws
    -> any FTPDataTransport
  func connect(
    to endpoint: FTPPassiveEndpoint,
    timeout: Duration,
    tlsServerHostname: String?,
    tlsSessionIdentifier: Data?
  ) async throws -> any FTPDataTransport
}

extension FTPDataTransportConnecting {
  func connect(
    to endpoint: FTPPassiveEndpoint,
    timeout: Duration,
    tlsServerHostname _: String?,
    tlsSessionIdentifier _: Data?
  ) async throws -> any FTPDataTransport {
    try await connect(to: endpoint, timeout: timeout)
  }
}

struct NIOFTPDataTransportConnector: FTPDataTransportConnecting {
  func connect(to endpoint: FTPPassiveEndpoint, timeout: Duration) async throws
    -> any FTPDataTransport
  {
    try await connect(
      to: endpoint,
      timeout: timeout,
      tlsServerHostname: nil,
      tlsSessionIdentifier: nil)
  }

  func connect(
    to endpoint: FTPPassiveEndpoint,
    timeout: Duration,
    tlsServerHostname: String?,
    tlsSessionIdentifier: Data?
  ) async throws -> any FTPDataTransport {
    let buffer = FTPDataInboundBuffer()
    if tlsServerHostname != nil, tlsSessionIdentifier == nil {
      throw FTPTransportError.tlsHandshakeFailed
    }
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .connectTimeout(Self.timeAmount(timeout))
      .channelOption(ChannelOptions.autoRead, value: false)
      .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
      .channelOption(
        ChannelOptions.socketOption(.so_rcvbuf),
        value: CInt(FTPDataInboundBuffer.requestedSocketReceiveBufferBytes)
      )
      .channelOption(
        ChannelOptions.recvAllocator,
        value: FixedSizeRecvByteBufferAllocator(
          capacity: FTPDataInboundBuffer.maximumReadBytes)
      )
      .channelInitializer { channel in
        let inbound = FTPDataInboundHandler(buffer: buffer)
        guard let tlsServerHostname, let tlsSessionIdentifier else {
          return channel.pipeline.addHandler(inbound)
        }
        do {
          let tlsHandler = try FTPSecureTransportHandler(
            serverHostname: tlsServerHostname,
            sessionIdentifier: tlsSessionIdentifier)
          try channel.pipeline.syncOperations.addHandler(tlsHandler)
          try channel.pipeline.syncOperations.addHandler(inbound)
          return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
          return channel.eventLoop.makeFailedFuture(error)
        }
      }
      .connect(host: endpoint.host, port: endpoint.port)
      .get()
    let receiveOption = ChannelOptions.socketOption(.so_rcvbuf)
    let socketReceiveBytes: Int
    do {
      socketReceiveBytes = Int(try await channel.getOption(receiveOption).get())
    } catch {
      buffer.finish(throwing: error)
      channel.close(promise: nil)
      throw error
    }
    guard socketReceiveBytes > 0,
      socketReceiveBytes <= FTPDataInboundBuffer.socketReceiveBufferBytes
    else {
      let error = FTPReceiveBufferConfigurationError(
        requestedBytes: FTPDataInboundBuffer.requestedSocketReceiveBufferBytes,
        actualBytes: socketReceiveBytes)
      buffer.finish(throwing: error)
      channel.close(promise: nil)
      throw error
    }
    return NIOFTPDataTransport(
      channel: channel, buffer: buffer, socketReceiveBufferBytes: Int(socketReceiveBytes))
  }

  private static func timeAmount(_ duration: Duration) -> TimeAmount {
    let components = duration.components
    let seconds = max(0, components.seconds)
    let nanoseconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    guard !nanoseconds.overflow else { return .nanoseconds(Int64.max) }
    return .nanoseconds(
      nanoseconds.partialValue + max(0, components.attoseconds) / 1_000_000_000)
  }
}

actor NIOFTPDataTransport: FTPDataTransport {
  private let channel: Channel
  let buffer: FTPDataInboundBuffer
  let socketReceiveBufferBytes: Int
  private var isReading = false
  private var isWriting = false
  private var readGeneration = 0
  private var timedOutGeneration: Int?
  private var activeReadGeneration: Int?

  init(channel: Channel, buffer: FTPDataInboundBuffer, socketReceiveBufferBytes: Int) {
    self.channel = channel
    self.buffer = buffer
    self.socketReceiveBufferBytes = socketReceiveBufferBytes
  }

  func readAll(timeout: Duration, maximumBytes: Int) async throws -> Data {
    guard !isReading else { throw FTPTransportError.concurrentRead }
    isReading = true
    defer { isReading = false }
    var result = Data()
    while true {
      guard let bytes = try await readChunk(timeout: timeout) else { return result }
      guard result.count <= maximumBytes - bytes.count else {
        throw FTPTransportError.lineTooLong
      }
      result.append(contentsOf: bytes)
    }
  }

  func readChunks(
    timeout: Duration,
    receive: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    guard !isReading else { throw FTPTransportError.concurrentRead }
    isReading = true
    defer { isReading = false }
    while let bytes = try await readChunk(timeout: timeout) {
      try Task.checkCancellation()
      try await receive(Data(bytes))
    }
  }

  func writeChunks(
    _ chunks: AsyncThrowingStream<Data, Error>,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    guard !isWriting else { throw FTPTransportError.concurrentRead }
    isWriting = true
    defer { isWriting = false }
    var transferred: Int64 = 0
    do {
      for try await chunk in chunks {
        try Task.checkCancellation()
        guard !chunk.isEmpty else { continue }
        try await channel.writeAndFlush(ByteBuffer(bytes: chunk)).get()
        transferred += Int64(chunk.count)
        progress(transferred)
      }
      try await channel.close().get()
    } catch {
      channel.close(promise: nil)
      throw error
    }
  }

  func close() async {
    buffer.finish(throwing: CancellationError())
    channel.close(promise: nil)
  }

  private func readChunk(timeout: Duration) async throws -> [UInt8]? {
    readGeneration += 1
    let generation = readGeneration
    activeReadGeneration = generation
    let timeoutTask = Task { [weak self] in
      do {
        try await Task.sleep(for: timeout)
        await self?.expireRead(generation: generation)
      } catch {
        // データ到着またはEOF時の正常なキャンセルです。
      }
    }
    defer {
      activeReadGeneration = nil
      timeoutTask.cancel()
    }

    do {
      let nextBuffer = try await withTaskCancellationHandler {
        try await buffer.next()
      } onCancel: {
        self.buffer.finish(throwing: CancellationError())
        self.channel.close(promise: nil)
      }
      guard var nextBuffer else { return nil }
      return nextBuffer.readBytes(length: nextBuffer.readableBytes) ?? []
    } catch {
      if timedOutGeneration == generation {
        throw FTPTransportError.timedOut
      }
      throw error
    }
  }

  private func expireRead(generation: Int) {
    guard activeReadGeneration == generation else { return }
    timedOutGeneration = generation
    buffer.finish(throwing: FTPTransportError.timedOut)
    channel.close(promise: nil)
  }
}

/// データ接続専用のバイト計数キュー。制御接続の応答ストリームとは共有しない。
/// 通常の高水位は2MiB。一度のsocket読取は64KiB、読取回数は1に固定する。
/// NIOのreadEOF0は手動read停止を迂回して残りを排出するため、SO_RCVBUFも2MiBに
/// 固定する。メモリ上限を超えるEOF同期排出分は匿名一時ファイルへ退避する。
/// SO_RCVBUFは瞬間容量であり、同期排出の累積量を保証するものではない。
/// 消費中のチャンク、コピー、Secure Transport内部の領域はこのキュー計数に含まない。
/// TLS内部の保留と総RSSの上限は未実測であり、この式でRSSまで保証するものではない。
final class FTPDataInboundBuffer: Sendable {
  static let maximumReadBytes = 64 * 1_024
  static let highWatermarkBytes = 2 * 1_024 * 1_024
  static let socketReceiveBufferBytes = 2 * 1_024 * 1_024
  // 接続時のMSS単位切り上げを吸収し、接続後の実値を2MiB以内に検査する。
  static let requestedSocketReceiveBufferBytes = socketReceiveBufferBytes - maximumReadBytes
  static let maximumBufferedBytes =
    highWatermarkBytes + socketReceiveBufferBytes + 2 * maximumReadBytes

  private struct State {
    var chunks: [ByteBuffer?] = []
    var head = 0
    var bytes = 0
    var maximumBytes = 0
    var maximumChunkBytes = 0
    var rejectedBytes: (pending: Int, incoming: Int)?
    var spool: FTPDataReceiveSpool?
    var maximumSpoolBytes = 0
    var end: Result<Void, Error>?
    var waiter: CheckedContinuation<ByteBuffer?, Error>?
    var capacityAvailable: (@Sendable () -> Void)?
  }

  private let state = Mutex(State())

  var pendingBytes: Int { state.withLock { $0.bytes } }
  var maximumPendingBytes: Int { state.withLock { $0.maximumBytes } }
  var maximumChunkBytes: Int { state.withLock { $0.maximumChunkBytes } }
  var rejectedBytes: (pending: Int, incoming: Int)? { state.withLock { $0.rejectedBytes } }
  var maximumSpoolBytes: Int { state.withLock { $0.maximumSpoolBytes } }
  var hasOpenSpool: Bool { state.withLock { $0.spool != nil } }
  var canRead: Bool {
    state.withLock { $0.end == nil && $0.spool == nil && $0.bytes < Self.highWatermarkBytes }
  }

  func onCapacityAvailable(_ callback: @escaping @Sendable () -> Void) {
    state.withLock { if $0.end == nil { $0.capacityAvailable = callback } }
  }

  func append(_ chunk: ByteBuffer) throws -> Bool {
    let result: (Bool, CheckedContinuation<ByteBuffer?, Error>?) = try state.withLock { value in
      guard value.end == nil else { return (true, nil) }
      value.maximumChunkBytes = max(value.maximumChunkBytes, chunk.readableBytes)
      guard chunk.readableBytes <= Self.maximumReadBytes else {
        value.rejectedBytes = (pending: value.bytes, incoming: chunk.readableBytes)
        return (false, nil)
      }
      if let waiter = value.waiter {
        value.waiter = nil
        return (true, waiter)
      }
      if value.spool != nil || value.bytes > Self.maximumBufferedBytes - chunk.readableBytes {
        if value.spool == nil { value.spool = try FTPDataReceiveSpool() }
        if let spool = value.spool {
          try spool.append(chunk)
          value.maximumSpoolBytes = max(value.maximumSpoolBytes, spool.pendingBytes)
        }
        return (true, nil)
      }
      value.chunks.append(chunk)
      value.bytes += chunk.readableBytes
      value.maximumBytes = max(value.maximumBytes, value.bytes)
      return (true, nil)
    }
    result.1?.resume(returning: chunk)
    return result.0
  }

  func next() async throws -> ByteBuffer? {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        let result: (Result<ByteBuffer?, Error>?, (@Sendable () -> Void)?) =
          state.withLock { value in
            if value.head < value.chunks.count, let chunk = value.chunks[value.head] {
              let previousBytes = value.bytes
              value.bytes -= chunk.readableBytes
              // 消費済みByteBufferへの参照も直ちに捨て、計数と実保留量を一致させる。
              value.chunks[value.head] = nil
              value.head += 1
              if value.head == value.chunks.count {
                value.chunks.removeAll(keepingCapacity: true)
                value.head = 0
              } else if value.head >= 64 {
                value.chunks.removeFirst(value.head)
                value.head = 0
              }
              let callback =
                previousBytes >= Self.highWatermarkBytes ? value.capacityAvailable : nil
              return (.success(chunk), callback)
            }
            if let spool = value.spool {
              do {
                let chunk = try spool.next(maximumBytes: Self.maximumReadBytes)
                if spool.pendingBytes == 0 {
                  value.spool = nil
                  return (.success(chunk), value.capacityAvailable)
                }
                return (.success(chunk), nil)
              } catch {
                value.spool = nil
                value.end = .failure(error)
                value.capacityAvailable = nil
                return (.failure(error), nil)
              }
            }
            if let end = value.end {
              return (end.map { nil }, nil)
            }
            guard value.waiter == nil else {
              return (.failure(FTPTransportError.concurrentRead), nil)
            }
            value.waiter = continuation
            return (nil, nil)
          }
        result.1?()
        if let outcome = result.0 { continuation.resume(with: outcome) }
      }
    } onCancel: {
      self.finish(throwing: CancellationError())
    }
  }

  func finish(throwing error: Error? = nil) {
    let waiter: CheckedContinuation<ByteBuffer?, Error>? = state.withLock { value in
      // 正常EOF後でも取消時は、まだ保留しているデータを即解放する。
      if value.end != nil, error == nil { return nil }
      value.end = error.map { .failure($0) } ?? .success(())
      value.capacityAvailable = nil
      if error != nil {
        value.chunks.removeAll()
        value.head = 0
        value.bytes = 0
        value.spool = nil
      }
      let waiter = value.waiter
      value.waiter = nil
      return waiter
    }
    if let error { waiter?.resume(throwing: error) } else { waiter?.resume(returning: nil) }
  }
}

/// EOFの同期排出だけを退避する。呼出しは受信キューのMutex内で直列化する。
/// 同期disk I/Oはイベントループを一時的に占有するが、保留メモリを増やさない。
private final class FTPDataReceiveSpool: @unchecked Sendable {
  private let descriptor: Int32
  private var readOffset: Int64 = 0
  private var writtenBytes: Int64 = 0
  var pendingBytes: Int { Int(writtenBytes - readOffset) }

  init() throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("PKPane-FTP-receive-XXXXXX").path
    var template = Array(path.utf8CString)
    let descriptor = mkstemp(&template)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    // mkstempの0600を保ち、パスを直ちに消してfd解放時に実体も破棄する。
    var unlinkResult: Int32
    repeat { unlinkResult = unlink(template) } while unlinkResult < 0 && errno == EINTR
    guard unlinkResult == 0 else {
      let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      Darwin.close(descriptor)
      throw error
    }
    self.descriptor = descriptor
  }

  deinit { Darwin.close(descriptor) }

  func append(_ chunk: ByteBuffer) throws {
    try chunk.withUnsafeReadableBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
        if count < 0 {
          if errno == EINTR { continue }
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard count > 0 else { throw POSIXError(.EIO) }
        offset += count
        writtenBytes += Int64(count)
      }
    }
  }

  func next(maximumBytes: Int) throws -> ByteBuffer {
    let count = min(maximumBytes, pendingBytes)
    var bytes = [UInt8](repeating: 0, count: count)
    try bytes.withUnsafeMutableBytes { destination in
      guard let baseAddress = destination.baseAddress else { throw POSIXError(.EIO) }
      var offset = 0
      while offset < count {
        let received = Darwin.pread(
          descriptor, baseAddress.advanced(by: offset), count - offset,
          off_t(readOffset + Int64(offset)))
        if received < 0 {
          if errno == EINTR { continue }
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard received > 0 else { throw POSIXError(.EIO) }
        offset += received
      }
    }
    readOffset += Int64(count)
    return ByteBuffer(bytes: bytes)
  }
}

/// 手動readを高水位で止め、消費による空きができたらイベントループ上で再開する。
/// TLSのhandshake中もchannelActive/readCompleteがreadを継続し、復号が始まってから
/// バイト上限が作用する。制御接続のautoReadと応答ハンドラには変更を加えない。
final class FTPDataInboundHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  private let buffer: FTPDataInboundBuffer
  private var readPending = false

  init(buffer: FTPDataInboundBuffer) { self.buffer = buffer }

  func handlerAdded(context: ChannelHandlerContext) {
    let eventLoop = context.eventLoop
    let boundContext = NIOLoopBound(context, eventLoop: eventLoop)
    buffer.onCapacityAvailable { [weak self] in
      eventLoop.execute { [weak self] in self?.requestRead(context: boundContext.value) }
    }
    if context.channel.isActive { requestRead(context: context) }
  }

  func channelActive(context: ChannelHandlerContext) {
    requestRead(context: context)
    context.fireChannelActive()
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    do {
      guard try buffer.append(unwrapInboundIn(data)) else {
        errorCaught(context: context, error: FTPTransportError.lineTooLong)
        return
      }
    } catch {
      errorCaught(context: context, error: error)
    }
  }

  func channelReadComplete(context: ChannelHandlerContext) {
    readPending = false
    requestRead(context: context)
    context.fireChannelReadComplete()
  }

  func channelInactive(context: ChannelHandlerContext) {
    buffer.finish()
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    buffer.finish(throwing: FTPTLSErrorMapper.map(error))
    context.close(promise: nil)
  }

  private func requestRead(context: ChannelHandlerContext) {
    guard !readPending, context.channel.isActive, buffer.canRead else { return }
    readPending = true
    context.read()
  }
}
