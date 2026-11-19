import Foundation

/// サイドバー「場所」セクションの1行。デバイス固有の揮発データであり、
/// ブックマークやお気に入りリポジトリへは決して保存しない(iCloud同期へ漏らさないため)。
struct SidebarPlace: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case volume(isEjectable: Bool)
    case iCloudDrive
    case cloudStorage
  }

  /// 標準化済みパス。ボリューム名は同名衝突するためIDにしない。
  let id: String
  let url: URL
  let displayName: String
  /// 補足(クラウドのアカウント名やパス)。sidebarLocationButtonの.helpに出る。
  let detail: String?
  let kind: Kind

  var systemImage: String {
    switch kind {
    case .volume(let isEjectable):
      isEjectable ? "externaldrive" : "internaldrive"
    case .iCloudDrive:
      "icloud"
    case .cloudStorage:
      "cloud"
    }
  }
}
