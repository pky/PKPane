import AppKit
import Foundation
import Testing

@testable import PKPane

struct GitStatusTests {
  @Test("Git状態を変更橙・追加と未追跡緑・競合赤へ写像する")
  func mapsIndicatorColors() {
    #expect(GitStatusIndicatorStyle.color(for: .modified) == .systemOrange)
    #expect(GitStatusIndicatorStyle.color(for: .added) == .systemGreen)
    #expect(GitStatusIndicatorStyle.color(for: .untracked) == .systemGreen)
    #expect(GitStatusIndicatorStyle.color(for: .conflicted) == .systemRed)
  }

  @Test("porcelain v1の変更種別とNUL区切りの日本語名・リネームを解析する")
  func parsesPorcelainV1NullTerminatedOutput() {
    let data = Data(
      " M changed.swift\0A  added.swift\0?? 未追跡.txt\0UU conflict.txt\0R  新.swift\0旧.swift\0"
        .utf8)

    #expect(
      GitPorcelainParser.parse(data)
        == [
          GitStatusEntry(status: .modified, path: "changed.swift", originalPath: nil),
          GitStatusEntry(status: .added, path: "added.swift", originalPath: nil),
          GitStatusEntry(status: .untracked, path: "未追跡.txt", originalPath: nil),
          GitStatusEntry(status: .conflicted, path: "conflict.txt", originalPath: nil),
          GitStatusEntry(status: .modified, path: "新.swift", originalPath: "旧.swift"),
        ])
  }

  @Test("表示ディレクトリ配下の状態を直下項目へ優先度付きで集約する")
  func projectsStatusesOntoDirectChildren() {
    let root = URL(filePath: "/repo", directoryHint: .isDirectory)
    let directory = root.appending(path: "Sources", directoryHint: .isDirectory)
    let entries = [
      GitStatusEntry(status: .modified, path: "Sources/App/main.swift", originalPath: nil),
      GitStatusEntry(status: .conflicted, path: "Sources/App/conflict.swift", originalPath: nil),
      GitStatusEntry(status: .untracked, path: "Sources/日本語.txt", originalPath: nil),
      GitStatusEntry(status: .added, path: "Tests/test.swift", originalPath: nil),
    ]

    #expect(
      GitStatusProjection.directChildStatuses(
        from: entries, repositoryRoot: root, displayedDirectory: directory)
        == [
          directory.appending(path: "App"): .conflicted,
          directory.appending(path: "日本語.txt"): .untracked,
        ])
  }

  @Test("同一パスの検出とstatus実行をキャッシュし無効化後だけ再実行する")
  func cachesDetectionAndStatusUntilInvalidated() async {
    let root = URL(filePath: "/repo", directoryHint: .isDirectory)
    let directory = root.appending(path: "Sources", directoryHint: .isDirectory)
    let locator = RecordingGitRepositoryLocator(root: root)
    let runner = RecordingGitStatusRunner(output: Data(" M Sources/main.swift\0".utf8))
    let service = GitStatusService(locator: locator, runner: runner)

    let first = await service.statuses(in: directory)
    let second = await service.statuses(in: directory)
    #expect(first == second)
    #expect(await locator.callCount == 1)
    #expect(await runner.callCount == 1)

    await service.invalidate(directory: directory)
    _ = await service.statuses(in: directory)
    #expect(await locator.callCount == 2)
    #expect(await runner.callCount == 2)
  }

  @Test("同じフォルダの並行要求は1回のstatus実行を共有する")
  func coalescesConcurrentStatusRequests() async {
    let root = URL(filePath: "/repo", directoryHint: .isDirectory)
    let locator = RecordingGitRepositoryLocator(root: root, delay: .milliseconds(50))
    let runner = RecordingGitStatusRunner(
      output: Data(" M file.swift\0".utf8), delay: .milliseconds(50))
    let service = GitStatusService(
      locator: locator, runner: runner)

    async let first = service.statuses(in: root)
    async let second = service.statuses(in: root)
    _ = await (first, second)

    #expect(await locator.callCount == 1)
    #expect(await runner.callCount == 1)
  }

  @Test("ディレクトリキャッシュは上限を超えると最古パスを再探索対象へ戻す")
  func evictsLeastRecentlyUsedDirectoryCacheEntry() async {
    let root = URL(filePath: "/repo", directoryHint: .isDirectory)
    let locator = RecordingGitRepositoryLocator(root: root)
    let runner = RecordingGitStatusRunner(output: Data())
    let service = GitStatusService(
      locator: locator,
      runner: runner,
      cacheEntryLimit: 2)
    let directories = (0..<3).map {
      root.appending(path: "folder-\($0)", directoryHint: .isDirectory)
    }

    for directory in directories {
      _ = await service.statuses(in: directory)
    }
    _ = await service.statuses(in: directories[0])

    #expect(await locator.callCount == 4)
    #expect(await runner.callCount == 4)
  }

  @Test("タイムアウト時は実行をキャンセルし空結果を返す")
  func cancelsRunnerOnTimeout() async {
    let root = URL(filePath: "/repo", directoryHint: .isDirectory)
    let runner = RecordingGitStatusRunner(output: Data(), delay: .seconds(10))
    let service = GitStatusService(
      locator: RecordingGitRepositoryLocator(root: root),
      runner: runner,
      timeout: .milliseconds(30))

    #expect(await service.statuses(in: root).isEmpty)
    #expect(await runner.cancellationCount == 1)
  }
}

private actor RecordingGitRepositoryLocator: GitRepositoryLocating {
  private(set) var callCount = 0
  let root: URL?
  let delay: Duration

  init(root: URL?, delay: Duration = .zero) {
    self.root = root
    self.delay = delay
  }

  func repositoryRoot(containing _: URL) async -> URL? {
    callCount += 1
    try? await Task.sleep(for: delay)
    guard !Task.isCancelled else { return nil }
    return root
  }
}

private actor RecordingGitStatusRunner: GitStatusRunning {
  private(set) var callCount = 0
  private(set) var cancellationCount = 0
  let output: Data
  let delay: Duration

  init(output: Data, delay: Duration = .zero) {
    self.output = output
    self.delay = delay
  }

  func status(repositoryRoot _: URL, directory _: URL) async throws -> Data {
    callCount += 1
    do {
      try await Task.sleep(for: delay)
      return output
    } catch {
      cancellationCount += 1
      throw error
    }
  }
}
