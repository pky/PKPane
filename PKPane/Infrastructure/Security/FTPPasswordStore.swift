import Foundation

final class FTPPasswordStore {
  private static let service = "com.pky.PKPane.ftp-password"
  private let keychain: any KeychainPasswordDataStoring

  init(keychain: any KeychainPasswordDataStoring = SystemKeychainPasswordDataStore()) {
    self.keychain = keychain
  }

  func save(_ password: String, for target: FTPConnectionTarget) throws {
    try keychain.save(password: password, service: Self.service, account: account(for: target))
  }

  func password(for target: FTPConnectionTarget) throws -> String? {
    try keychain.password(service: Self.service, account: account(for: target))
  }

  private func account(for target: FTPConnectionTarget) -> String {
    "\(target.security.rawValue):\(target.host):\(target.port):\(target.username)"
  }
}
