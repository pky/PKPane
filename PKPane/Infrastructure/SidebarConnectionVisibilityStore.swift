import Foundation

/// サイドバーの接続セクションから隠された接続の識別子集合をUserDefaultsへ永続化する。
/// 既定は空集合(=全接続が表示)。NAS/SFTPのどちらの接続も同じ集合で扱うため、
/// 識別子はプロトコルごとに一意な文字列へ変換して格納する。
final class SidebarConnectionVisibilityStore {
  private let defaults: UserDefaults
  private let key = "sidebar-hidden-connection-ids"

  init(defaults: UserDefaults? = nil) {
    self.defaults = defaults ?? Self.defaultUserDefaults
  }

  func hiddenIdentifiers() -> Set<String> {
    Set(defaults.stringArray(forKey: key) ?? [])
  }

  func isHidden(_ identifier: String) -> Bool {
    hiddenIdentifiers().contains(identifier)
  }

  func setHidden(_ hidden: Bool, for identifier: String) {
    var identifiers = hiddenIdentifiers()
    if hidden {
      identifiers.insert(identifier)
    } else {
      identifiers.remove(identifier)
    }
    if identifiers.isEmpty {
      defaults.removeObject(forKey: key)
    } else {
      defaults.set(Array(identifiers), forKey: key)
    }
  }

  /// NAS接続の識別子はprofile.id(UUID)で一意。
  static func identifier(for profile: NASConnectionProfile) -> String {
    "nas:\(profile.id.uuidString)"
  }

  /// SFTP接続の識別子はhost+port+usernameで一意(SFTPConnectionTargetのEquatable/Hashable定義と揃える)。
  static func identifier(for target: SFTPConnectionTarget) -> String {
    "sftp:\(target.host.lowercased()):\(target.port):\(target.username.lowercased())"
  }

  static func identifier(for target: FTPConnectionTarget) -> String {
    "ftp:\(target.security.rawValue):\(target.host.lowercased()):\(target.port):\(target.username.lowercased())"
  }

  private static var defaultUserDefaults: UserDefaults {
    PKPaneUserDefaults.resolve()
  }
}
