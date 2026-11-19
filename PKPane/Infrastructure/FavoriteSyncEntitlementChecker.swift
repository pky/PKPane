import Foundation
import Security

protocol FavoriteSyncEntitlementChecking: Sendable {
  func hasUbiquityKeyValueStoreEntitlement() -> Bool
}

struct SystemFavoriteSyncEntitlementChecker: FavoriteSyncEntitlementChecking {
  static let entitlementName = "com.apple.developer.ubiquity-kvstore-identifier"

  func hasUbiquityKeyValueStoreEntitlement() -> Bool {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    return SecTaskCopyValueForEntitlement(
      task,
      Self.entitlementName as CFString,
      nil
    ) != nil
  }
}
