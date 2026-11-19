import Foundation
import NIO
import NIOTLS
import Security

/// Secure Transportのセッションキャッシュを使い、FTPSの制御接続とデータ接続で
/// 同一TLSセッションを再開できるようにするNIOハンドラです。
///
/// FTPSサーバーの一部はデータ接続の乗っ取りを防ぐため、制御接続のTLSセッションを
/// データ接続で再開できないクライアントを拒否します。SwiftNIO SSLはクライアント側の
/// セッション再開APIを公開していないため、macOSのSSLSetPeerIDをこの用途に限定して使います。
final class FTPSecureTransportHandler: ChannelDuplexHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  typealias InboundOut = ByteBuffer
  typealias OutboundIn = ByteBuffer
  typealias OutboundOut = ByteBuffer

  private let sslContext: SSLContext
  private let io = FTPSecureTransportIO()
  private var handshakeStarted = false
  private var handshakeCompleted = false
  private var failed = false

  init(serverHostname: String, sessionIdentifier: Data) throws {
    guard let sslContext = SSLCreateContext(nil, .clientSide, .streamType) else {
      throw FTPTransportError.tlsHandshakeFailed
    }
    self.sslContext = sslContext

    try Self.require(SSLSetIOFuncs(sslContext, ftpTLSRead, ftpTLSWrite))
    let connection = Unmanaged.passUnretained(io).toOpaque()
    try Self.require(SSLSetConnection(sslContext, UnsafeRawPointer(connection)))
    try serverHostname.withCString { hostname in
      try Self.require(SSLSetPeerDomainName(sslContext, hostname, strlen(hostname)))
    }
    try sessionIdentifier.withUnsafeBytes { bytes in
      try Self.require(SSLSetPeerID(sslContext, bytes.baseAddress, bytes.count))
    }
    try Self.require(SSLSetSessionOption(sslContext, .enableSessionTickets, true))
    try Self.require(SSLSetProtocolVersionMin(sslContext, .tlsProtocol12))
  }

  func handlerAdded(context: ChannelHandlerContext) {
    if context.channel.isActive {
      beginHandshake(context: context)
    }
  }

  func channelActive(context: ChannelHandlerContext) {
    beginHandshake(context: context)
    context.fireChannelActive()
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var encrypted = unwrapInboundIn(data)
    if let bytes = encrypted.readBytes(length: encrypted.readableBytes) {
      io.appendEncryptedInput(bytes)
    }
    if handshakeCompleted {
      readPlaintext(context: context)
    } else {
      driveHandshake(context: context)
    }
  }

  func write(
    context: ChannelHandlerContext,
    data: NIOAny,
    promise: EventLoopPromise<Void>?
  ) {
    guard handshakeCompleted, !failed else {
      promise?.fail(FTPTransportError.tlsHandshakeFailed)
      return
    }
    var plaintext = unwrapOutboundIn(data)
    let bytes = plaintext.readBytes(length: plaintext.readableBytes) ?? []
    do {
      try bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
          var processed = 0
          let status = SSLWrite(
            sslContext,
            buffer.baseAddress?.advanced(by: offset),
            buffer.count - offset,
            &processed)
          offset += processed
          guard status == errSecSuccess || status == errSSLWouldBlock else {
            throw Self.map(status)
          }
          guard processed > 0 || status == errSecSuccess else {
            throw FTPTransportError.tlsHandshakeFailed
          }
        }
      }
      writeEncryptedOutput(context: context, promise: promise)
    } catch {
      promise?.fail(error)
      fail(error, context: context)
    }
  }

  func flush(context: ChannelHandlerContext) {
    context.flush()
  }

  func close(
    context: ChannelHandlerContext,
    mode: CloseMode,
    promise: EventLoopPromise<Void>?
  ) {
    if handshakeStarted {
      _ = SSLClose(sslContext)
      writeEncryptedOutput(context: context, promise: nil)
      context.flush()
    }
    context.close(mode: mode, promise: promise)
  }

  func channelInactive(context: ChannelHandlerContext) {
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    fail(error, context: context)
  }

  private func beginHandshake(context: ChannelHandlerContext) {
    guard !handshakeStarted, !failed else { return }
    handshakeStarted = true
    driveHandshake(context: context)
  }

  private func driveHandshake(context: ChannelHandlerContext) {
    guard handshakeStarted, !handshakeCompleted, !failed else { return }
    let status = SSLHandshake(sslContext)
    writeEncryptedOutput(context: context, promise: nil)
    context.flush()
    switch status {
    case errSecSuccess:
      handshakeCompleted = true
      context.fireUserInboundEventTriggered(
        TLSUserEvent.handshakeCompleted(negotiatedProtocol: nil))
      readPlaintext(context: context)
    case errSSLWouldBlock:
      return
    default:
      fail(mapHandshakeError(status), context: context)
    }
  }

  private func readPlaintext(context: ChannelHandlerContext) {
    guard handshakeCompleted, !failed else { return }
    while true {
      var plaintext = [UInt8](repeating: 0, count: 16 * 1_024)
      var processed = 0
      let status = SSLRead(sslContext, &plaintext, plaintext.count, &processed)
      writeEncryptedOutput(context: context, promise: nil)
      context.flush()
      if processed > 0 {
        plaintext.removeLast(plaintext.count - processed)
        context.fireChannelRead(wrapInboundOut(ByteBuffer(bytes: plaintext)))
      }
      switch status {
      case errSecSuccess:
        if processed == 0 { return }
      case errSSLWouldBlock:
        return
      case errSSLClosedGraceful:
        context.close(promise: nil)
        return
      default:
        fail(Self.map(status), context: context)
        return
      }
    }
  }

  private func writeEncryptedOutput(
    context: ChannelHandlerContext,
    promise: EventLoopPromise<Void>?
  ) {
    let bytes = io.takeEncryptedOutput()
    guard !bytes.isEmpty else {
      promise?.succeed(())
      return
    }
    context.write(wrapOutboundOut(ByteBuffer(bytes: bytes)), promise: promise)
  }

  private func fail(_ error: Error, context: ChannelHandlerContext) {
    guard !failed else { return }
    failed = true
    context.fireErrorCaught(error)
    context.close(promise: nil)
  }

  private static func require(_ status: OSStatus) throws {
    guard status == errSecSuccess else { throw map(status) }
  }

  private func mapHandshakeError(_ status: OSStatus) -> Error {
    guard status == errSSLXCertChainInvalid || status == errSSLBadCert else {
      return Self.map(status)
    }
    var peerTrust: SecTrust?
    guard SSLCopyPeerTrust(sslContext, &peerTrust) == errSecSuccess,
      let peerTrust
    else {
      return Self.map(status)
    }
    var trustError: CFError?
    guard !SecTrustEvaluateWithError(peerTrust, &trustError),
      let trustError
    else {
      return Self.map(status)
    }
    let error = trustError as Error as NSError
    if Self.containsHostnameMismatch(error) {
      return FTPTransportError.tlsHostnameValidationFailed
    }
    return Self.map(status)
  }

  private static func containsHostnameMismatch(_ error: NSError) -> Bool {
    if error.code == errSecHostNameMismatch { return true }
    guard let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
      return false
    }
    return containsHostnameMismatch(underlyingError)
  }

  private static func map(_ status: OSStatus) -> Error {
    switch status {
    case errSSLHostNameMismatch:
      FTPTransportError.tlsHostnameValidationFailed
    case errSSLUnknownRootCert, errSSLNoRootCert, errSSLCertExpired,
      errSSLXCertChainInvalid, errSSLBadCert:
      FTPTransportError.tlsCertificateValidationFailed
    default:
      FTPTransportError.tlsHandshakeFailed
    }
  }
}

