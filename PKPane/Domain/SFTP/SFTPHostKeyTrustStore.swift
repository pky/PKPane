import CryptoKit
import Foundation

enum SFTPHostKeyTrustStatus: Equatable {
  case unknown
  case trusted
  case changed
}

final class SFTPHostKeyTrustStore {
  private let defaults: UserDefaults

  init(defaults: UserDefaults? = nil) {
    self.defaults = defaults ?? Self.defaultUserDefaults
  }

  func status(for target: SFTPConnectionTarget, fingerprint: String) -> SFTPHostKeyTrustStatus {
    guard let storedFingerprint = defaults.string(forKey: key(for: target)) else {
      return .unknown
    }
    return storedFingerprint == fingerprint ? .trusted : .changed
  }

  func trust(_ fingerprint: String, for target: SFTPConnectionTarget) {
    defaults.set(fingerprint, forKey: key(for: target))
  }

  func trustedOpenSSHPublicKey(for target: SFTPConnectionTarget) -> String? {
    trustedOpenSSHPublicKey(host: target.finalHop.host, port: target.finalHop.port)
  }

  func trust(openSSHPublicKey: String, for target: SFTPConnectionTarget) {
    trust(
      openSSHPublicKey: openSSHPublicKey,
      host: target.finalHop.host,
      port: target.finalHop.port)
  }

  func trustedOpenSSHPublicKey(host: String, port: Int) -> String? {
    defaults.string(forKey: publicKeyKey(host: host, port: port))
  }

  func trust(openSSHPublicKey: String, host: String, port: Int) {
    defaults.set(openSSHPublicKey, forKey: publicKeyKey(host: host, port: port))
  }

  static func fingerprint(for openSSHPublicKey: String) -> String {
    let components = openSSHPublicKey.split(separator: " ", maxSplits: 2)
    let encodedKey = components.dropFirst().first
    let keyData: Data
    if let encodedKey, let decodedKey = Data(base64Encoded: String(encodedKey)) {
      keyData = decodedKey
    } else {
      keyData = Data(openSSHPublicKey.utf8)
    }
    let digest = SHA256.hash(data: keyData)
    return "SHA256:\(Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: ""))"
  }

  func removeTrust(for target: SFTPConnectionTarget) {
    defaults.removeObject(forKey: key(for: target))
    defaults.removeObject(forKey: publicKeyKey(for: target))
  }

  private func key(for target: SFTPConnectionTarget) -> String {
    "sftp-host-key-\(target.host):\(target.port)"
  }

  private func publicKeyKey(for target: SFTPConnectionTarget) -> String {
    publicKeyKey(host: target.host, port: target.port)
  }

  private func publicKeyKey(host: String, port: Int) -> String {
    "sftp-host-key-\(host):\(port)-public-key"
  }

  private static var defaultUserDefaults: UserDefaults {
    PKPaneUserDefaults.resolve()
  }
}
