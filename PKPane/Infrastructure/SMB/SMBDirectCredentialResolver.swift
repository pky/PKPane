import Foundation
import Security

/// 直接SMB接続でだけ使用するログインKeychain上の資格情報です。
struct SMBDirectCredentials: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  let account: String
  let password: String

  var description: String { "account: ***, password: ***" }
  var debugDescription: String { description }
}

/// テスト用にKeychain照会を差し替える境界です。
protocol SMBDirectCredentialQuerying: AnyObject, Sendable {
  func accounts(forServer server: String) throws -> [String]
  func credential(forServer server: String, account: String) throws -> SMBDirectCredentials?
}

protocol SMBDirectCredentialResolving: Sendable {
  func credentials(forServer server: String, preferredAccount: String?) -> SMBDirectCredentials?
}

/// macOSがマウント時に保存したSMB資格情報を、その場で解決します。
///
/// 資格情報をアプリ側で保持しないため、呼び出しごとにKeychainを照会します。
final class SMBDirectCredentialResolver: SMBDirectCredentialResolving, Sendable {
  private let keychain: any SMBDirectCredentialQuerying

  init(keychain: any SMBDirectCredentialQuerying = SystemSMBDirectCredentialQuery()) {
    self.keychain = keychain
  }

  /// 指定アカウントがあれば完全一致を優先し、なければ同じサーバーの先頭候補を返します。
  /// Keychainに項目がない場合やアクセスできない場合は直接SMBを使わないためnilを返します。
  func credentials(
    forServer server: String,
    preferredAccount: String? = nil
  ) -> SMBDirectCredentials? {
    guard let accounts = try? keychain.accounts(forServer: server) else { return nil }
    let account =
      preferredAccount.flatMap { preferredAccount in
        accounts.first(where: { $0 == preferredAccount })
      } ?? accounts.first
    guard let account else { return nil }
    return try? keychain.credential(forServer: server, account: account)
  }
}

private final class SystemSMBDirectCredentialQuery:
  SMBDirectCredentialQuerying,
  Sendable
{
  func accounts(forServer server: String) throws -> [String] {
    let query: [CFString: Any] = [
      kSecClass: kSecClassInternetPassword,
      kSecAttrProtocol: kSecAttrProtocolSMB,
      kSecAttrServer: server,
      kSecReturnAttributes: true,
      kSecMatchLimit: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else {
      throw SMBDirectCredentialQueryError.operationFailed(status)
    }
    guard let result = result as? [[String: Any]] else {
      throw SMBDirectCredentialQueryError.invalidResult
    }
    return result.compactMap { $0[kSecAttrAccount as String] as? String }
  }

  func credential(forServer server: String, account: String) throws -> SMBDirectCredentials? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassInternetPassword,
      kSecAttrProtocol: kSecAttrProtocolSMB,
      kSecAttrServer: server,
      kSecAttrAccount: account,
      kSecReturnAttributes: true,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else {
      throw SMBDirectCredentialQueryError.operationFailed(status)
    }
    guard let entry = result as? [String: Any],
      let passwordData = entry[kSecValueData as String] as? Data,
      let password = String(data: passwordData, encoding: .utf8)
    else {
      throw SMBDirectCredentialQueryError.invalidResult
    }
    return SMBDirectCredentials(account: account, password: password)
  }
}

private enum SMBDirectCredentialQueryError: Error {
  case invalidResult
  case operationFailed(OSStatus)
}