private final class FTPSecureTransportIO: @unchecked Sendable {
  private var encryptedInput: [UInt8] = []
  private var encryptedOutput: [UInt8] = []

  func appendEncryptedInput(_ bytes: [UInt8]) {
    encryptedInput.append(contentsOf: bytes)
  }

  func read(
    into destination: UnsafeMutableRawPointer,
    requested: Int
  ) -> (status: OSStatus, count: Int) {
    let count = min(requested, encryptedInput.count)
    if count > 0 {
      encryptedInput.withUnsafeBytes { source in
        destination.copyMemory(from: source.baseAddress!, byteCount: count)
      }
      encryptedInput.removeFirst(count)
    }
    return (count == requested ? errSecSuccess : errSSLWouldBlock, count)
  }

  func write(from source: UnsafeRawPointer, count: Int) -> OSStatus {
    encryptedOutput.append(contentsOf: UnsafeRawBufferPointer(start: source, count: count))
    return errSecSuccess
  }

  func takeEncryptedOutput() -> [UInt8] {
    defer { encryptedOutput.removeAll(keepingCapacity: true) }
    return encryptedOutput
  }
}

private let ftpTLSRead: SSLReadFunc = { connection, data, dataLength in
  let io = Unmanaged<FTPSecureTransportIO>.fromOpaque(connection).takeUnretainedValue()
  let requested = dataLength.pointee
  let result = io.read(into: data, requested: requested)
  dataLength.pointee = result.count
  return result.status
}

private let ftpTLSWrite: SSLWriteFunc = { connection, data, dataLength in
  let io = Unmanaged<FTPSecureTransportIO>.fromOpaque(connection).takeUnretainedValue()
  let count = dataLength.pointee
  let status = io.write(from: data, count: count)
  dataLength.pointee = status == errSecSuccess ? count : 0
  return status
}
