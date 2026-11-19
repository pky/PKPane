import CryptoKit
import Foundation
import NIO
import Synchronization
import Testing

@testable import PKPane

struct FTPDataBackpressureTests {
  @Test("EOFの同期排出がメモリ上限を超えても全内容を順序どおり届ける")
  func preservesSynchronousEOFDrainBeyondMemoryLimit() async throws {
    let buffer = FTPDataInboundBuffer()
    var expected = SHA256()
    let chunkBytes = FTPDataInboundBuffer.maximumReadBytes
    let chunkCount = 128
    // readEOF0は消費側の再開を待たず、channelReadを同期で繰り返す。
    for index in 0..<chunkCount {
      let data = Data(repeating: UInt8(index % 251), count: chunkBytes)
      expected.update(data: data)
      try #require(try buffer.append(ByteBuffer(bytes: data)))
    }
    #expect(buffer.maximumSpoolBytes > 0)
    #expect(buffer.hasOpenSpool)
    #expect(!buffer.canRead)
    var actual = SHA256()
    var receivedBytes = 0
    // メモリを空にしても旧データがdiskに残っている間は、新着分を末尾へ保つ。
    while buffer.pendingBytes > 0 {
      let chunk = try #require(try await buffer.next())
      let data = Data(chunk.readableBytesView)
      actual.update(data: data)
      receivedBytes += data.count
    }
    #expect(buffer.hasOpenSpool)
    let tail = Data([0x13, 0x37, 0x42])
    expected.update(data: tail)
    try #require(try buffer.append(ByteBuffer(bytes: tail)))
    #expect(buffer.pendingBytes == 0)
    buffer.finish()
    while let chunk = try await buffer.next() {
      let data = Data(chunk.readableBytesView)
      actual.update(data: data)
      receivedBytes += data.count
    }
    #expect(receivedBytes == chunkBytes * chunkCount + tail.count)
    #expect(Data(actual.finalize()) == Data(expected.finalize()))
    #expect(buffer.maximumPendingBytes <= FTPDataInboundBuffer.maximumBufferedBytes)
    #expect(buffer.pendingBytes == 0)
    #expect(!buffer.hasOpenSpool)
  }

  @Test("EOF退避中の取消と異常終了は匿名一時ファイルを即時解放する")
  func releasesSpoolOnAbnormalTerminalPaths() async throws {
    let errors: [any Error] = [CancellationError(), FTPTransportError.connectionClosed]
    for error in errors {
      let buffer = FTPDataInboundBuffer()
      let chunk = ByteBuffer(repeating: 0x41, count: FTPDataInboundBuffer.maximumReadBytes)
      let count = FTPDataInboundBuffer.maximumBufferedBytes / chunk.readableBytes + 1
      for _ in 0..<count { try #require(try buffer.append(chunk)) }
      #expect(buffer.hasOpenSpool)
      // 正常EOFが先行していても、その後の取消・異常は退避内容を破棄する。
      buffer.finish()
      buffer.finish(throwing: error)
      #expect(!buffer.hasOpenSpool)
      #expect(buffer.pendingBytes == 0)
      await #expect(throws: (any Error).self) { try await buffer.next() }
    }
  }

  @Test("本番FTP受信ハンドラは遅い消費でも保留バイトを有限に保ち全内容を届ける")
  func boundsReceivingBytesWithoutDroppingData() async throws {
    let chunkCount = 256
    let expectedBytes =
      FTPBackpressureFixture.chunkBytes * chunkCount + FTPBackpressureFixture.tail.count
    let server = try await FTPBackpressureFixture.listen(chunkCount: chunkCount)
    defer { server.close(promise: nil) }
    let port = try #require(server.localAddress?.port)
    let transport = try await connect(port: port)
    let nioTransport = try #require(transport as? NIOFTPDataTransport)
    let buffer = await nioTransport.buffer
    let socketReceiveBytes = await nioTransport.socketReceiveBufferBytes
    #expect(socketReceiveBytes > 0)
    #expect(socketReceiveBytes <= FTPDataInboundBuffer.socketReceiveBufferBytes)
    defer {
      print(
        "RV26-05 SO_RCVBUF実値=\(socketReceiveBytes)、socketチャンク最大=\(buffer.maximumChunkBytes)、"
          + "保留最大=\(buffer.maximumPendingBytes)、退避最大=\(buffer.maximumSpoolBytes)、"
          + "拒否時=\(String(describing: buffer.rejectedBytes))")
    }

    // 高水位に達したことを確認してから消費し、停止と再開の経路を通す。
    await waitUntil("FTP受信が高水位に達しなかった") {
      buffer.pendingBytes >= FTPDataInboundBuffer.highWatermarkBytes
    }
    #expect(buffer.maximumPendingBytes >= FTPDataInboundBuffer.highWatermarkBytes)
    let received = Mutex((digest: SHA256(), bytes: 0))
    do {
      try await transport.readChunks(timeout: .seconds(5)) { data in
        received.withLock {
          $0.digest.update(data: data)
          $0.bytes += data.count
        }
        try await Task.sleep(for: .milliseconds(1))
      }
    } catch {
      await transport.close()
      let message =
        "FTP受信の拒否診断: 最大chunk=\(buffer.maximumChunkBytes)、"
        + "最大pending=\(buffer.maximumPendingBytes)、"
        + "拒否pending/incoming=\(String(describing: buffer.rejectedBytes))"
      Issue.record(Comment(rawValue: message))
      throw error
    }
    await transport.close()
    var digest = received.withLock { $0.digest }
    let receivedBytes = received.withLock { $0.bytes }
    #expect(receivedBytes == expectedBytes)
    #expect(
      Data(digest.finalize()) == FTPBackpressureFixture.expectedDigest(chunkCount: chunkCount))
    let maximum = buffer.maximumPendingBytes
    print("RV26-05 FTP受信保留最大=\(maximum)バイト、全量=\(receivedBytes)バイト")
    #expect(maximum <= 4 * 1_024 * 1_024 + 2 * 64 * 1_024)
    try writeRV26Measurement(
      name: "rv26-05-receive",
      values: [
        "totalBytes": receivedBytes,
        "maximumPendingBytes": maximum,
        "maximumReadBytes": buffer.maximumChunkBytes,
        "requestedSocketReceiveBytes": FTPDataInboundBuffer.requestedSocketReceiveBufferBytes,
        "actualSocketReceiveBytes": socketReceiveBytes,
        "absolutePendingLimitBytes": FTPDataInboundBuffer.maximumBufferedBytes,
        "maximumSpoolBytes": buffer.maximumSpoolBytes,
      ])
  }

