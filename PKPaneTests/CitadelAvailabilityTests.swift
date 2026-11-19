import Testing

@testable import PKPane

struct CitadelAvailabilityTests {
  @Test("Citadelの採用候補バージョンを固定する")
  func packageVersionIsPinned() {
    #expect(CitadelAvailability.packageVersion == "0.12.1")
  }
}
