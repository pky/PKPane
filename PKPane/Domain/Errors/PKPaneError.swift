import Foundation

enum PKPaneErrorCategory: CaseIterable, Equatable, Hashable, Sendable {
  case accessDenied
  case notFound
  case alreadyExists
  case authenticationFailed
  case hostKeyUnknown
  case hostKeyChanged
  case networkUnavailable
  case connectionLost
  case timeout
  case unsupported
  case conflict
  case partialFailure
  case cancelled
  case internalInvariant
  case unknown

  var retryPolicy: PKPaneErrorRetryPolicy {
    switch self {
    case .hostKeyUnknown:
      .afterApproval
    case .networkUnavailable, .timeout:
      .limited
    case .connectionLost:
      .readOnlyThenVerify
    case .partialFailure:
      .failedItemsOnly
    case .conflict:
      .userDecision
    case .accessDenied, .notFound, .alreadyExists, .authenticationFailed, .hostKeyChanged,
      .unsupported, .cancelled, .internalInvariant, .unknown:
      .none
    }
  }
}

enum PKPaneErrorRetryPolicy: Equatable, Sendable {
  case none
  case afterApproval
  case limited
  case readOnlyThenVerify
  case failedItemsOnly
  case userDecision
}

struct PKPaneError: LocalizedError, Equatable, Sendable {
  let category: PKPaneErrorCategory
  let userMessage: String
  let recoverySuggestion: String?
  let technicalReason: String?
  let subjectName: String?

  init(
    category: PKPaneErrorCategory,
    userMessage: String,
    recoverySuggestion: String? = nil,
    technicalReason: String? = nil,
    subjectName: String? = nil
  ) {
    self.category = category
    self.userMessage = userMessage
    self.recoverySuggestion = recoverySuggestion
    self.technicalReason = technicalReason.map(SecretMasker.maskForDisplay)
    self.subjectName = subjectName
  }

  var retryPolicy: PKPaneErrorRetryPolicy {
    category.retryPolicy
  }

  var displayMessage: String {
    var parts = [userMessage]
    if let recoverySuggestion, !recoverySuggestion.isEmpty {
      parts.append(recoverySuggestion)
    }
    if let technicalReason, !technicalReason.isEmpty {
      parts.append("詳細: \(technicalReason)")
    }
    return parts.joined(separator: "\n")
  }

  var errorDescription: String? {
    displayMessage
  }
}
