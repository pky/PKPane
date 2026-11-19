import Foundation
import Observation

struct SFTPCredentialPromptItem: Identifiable {
  let id: UUID
  let request: SFTPCredentialRequest
}

@MainActor
@Observable
final class SFTPCredentialPromptCoordinator: SFTPCredentialPrompting {
  private(set) var current: SFTPCredentialPromptItem?
  private let presentsUI: Bool
  @ObservationIgnored private var pending: [PendingRequest] = []

  private struct PendingRequest {
    let item: SFTPCredentialPromptItem
    let continuation: CheckedContinuation<SFTPCredentialAnswer?, Never>
  }

  init(
    presentsUI: Bool = !TestEnvironmentDetector.isRunningTests(
      environment: ProcessInfo.processInfo.environment)
  ) {
    self.presentsUI = presentsUI
  }

  func requestCredential(_ request: SFTPCredentialRequest) async -> SFTPCredentialAnswer? {
    guard presentsUI, !Task.isCancelled else { return nil }
    let item = SFTPCredentialPromptItem(id: UUID(), request: request)
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: nil)
          return
        }
        pending.append(PendingRequest(item: item, continuation: continuation))
        if current == nil { current = item }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.finish(id: item.id, answer: nil)
      }
    }
  }

  func submit(secret: String, saveToKeychain: Bool) {
    guard let current else { return }
    finish(
      id: current.id,
      answer: SFTPCredentialAnswer(secret: secret, saveToKeychain: saveToKeychain))
  }

  func cancel() {
    guard let current else { return }
    finish(id: current.id, answer: nil)
  }

  func cancelAll() {
    let cancelled = pending
    pending.removeAll()
    current = nil
    for request in cancelled {
      request.continuation.resume(returning: nil)
    }
  }

  private func finish(id: UUID, answer: SFTPCredentialAnswer?) {
    guard let index = pending.firstIndex(where: { $0.item.id == id }) else { return }
    let completed = pending.remove(at: index)
    if current?.id == id { current = pending.first?.item }
    completed.continuation.resume(returning: answer)
  }
}
