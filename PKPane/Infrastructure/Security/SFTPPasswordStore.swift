import Foundation
import Security

protocol KeychainPasswordDataStoring: AnyObject {
  func save(password: String, service: String, account: String) throws
  func password(service: String, account: String) throws -> String?
  func remove(service: String, account: String) throws
}

extension KeychainPasswordDataStoring {
  func remove(service _: String, account _: String) throws {}
}

final class SFTPPasswordStore {
  private static let service = "com.pky.PKPane.sftp-password"
  private let keychain: any KeychainPasswordDataStoring

  init(keychain: any KeychainPasswordDataStoring = SystemKeychainPasswordDataStore()) {
    self.keychain = keychain
  }

  func save(_ password: String, for target: SFTPConnectionTarget) throws {
    try save(password, for: target.finalHop, kind: .password)
  }

  func password(for target: SFTPConnectionTarget) throws -> String? {
    try secret(for: target.finalHop, kind: .password)
  }

  func secret(for hop: SFTPHopIdentity, kind: SFTPCredentialKind) throws -> String? {
    try keychain.password(service: Self.service, account: Self.account(for: hop, kind: kind))
  }

  func save(_ secret: String, for hop: SFTPHopIdentity, kind: SFTPCredentialKind) throws {
    try keychain.save(
      password: secret,
      service: Self.service,
      account: Self.account(for: hop, kind: kind))
  }

  func remove(for hop: SFTPHopIdentity, kind: SFTPCredentialKind) throws {
    try keychain.remove(service: Self.service, account: Self.account(for: hop, kind: kind))
  }

  static func account(for hop: SFTPHopIdentity, kind: SFTPCredentialKind) -> String {
    let base = "\(hop.host):\(hop.port):\(hop.username)"
    switch kind {
    case .password:
      return base
    case .passphrase(let keyPath):
      return "\(base)#passphrase:\(keyPath)"
    }
  }
}

final class SystemKeychainPasswordDataStore: KeychainPasswordDataStoring {
  func save(password: String, service: String, account: String) throws {
    let query = baseQuery(service: service, account: account)
    let data = Data(password.utf8)
    let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)

    if updateStatus == errSecItemNotFound {
      var addQuery = query
      addQuery[kSecValueData] = data
      try check(SecItemAdd(addQuery as CFDictionary, nil))
      return
    }

    try check(updateStatus)
  }

  func password(service: String, account: String) throws -> String? {
    var query = baseQuery(service: service, account: account)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    try check(status)

    guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
      throw KeychainPasswordDataStoreError.invalidData
    }
    return password
  }

  func remove(service: String, account: String) throws {
    let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    if status != errSecItemNotFound {
      try check(status)
    }
  }

  private func baseQuery(service: String, account: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
  }

  private func check(_ status: OSStatus) throws {
    guard status == errSecSuccess else {
      throw KeychainPasswordDataStoreError.operationFailed(status)
    }
  }
}

enum KeychainPasswordDataStoreError: LocalizedError {
  case invalidData
  case operationFailed(OSStatus)

  var errorDescription: String? {
    switch self {
    case .invalidData:
      "Keychainのパスワードデータを読み取れませんでした。"
    case .operationFailed:
      "Keychainへのアクセスに失敗しました。"
    }
  }
}
