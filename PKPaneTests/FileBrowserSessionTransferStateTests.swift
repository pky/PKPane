import Foundation
import Testing

@testable import PKPane

/// startTransferはbeginTransferで実行中集合へ同期登録した後、非同期Taskの中で
/// TransferQueueへenqueueする。その間に無関係ジョブの更新が届くと、キュー一覧に
/// まだ現れない自ジョブが実行中集合から消えisTransferringが偽りのfalseへ落ちる
/// レースがあった(並列テストで転送完了待ちが早抜けし移動未実行のまま検証が走る)。
struct FileBrowserSessionTransferStateTests {
  @Test("キュー未登録のローカル登録済みジョブはenqueue前として実行中集合に保持する")
  func keepsLocallyRegisteredJobAwaitingEnqueue() {
    let pendingID = UUID()

    let result = FileBrowserSession.recomputedExecutingTransferJobIDs(
      current: [pendingID], active: [pendingID], jobs: [])

    #expect(result == [pendingID])
  }

  @Test("キューに現れたqueued・runningジョブは実行中集合へ含める")
  func includesQueuedAndRunningJobsKnownToQueue() {
    var queued = makeJob()
    queued.state = .queued
    var running = makeJob()
    running.state = .running

    let result = FileBrowserSession.recomputedExecutingTransferJobIDs(
      current: [],
      active: [queued.id, running.id],
      jobs: [queued, running])

    #expect(result == [queued.id, running.id])
  }

  @Test("キューで終端状態になったジョブは実行中集合から除外する")
  func excludesTerminalJobsKnownToQueue() {
    var failed = makeJob()
    failed.state = .failed

    let result = FileBrowserSession.recomputedExecutingTransferJobIDs(
      current: [failed.id], active: [failed.id], jobs: [failed])

    #expect(result.isEmpty)
  }

  @Test("activeでないジョブはキュー未登録でも実行中集合に保持しない")
  func dropsInactiveJobsEvenWhenUnknownToQueue() {
    let inactiveID = UUID()

    let result = FileBrowserSession.recomputedExecutingTransferJobIDs(
      current: [inactiveID], active: [], jobs: [])

    #expect(result.isEmpty)
  }

  private func makeJob() -> TransferJob {
    let providerID = FileProviderID(rawValue: "source")
    let item = FileItem(
      remotePath: "./report.txt",
      url: URL(string: "test://source/report.txt")!,
      providerID: providerID,
      isDirectory: false,
      size: 4)
    return TransferJob(
      kind: .copy,
      items: [item],
      sourceProviderID: providerID,
      destinationProviderID: FileProviderID(rawValue: "destination"),
      destination: FileLocation(
        remotePath: ".",
        providerID: FileProviderID(rawValue: "destination")))
  }
}
