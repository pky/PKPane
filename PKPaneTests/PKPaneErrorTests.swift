import Foundation
import Testing

@testable import PKPane

struct PKPaneErrorTests {
  @Test("カテゴリは設計表どおりの再試行方針を返す")
  func categoryRetryPoliciesMatchDesign() {
    let expected: [PKPaneErrorCategory: PKPaneErrorRetryPolicy] = [
      .accessDenied: .none,
      .notFound: .none,
      .alreadyExists: .none,
      .authenticationFailed: .none,
      .hostKeyUnknown: .afterApproval,
      .hostKeyChanged: .none,
      .networkUnavailable: .limited,
      .connectionLost: .readOnlyThenVerify,
      .timeout: .limited,
      .unsupported: .none,
      .conflict: .userDecision,
      .partialFailure: .failedItemsOnly,
      .cancelled: .none,
      .internalInvariant: .none,
      .unknown: .none,
    ]

    #expect(expected.count == PKPaneErrorCategory.allCases.count)
    for category in PKPaneErrorCategory.allCases {
      #expect(category.retryPolicy == expected[category])
    }
  }

  @Test("表示文言は説明、回復提案、マスク済み詳細を組み立てる")
  func buildsDisplayMessage() {
    let error = PKPaneError(
      category: .unknown,
      userMessage: "操作を完了できませんでした。",
      recoverySuggestion: "もう一度試してください。",
      technicalReason: "失敗: /Users/alice/Documents/report.txt")

    #expect(
      error.displayMessage
        == "操作を完了できませんでした。\nもう一度試してください。\n詳細: 失敗: ~/Documents/report.txt")
    #expect(error.localizedDescription == error.displayMessage)
  }
}
