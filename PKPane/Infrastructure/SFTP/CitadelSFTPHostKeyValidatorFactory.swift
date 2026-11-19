import Citadel
import Foundation
import NIO
import NIOSSH

struct SFTPHostKeyValidation {
  let validator: SSHHostKeyValidator
  let capture: SFTPHostKeyCapture
  let trustedPublicKey: String?
}

struct CitadelSFTPHostKeyValidatorFactory {
  let trustStore: SFTPHostKeyTrustStore

  func validation(for target: SFTPConnectionTarget) -> SFTPHostKeyValidation {
    validation(host: target.finalHop.host, port: target.finalHop.port)
  }

  func validation(host: String, port: Int) -> SFTPHostKeyValidation {
    let trustedPublicKey = trustStore.trustedOpenSSHPublicKey(host: host, port: port)
    let capture = SFTPHostKeyCapture(trustedPublicKey: trustedPublicKey)
    return SFTPHostKeyValidation(
      validator: .custom(capture),
      capture: capture,
      trustedPublicKey: trustedPublicKey)
  }
}

final class SFTPHostKeyCapture: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private let trustedPublicKey: String?
  private var capturedPublicKey: String?

  init(trustedPublicKey: String?) {
    self.trustedPublicKey = trustedPublicKey
  }

  func validateHostKey(
    hostKey: NIOSSHPublicKey,
    validationCompletePromise: EventLoopPromise<Void>
  ) {
    let publicKey = String(openSSHPublicKey: hostKey)
    lock.lock()
    capturedPublicKey = publicKey
    lock.unlock()
    if trustedPublicKey == publicKey {
      validationCompletePromise.succeed(())
    } else {
      validationCompletePromise.fail(SFTPUntrustedHostKey())
    }
  }

  var publicKey: String? {
    lock.lock()
    defer { lock.unlock() }
    return capturedPublicKey
  }
}

private struct SFTPUntrustedHostKey: Error {}