  @Test("受信高水位で閉じると保留バッファとsocket送信タスクを解放する")
  func closesWhileProducerIsBackpressured() async throws {
    let finished = FTPProducerCompletion()
    let server = try await FTPBackpressureFixture.listen(finished: finished)
    defer { server.close(promise: nil) }
    let port = try #require(server.localAddress?.port)
    let transport = try await connect(port: port)
    let nioTransport = try #require(transport as? NIOFTPDataTransport)
    let buffer = await nioTransport.buffer
    await waitUntil { buffer.pendingBytes >= FTPDataInboundBuffer.highWatermarkBytes }
    await transport.close()
    await waitUntil { finished.isFinished }
    #expect(buffer.pendingBytes == 0)
    await #expect(throws: CancellationError.self) { try await buffer.next() }
  }

  @Test("EOFは保留内容を排出し、エラーと取消は待機中の消費を解放する")
  func releasesConsumerOnAllTerminalPaths() async throws {
    let eof = FTPDataInboundBuffer()
    #expect(try eof.append(ByteBuffer(bytes: [0x41])))
    eof.finish()
    #expect(try await eof.next()?.readableBytes == 1)
    #expect(try await eof.next() == nil)

    let failed = FTPDataInboundBuffer()
    let failureTask = Task { try await failed.next() }
    failed.finish(throwing: FTPTransportError.connectionClosed)
    await #expect(throws: FTPTransportError.connectionClosed) { try await failureTask.value }

    let cancelled = FTPDataInboundBuffer()
    let cancelTask = Task { try await cancelled.next() }
    cancelTask.cancel()
    await #expect(throws: CancellationError.self) { try await cancelTask.value }
  }

  private func connect(port: Int) async throws -> any FTPDataTransport {
    do {
      return try await NIOFTPDataTransportConnector().connect(
        to: FTPPassiveEndpoint(host: "127.0.0.1", port: port), timeout: .seconds(5))
    } catch let error as FTPReceiveBufferConfigurationError {
      let message =
        "SO_RCVBUF診断: 要求=\(error.requestedBytes)、実値=\(error.actualBytes)"
      Issue.record(Comment(rawValue: message))
      throw error
    }
  }
}

private final class FTPProducerCompletion: Sendable {
  private let state = Mutex(false)
  var isFinished: Bool { state.withLock { $0 } }
  func finish() { state.withLock { $0 = true } }
}

private enum FTPBackpressureFixture {
  static let chunkBytes = 64 * 1_024
  static let chunkCount = 1_024
  static let tail = Data([0x13, 0x37, 0x42])

  static func expectedDigest(chunkCount: Int) -> Data {
    var digest = SHA256()
    for index in 0..<chunkCount {
      digest.update(data: Data(repeating: UInt8(index % 251), count: chunkBytes))
    }
    digest.update(data: tail)
    return Data(digest.finalize())
  }

  static func listen(
    finished: FTPProducerCompletion = FTPProducerCompletion(),
    chunkCount: Int = FTPBackpressureFixture.chunkCount
  ) async throws -> Channel {
    try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .childChannelInitializer { channel in
        channel.pipeline.addHandler(
          FTPBackpressureSender(finished: finished, chunkCount: chunkCount))
      }
      .bind(host: "127.0.0.1", port: 0).get()
  }
}

private final class FTPBackpressureSender: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  private let finished: FTPProducerCompletion
  private let chunkCount: Int

  init(finished: FTPProducerCompletion, chunkCount: Int) {
    self.finished = finished
    self.chunkCount = chunkCount
  }

  func channelActive(context: ChannelHandlerContext) {
    let channel = context.channel
    Task { [self] in
      defer { finished.finish() }
      do {
        for index in 0..<chunkCount {
          let bytes = ByteBuffer(
            bytes: Data(repeating: UInt8(index % 251), count: FTPBackpressureFixture.chunkBytes))
          try await channel.writeAndFlush(bytes).get()
        }
        try await channel.writeAndFlush(ByteBuffer(bytes: FTPBackpressureFixture.tail)).get()
      } catch {
        // 受信側の取消や切断では送信も終了する。
      }
      channel.close(promise: nil)
    }
    context.fireChannelActive()
  }
}
