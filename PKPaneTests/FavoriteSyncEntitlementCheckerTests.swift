import Testing

@testable import PKPane

struct FavoriteSyncEntitlementCheckerTests {
  @Test("ad-hocテストビルドにはKVS entitlementがない")
  func adHocTestBuildDoesNotHaveKVS() {
    #expect(!SystemFavoriteSyncEntitlementChecker().hasUbiquityKeyValueStoreEntitlement())
  }
}
