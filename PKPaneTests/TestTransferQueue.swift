import Foundation

@testable import PKPane

final class InMemoryTransferJobStore: TransferJobStore, @unchecked Sendable {
  private let lock = NSLock()
  private var jobs: [TransferJob] = []

  func load() throws -> [TransferJob] {
    lock.withLock { jobs }
  }

  func save(_ jobs: [TransferJob]) throws {
    lock.withLock { self.jobs = jobs }
  }

  func snapshot() -> [TransferJob] {
    lock.withLock { jobs }
  }
}

extension TransferQueue {
  static func isolatedForTesting(
    maximumConcurrentTransfers: Int = 2
  ) -> TransferQueue {
    TransferQueue(
      store: InMemoryTransferJobStore(),
      maximumConcurrentTransfers: maximumConcurrentTransfers)
  }
}
