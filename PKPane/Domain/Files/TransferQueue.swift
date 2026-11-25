import Foundation

enum TransferJobHistoryPolicy {
  static let terminalLimit = 1_000
}

/// アプリを再起動しても転送状況を表示できる、転送対象の不変な記録です。
struct TransferJob: Codable, Equatable, Identifiable, Sendable {
  enum Kind: String, Codable, Sendable {
    case copy
    case move
  }

  enum State: String, Codable, Sendable {
    case queued
    case running
    case paused
    case completed
    case failed
    case cancelled
    case interrupted

    var isTerminal: Bool {
      switch self {
      case .completed, .failed, .cancelled, .interrupted: true
      case .queued, .running, .paused: false
      }
    }
  }

  struct Item: Codable, Hashable, Sendable {
    let location: FileLocation
    let name: String
    let isDirectory: Bool
    let totalBytes: Int64?
    /// P1-1のTransferSizeVerifierはシンボリックリンクを検証対象外にする(リンク自体と
    /// リンク先の実体でサイズの対応が取れないため)。プロセス再起動で復元したジョブでも
    /// この判定が効くよう、item自体にisSymbolicLinkを持たせる。
    let isSymbolicLink: Bool
    let transferOptions: TransferItemOptions

    init(_ item: FileItem) {
      self.init(item, options: TransferItemOptions())
    }

    init(_ item: FileItem, options: TransferItemOptions) {
      location = item.location
      name = item.name
      isDirectory = item.isDirectory
      totalBytes = item.size
      isSymbolicLink = item.isSymbolicLink
      transferOptions = options
    }

    var fileItem: FileItem {
      switch location.path {
      case .local(let url):
        FileItem(
          url: url,
          providerID: location.providerID,
          isDirectory: isDirectory,
          isSymbolicLink: isSymbolicLink,
          size: totalBytes)
      case .remote(let path):
        FileItem(
          remotePath: path,
          url: URL(fileURLWithPath: "/\(name)"),
          providerID: location.providerID,
          isDirectory: isDirectory,
          isSymbolicLink: isSymbolicLink,
          size: totalBytes)
      }
    }

    private enum CodingKeys: CodingKey {
      case location, name, isDirectory, totalBytes, isSymbolicLink, transferOptions
    }

    /// isSymbolicLinkは今回追加したフィールドのため、ディスク上に残る旧形式のjson
    /// (このキーを持たない)を後方互換で読めるよう、無ければfalseにフォールバックする。
    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      location = try container.decode(FileLocation.self, forKey: .location)
      name = try container.decode(String.self, forKey: .name)
      isDirectory = try container.decode(Bool.self, forKey: .isDirectory)
      totalBytes = try container.decodeIfPresent(Int64.self, forKey: .totalBytes)
      isSymbolicLink =
        try container.decodeIfPresent(Bool.self, forKey: .isSymbolicLink) ?? false
      transferOptions =
        try container.decodeIfPresent(TransferItemOptions.self, forKey: .transferOptions)
        ?? TransferItemOptions()
    }
  }

  let id: UUID
  let kind: Kind
  var items: [Item]
  let sourceProviderID: FileProviderID
  /// 最近の項目からのローカル転送を再開するとき、実際の転送元許可を復元する。
  var sourceAccessBookmarkData: Data?
  let destinationProviderID: FileProviderID
  let destination: FileLocation
  let createdAt: Date
  var state: State
  var completedBytes: Int64
  var totalBytes: Int64?
  var errorDescription: String?
  var startedAt: Date?
  var updatedAt: Date
  /// 転送レジューム(P1-2)用: このジョブの実行中に検証まで通って完了したitemsの記録。
  /// ジョブ全体がfailed/interrupted/cancelledで終了しても消えず、次のretryが
  /// 「安全にスキップできる項目」を判定するために使う(destination側の再確認は
  /// retry側の責務。ここは記録のみ)。完了(.completed)したジョブでは空に戻す。
  var completedItems: [Item]
  /// 自動再接続(P1-3)用: 直近のfailedが、再接続では直らない種類のエラー
  /// (TransferJobPartialFailure.isReconnectFutile)由来だったかどうか。trueなら
  /// FileBrowserSession側の自動リトライ対象から外し、既存の手動リトライUIへ直行させる。
  var isReconnectFutile: Bool
  var skippedItemCount: Int
  var isLocalSameVolumeMove: Bool

  init(
    id: UUID = UUID(),
    kind: Kind,
    items: [FileItem],
    sourceProviderID: FileProviderID,
    destinationProviderID: FileProviderID,
    destination: FileLocation,
    createdAt: Date = .now
  ) {
    self.id = id
    self.kind = kind
    self.items = items.map(Item.init)
    self.sourceProviderID = sourceProviderID
    sourceAccessBookmarkData = nil
    self.destinationProviderID = destinationProviderID
    self.destination = destination
    self.createdAt = createdAt
    state = .queued
    completedBytes = 0
    totalBytes = items.reduce(into: Int64(0)) { partialResult, item in
      guard let size = item.size else {
        partialResult = -1
        return
      }
      guard partialResult >= 0 else { return }
      partialResult += size
    }
    if totalBytes == -1 { totalBytes = nil }
    errorDescription = nil
    startedAt = nil
    updatedAt = createdAt
    completedItems = []
    isReconnectFutile = false
    skippedItemCount = 0
    isLocalSameVolumeMove = false
  }

  private enum CodingKeys: CodingKey {
    case id, kind, items, sourceProviderID, sourceAccessBookmarkData, destinationProviderID,
      destination, createdAt, state,
      completedBytes, totalBytes, errorDescription, startedAt, updatedAt, completedItems,
      isReconnectFutile, skippedItemCount, isLocalSameVolumeMove
  }

  /// completedItems/isReconnectFutileは追加したフィールドのため、ディスク上に残る
  /// 旧形式のjson(このキーを持たない)を後方互換で読めるよう、無ければfalse/空配列に
  /// フォールバックする。
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    kind = try container.decode(Kind.self, forKey: .kind)
    items = try container.decode([Item].self, forKey: .items)
    sourceProviderID = try container.decode(FileProviderID.self, forKey: .sourceProviderID)
    sourceAccessBookmarkData = try container.decodeIfPresent(
      Data.self, forKey: .sourceAccessBookmarkData)
    destinationProviderID = try container.decode(
      FileProviderID.self, forKey: .destinationProviderID)
    destination = try container.decode(FileLocation.self, forKey: .destination)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    state = try container.decode(State.self, forKey: .state)
    completedBytes = try container.decode(Int64.self, forKey: .completedBytes)
    totalBytes = try container.decodeIfPresent(Int64.self, forKey: .totalBytes)
    errorDescription = try container.decodeIfPresent(String.self, forKey: .errorDescription)
    startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    completedItems = try container.decodeIfPresent([Item].self, forKey: .completedItems) ?? []
    isReconnectFutile =
      try container.decodeIfPresent(Bool.self, forKey: .isReconnectFutile) ?? false
    skippedItemCount = try container.decodeIfPresent(Int.self, forKey: .skippedItemCount) ?? 0
    isLocalSameVolumeMove =
      try container.decodeIfPresent(Bool.self, forKey: .isLocalSameVolumeMove) ?? false
  }

  var throughputBytesPerSecond: Double? {
    guard let startedAt, completedBytes > 0 else { return nil }
    let duration = max(updatedAt.timeIntervalSince(startedAt), 0.001)
    return Double(completedBytes) / duration
  }

  var estimatedRemainingTime: TimeInterval? {
    guard let totalBytes, let throughputBytesPerSecond, throughputBytesPerSecond > 0 else {
      return nil
    }
    return Double(max(totalBytes - completedBytes, 0)) / throughputBytesPerSecond
  }

  mutating func retainFailedItems(_ failedItems: [Item]) {
    items = failedItems
    completedBytes = 0
    totalBytes = failedItems.reduce(into: Int64(0)) { partialResult, item in
      guard let size = item.totalBytes else {
        partialResult = -1
        return
      }
      guard partialResult >= 0 else { return }
      partialResult += size
    }
    if totalBytes == -1 { totalBytes = nil }
  }
}

struct TransferJobPartialFailure: Error, LocalizedError, Sendable {
  let failedItems: [TransferJob.Item]
  let underlyingErrorDescription: String
  /// 自動再接続(P1-3)の対象外にすべきかどうか。失敗項目のうち1つでも再接続では
  /// 直らない種類のエラー(TransferReconnectionPolicy.isEligibleForAutoReconnectが
  /// falseと判定したもの、資格情報エラー等)であれば、ジョブ全体を自動再試行の対象外にする。
  /// 残りの項目だけ自動リトライしても、直らない項目のために自動リトライの枠を消費し続け
  /// 手動リトライへ辿り着くまでを遅らせるだけのため。
  var isReconnectFutile: Bool = false
  var recoveryDescription: String? = nil

  var errorDescription: String? {
    "\(failedItems.count)項目の転送に失敗しました。\(underlyingErrorDescription)"
  }
}

protocol TransferJobStore: Sendable {
  func load() throws -> [TransferJob]
  func save(_ jobs: [TransferJob]) throws
}

struct JSONTransferJobStore: TransferJobStore {
  let url: URL

  init(url: URL? = nil) {
    self.url = url ?? Self.defaultURL(environment: ProcessInfo.processInfo.environment)
  }

  /// テストランナー内(XCTest/Swift Testing)では実ユーザーのApplication Supportへ
  /// 絶対に書き込まない。テストが並列ワーカープロセスで走るため、プロセスIDを含めた
  /// 一時パスで相互干渉も断つ(実ファイル共有が過去に数百件のテスト巻き添え失敗を
  /// 引き起こした)。
  static func defaultURL(environment: [String: String]) -> URL {
    if TestEnvironmentDetector.isRunningTests(environment: environment) {
      return FileManager.default.temporaryDirectory
        .appending(path: "pkpane-tests", directoryHint: .isDirectory)
        .appending(path: "transfer-jobs-\(ProcessInfo.processInfo.processIdentifier).json")
    }
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!.appending(path: "PKPane", directoryHint: .isDirectory)
    return directory.appending(path: "transfer-jobs.json")
  }

  func load() throws -> [TransferJob] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try JSONDecoder().decode([TransferJob].self, from: Data(contentsOf: url)).map { job in
      var job = job
      job.errorDescription = job.errorDescription.map(SecretMasker.maskForDisplay)
      return job
    }
  }

  func save(_ jobs: [TransferJob]) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let maskedJobs = jobs.map { job in
      var job = job
      job.errorDescription = job.errorDescription.map(SecretMasker.maskForDisplay)
      return job
    }
    try encoder.encode(maskedJobs).write(to: url, options: .atomic)
  }
}

actor TransferQueue {
  typealias ProgressReporter = @Sendable (FileTransferProgress) async -> Void
  /// 1件のitemが検証まで通って完了するたびに呼ばれる。進捗(ProgressReporter)は間引き・
  /// 破棄されうる表示専用の値だが、こちらはレジューム判定の根拠として即座に永続化する
  /// ため別チャネルにしている。
  typealias ItemCompletionReporter = @Sendable (TransferJob.Item) async -> Void
  typealias Execution =
    @Sendable (
      @escaping ProgressReporter, @escaping ItemCompletionReporter
    ) async throws -> Void
  /// 自動再接続(P1-3)用: 失敗検知のたびに呼ばれ、自動リトライすべきかを判定する。
  /// 呼び出し元(FileBrowserSession)がプロバイダのスコープ適合性(SFTP限定)や
  /// 自動リトライの残り回数を判定し、リトライするならバックオフと次のexecutionを返す。
  /// nilを返せば自動リトライせず通常のfailedへ落とす。isReconnectFutileは呼び出し前に
  /// 既にfalseであることを保証済み(TransferJobPartialFailure由来の判定はTransferQueue
  /// 側で先に済ませている)ため、このクロージャはプロバイダスコープ判定に専念できる。
  typealias AutoRetryPlanner =
    @Sendable (
      _ isReconnectFutile: Bool
    ) async -> (backoff: Duration, execution: Execution)?

  static let shared = TransferQueue()

  private let store: any TransferJobStore
  private let maximumConcurrentTransfers: Int
  /// recordCompletedItemの永続化を合流させるデバウンス幅。小ファイル大量転送で1件ごとに
  /// store.save(全ジョブのJSONをatomic書き込み)を呼ぶとO(N^2)化するため、この間隔だけ
  /// 書き込みをまとめる。クラッシュで失われるのは直近この間隔分のcompletedItemsのみで、
  /// 失われた項目は次回retryが「未完了」として安全に再転送するだけなので許容する。
  private let itemCompletionPersistDebounce: Duration
  /// 完了間隔がitemCompletionPersistDebounceを切り続ける(=デバウンスが毎回張り直される)
  /// 高頻度の小ファイル転送でも、この間隔ごとには必ず実際にディスクへ書き込む上限。
  /// 無いとpersistが永久に先送りされ、クラッシュ時にcompletedItemsを全損しうる。
  private let maximumPersistDelay: Duration
  private var jobs: [TransferJob]
  private var executions: [UUID: Execution] = [:]
  private var autoRetryPlanners: [UUID: AutoRetryPlanner] = [:]
  /// completedItemsは表示・永続化順を保つArrayを正本とし、重複抑止だけをこの補助Setで
  /// O(1)化する。フォルダ転送のリーフ完了記録では件数がファイル数まで増えるため、
  /// Array.containsによるO(N²)化を避ける。
  private var completedItemSets: [UUID: Set<TransferJob.Item>] = [:]
  private var runningTasks: [UUID: Task<Void, Never>] = [:]
  /// 自動再接続(P1-3) Fix C: cancel()が呼ばれた意図を型判定に頼らず構造的に記録する。
  /// Providerのcopy()実装がキャンセルを正しくCancellationErrorへ写し損ねても、
  /// ここに記録があればfinish時に必ず.cancelledへ確定させ、誤って自動リトライしない。
  private var cancelledJobIDs: Set<UUID> = []
  /// pause()が呼ばれた意図を、Providerが返すエラー型とは独立して記録する。
  /// 実行Taskや自動リトライ待ちがCancellationError以外で終了しても、ここに記録が
  /// あれば必ず.pausedへ確定し、cancelや自動リトライへ誤って流さない。
  private var pausedJobIDs: Set<UUID> = []
  private var continuations: [UUID: AsyncStream<[TransferJob]>.Continuation] = [:]
  private var pendingPersistTask: Task<Void, Never>?
  private var lastPersistAt: ContinuousClock.Instant?

  init(
    store: any TransferJobStore = JSONTransferJobStore(),
    maximumConcurrentTransfers: Int = 2,
    itemCompletionPersistDebounce: Duration = .milliseconds(300),
    maximumPersistDelay: Duration = .seconds(2)
  ) {
    precondition(maximumConcurrentTransfers > 0)
    self.store = store
    self.maximumConcurrentTransfers = maximumConcurrentTransfers
    self.itemCompletionPersistDebounce = itemCompletionPersistDebounce
    self.maximumPersistDelay = maximumPersistDelay
    let loadedJobs = (try? store.load()) ?? []
    let restoredJobs = loadedJobs.map { job in
      var job = job
      if job.state == .running {
        job.state = .interrupted
        job.errorDescription = "アプリの終了により転送が中断されました。最初から再試行してください。"
        job.updatedAt = .now
      }
      return job
    }
    jobs = Self.jobsByTrimmingTerminalHistory(restoredJobs)
    completedItemSets = Dictionary(
      uniqueKeysWithValues: jobs.map { ($0.id, Set($0.completedItems)) })
    try? store.save(jobs)
    lastPersistAt = ContinuousClock().now
  }

  func allJobs() -> [TransferJob] {
    Array(jobs.reversed())
  }

  /// 実行Taskの協調キャンセル完了を待っているジョブIDを返す。永続状態は.runningのまま
  /// 維持しつつ、表示層が一時停止要求を即時にフィードバックするために使う。
  func pauseRequestedJobIDs() -> Set<UUID> {
    pausedJobIDs
  }

  /// 履歴画面から終了済みジョブを1件削除する。実行中・待機中のジョブは、表示層の
  /// 判定に依存せずactor内でも拒否し、転送の実行状態を履歴操作から変更させない。
  @discardableResult
  func removeTerminalJob(_ id: UUID) -> Bool {
    guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state.isTerminal else {
      return false
    }
    jobs.remove(at: index)
    executions[id] = nil
    autoRetryPlanners[id] = nil
    completedItemSets[id] = nil
    cancelledJobIDs.remove(id)
    pausedJobIDs.remove(id)
    persistAndPublish()
    return true
  }

  /// 終了済みジョブだけを一括削除する。queued/runningは必ず残す。
  @discardableResult
  func removeTerminalJobs() -> Int {
    let removedIDs = Set(jobs.lazy.filter(\.state.isTerminal).map(\.id))
    guard !removedIDs.isEmpty else { return 0 }
    jobs.removeAll { removedIDs.contains($0.id) }
    for id in removedIDs {
      executions[id] = nil
      autoRetryPlanners[id] = nil
      completedItemSets[id] = nil
      cancelledJobIDs.remove(id)
      pausedJobIDs.remove(id)
    }
    persistAndPublish()
    return removedIDs.count
  }

  var updateSubscriberCount: Int {
    continuations.count
  }

  func updates() -> AsyncStream<[TransferJob]> {
    let identifier = UUID()
    return AsyncStream { continuation in
      continuations[identifier] = continuation
      continuation.yield(allJobs())
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeContinuation(identifier) }
      }
    }
  }

  func enqueue(
    _ job: TransferJob,
    execution: @escaping Execution,
    autoRetryPlanner: AutoRetryPlanner? = nil
  ) -> TransferJob {
    // Fix C'': terminal状態のジョブへcancel()が呼ばれた場合、runningTasksが存在せず
    // finishが呼ばれないためcancelledJobIDsに記録だけが残る。同じidを積み直す入口で
    // 必ず捨てておかないと、後続の実行が無関係のキャンセル扱いになる。
    cancelledJobIDs.remove(job.id)
    pausedJobIDs.remove(job.id)
    jobs.removeAll { $0.id == job.id }
    completedItemSets[job.id] = Set(job.completedItems)
    jobs.append(job)
    executions[job.id] = execution
    autoRetryPlanners[job.id] = autoRetryPlanner
    persistAndPublish()
    startAvailableJobs()
    return job
  }

  func cancel(_ id: UUID) {
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    if jobs[index].state == .queued || jobs[index].state == .paused {
      jobs[index].state = .cancelled
      jobs[index].updatedAt = .now
      executions[id] = nil
      autoRetryPlanners[id] = nil
      pausedJobIDs.remove(id)
      persistAndPublish()
      return
    }
    // Fix C: 実行がPlain errorで終わってもfinish時に必ず.cancelledへ確定させるための
    // 構造的な記録。runningTasks[id]は「本実行中」だけでなく「自動リトライのバックオフ
    // 待ち」も指すため、どちらの状態でもcancel()一発で正しく止まる(Fix A)。
    pausedJobIDs.remove(id)
    cancelledJobIDs.insert(id)
    runningTasks[id]?.cancel()
  }

  /// 待機中または実行中の転送を一時停止する。実行中の場合は協調キャンセルが完了して
  /// Provider側の後始末が済むまで.runningを維持し、その後.pausedへ確定する。
  func pause(_ id: UUID) {
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    switch jobs[index].state {
    case .queued:
      jobs[index].state = .paused
      jobs[index].updatedAt = .now
      executions[id] = nil
      autoRetryPlanners[id] = nil
      persistAndPublish()
    case .running:
      // cancel操作が先に届いている場合は、一時停止で上書きしない。
      guard !cancelledJobIDs.contains(id) else { return }
      let inserted = pausedJobIDs.insert(id).inserted
      runningTasks[id]?.cancel()
      if inserted {
        // state自体はProviderの後始末が済むまで.runningを維持する。永続化対象ではない
        // pause要求だけを購読者へ知らせ、UIを「停止しています…」へ即時更新する。
        publish()
      }
    case .paused, .completed, .failed, .cancelled, .interrupted:
      return
    }
  }

  /// 一時停止中のジョブを実行待ちの末尾へ戻す。executionは停止前の接続やTaskを
  /// 保持せず、呼び出し元がcompletedItemsを再確認して組み立て直したものだけを受け取る。
  @discardableResult
  func resume(
    _ id: UUID,
    items: [TransferJob.Item]? = nil,
    execution: @escaping Execution,
    autoRetryPlanner: AutoRetryPlanner? = nil
  ) -> Bool {
    guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .paused else {
      return false
    }
    cancelledJobIDs.remove(id)
    pausedJobIDs.remove(id)
    var job = jobs.remove(at: index)
    if let items {
      job.items = items
    }
    job.state = .queued
    job.completedBytes = 0
    job.errorDescription = nil
    job.startedAt = nil
    job.updatedAt = .now
    jobs.append(job)
    executions[id] = execution
    autoRetryPlanners[id] = autoRetryPlanner
    persistAndPublish()
    startAvailableJobs()
    return true
  }

  /// 待機中ジョブを、実行順で1つ前の待機中ジョブと入れ替える。
  /// 実行中・終了済みジョブは順序変更の対象にせず、その間を飛び越えて探索する。
  func moveQueuedJobEarlier(_ jobID: UUID) {
    guard let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].state == .queued,
      let earlierIndex = jobs[..<index].lastIndex(where: { $0.state == .queued })
    else { return }
    jobs.swapAt(index, earlierIndex)
    persistAndPublish()
  }

  /// 待機中ジョブを、実行順で1つ後の待機中ジョブと入れ替える。
  /// 実行中・終了済みジョブは順序変更の対象にせず、その間を飛び越えて探索する。
  func moveQueuedJobLater(_ jobID: UUID) {
    guard let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].state == .queued,
      let laterIndex = jobs[jobs.index(after: index)...].firstIndex(where: { $0.state == .queued })
    else { return }
    jobs.swapAt(index, laterIndex)
    persistAndPublish()
  }

  /// items(nil以外)を渡すと、このretryが実際に処理する対象へjobs[index].itemsを
  /// 差し替える。転送レジューム(P1-2)で、呼び出し元が完了確認済みの項目を除いた
  /// 部分集合を渡せるようにするため(既定nilは従来どおりitemsを変更しない)。
  func retry(
    _ id: UUID,
    items: [TransferJob.Item]? = nil,
    execution: @escaping Execution,
    autoRetryPlanner: AutoRetryPlanner? = nil
  ) {
    guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state.isTerminal else {
      return
    }
    // Fix C'': 同上。手動retryの直前に残存しているかもしれないゴミを必ず捨てる。
    cancelledJobIDs.remove(id)
    pausedJobIDs.remove(id)
    if let items {
      jobs[index].items = items
    }
    jobs[index].state = .queued
    jobs[index].completedBytes = 0
    jobs[index].errorDescription = nil
    jobs[index].startedAt = nil
    jobs[index].updatedAt = .now
    executions[id] = execution
    autoRetryPlanners[id] = autoRetryPlanner
    persistAndPublish()
    startAvailableJobs()
  }

  /// サーバーが予約した実名は送信前に保存する。保存失敗を握りつぶさず送信を止める。
  func recordReservedDestinationName(
    _ name: String, for location: FileLocation, jobID: UUID
  ) throws {
    try Task.checkCancellation()
    guard let jobIndex = jobs.firstIndex(where: { $0.id == jobID }),
      jobs[jobIndex].state == .running,
      let itemIndex = jobs[jobIndex].items.firstIndex(where: { $0.location == location }),
      jobs[jobIndex].destination.appending(pathComponent: name) != nil,
      !name.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 })
    else { throw ProviderFileTransferServiceError.invalidDestination }
    var updated = jobs
    let item = updated[jobIndex].items[itemIndex]
    var options = item.transferOptions
    options.destinationName = name
    options.destinationNameWasReserved = true
    options.replacingExisting = false
    updated[jobIndex].items[itemIndex] = TransferJob.Item(item.fileItem, options: options)
    updated[jobIndex].updatedAt = .now
    try store.save(updated)
    jobs = updated
    lastPersistAt = ContinuousClock().now
    publish()
  }

  /// 転送レジューム(P1-2)用: このジョブでこれまでに検証まで通って完了したitemsを返す。
  /// 呼び出し元(FileBrowserSession.retryLastTransfer)が、destination側の再確認を経て
  /// 安全にスキップできる項目を判定するために使う。currentDestinationが元のjob.destination
  /// と一致する場合のみ返す。中断後にユーザーが宛先ペインを別の場所へ移動してからリトライ
  /// すると、記録済みの完了項目は今回の宛先にとって無意味(たまたま同名同サイズのファイルが
  /// あるだけかもしれない)になるため、不一致なら安全側に倒して空を返す。
  func completedItems(for id: UUID, currentDestination: FileLocation) -> [TransferJob.Item] {
    guard let job = jobs.first(where: { $0.id == id }), job.destination == currentDestination
    else {
      return []
    }
    return job.completedItems
  }

  /// 表示の判定結果を反映し、終了行の表示時間に使う updatedAt は保持する。
  func markLocalSameVolumeMove(_ id: UUID) {
    guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].isLocalSameVolumeMove
    else { return }
    jobs[index].isLocalSameVolumeMove = true
    persistAndPublish()
  }

  /// 並行実行される事前サイズ集計の結果を、遅れて到着した時点でジョブへ反映する。
  /// terminal状態(failed後のretainFailedItemsが再計算したtotalBytesなど)へ
  /// 遅延到着した値が上書きするrace防止のため、実行可能な非終端状態のみ許可する。
  func applyAggregatedTotalBytes(_ id: UUID, totalBytes: Int64?) {
    guard let totalBytes,
      let index = jobs.firstIndex(where: { $0.id == id }),
      !jobs[index].state.isTerminal,
      jobs[index].totalBytes != totalBytes
    else { return }
    jobs[index].totalBytes = totalBytes
    jobs[index].updatedAt = .now
    persistAndPublish()
  }

  private func startAvailableJobs() {
    while runningTasks.count < maximumConcurrentTransfers,
      let index = jobs.firstIndex(where: { $0.state == .queued })
    {
      let job = jobs[index]
      guard let execution = executions[job.id] else {
        jobs[index].state = .interrupted
        jobs[index].errorDescription = "転送元または転送先へ再接続してから再試行してください。"
        jobs[index].updatedAt = .now
        persistAndPublish()
        continue
      }
      jobs[index].state = .running
      jobs[index].startedAt = .now
      jobs[index].updatedAt = .now
      persistAndPublish()
      let queue = self
      runningTasks[job.id] = Task.detached {
        await queue.runJobAttempt(job.id, execution: execution)
      }
    }
  }

  /// 1回分の転送実行(execution)を行い、結果に応じて完了・失敗確定・自動リトライの
  /// いずれかへ振り分ける。
  private func runJobAttempt(_ id: UUID, execution: Execution) async {
    do {
      try await execution(
        { progress in await self.record(progress, for: id) },
        { item in await self.recordCompletedItem(item, for: id) })
      finish(id, state: .completed, errorDescription: nil)
    } catch {
      await handleAttemptFailure(id, error: error)
    }
  }

  /// 自動再接続(P1-3) Fix A: 失敗検知時、まずcancel()由来の構造的キャンセル記録(Fix C)を
  /// 型判定より優先して確認する。次にCancellationError型を確認する。どちらでもなければ
  /// 自動リトライ可否をautoRetryPlannerへ委ねる。自動リトライする場合はfinishを呼ばず
  /// (=stateを.failedにせず.runningのまま維持し)、activity barに新しい状態や文言を
  /// 一切見せない。バックオフ・再試行が尽きて初めてfailedへ確定する。
  private func handleAttemptFailure(_ id: UUID, error: Error) async {
    let recovery =
      (error as? TransferRecoveryDescribing)?.recoveryDescription
      ?? (error as? TransferJobPartialFailure)?.recoveryDescription
    if pausedJobIDs.remove(id) != nil {
      finishPaused(id, errorDescription: recovery)
      return
    }
    if cancelledJobIDs.remove(id) != nil {
      finish(
        id, state: .cancelled,
        errorDescription: ["転送をキャンセルしました。", recovery].compactMap { $0 }.joined(separator: "\n"))
      return
    }
    if error is CancellationError {
      finish(id, state: .cancelled, errorDescription: "転送をキャンセルしました。")
      return
    }
    let partialFailure = error as? TransferJobPartialFailure
    let isReconnectFutile = partialFailure?.isReconnectFutile ?? false
    var retryPlan: (backoff: Duration, execution: Execution)?
    if !isReconnectFutile, let planner = autoRetryPlanners[id] {
      retryPlan = await planner(isReconnectFutile)
    }
    // plannerは宛先stat並列8+列挙などを伴い秒単位のawait窓を持つ。結果がnilでも、
    // サスペンション中に届いたpause/cancelの構造的記録を必ず状態確定へ反映する。
    if pausedJobIDs.remove(id) != nil {
      finishPaused(id)
      return
    }
    if cancelledJobIDs.remove(id) != nil {
      finish(id, state: .cancelled, errorDescription: "転送をキャンセルしました。")
      return
    }
    if let (backoff, nextExecution) = retryPlan {
      if let failedItems = partialFailure?.failedItems,
        let index = jobs.firstIndex(where: { $0.id == id })
      {
        jobs[index].retainFailedItems(failedItems)
      }
      scheduleAutomaticRetry(id, backoff: backoff, execution: nextExecution)
      return
    }
    finish(
      id,
      state: .failed,
      errorDescription: PKPaneErrorClassifier.classify(error).displayMessage,
      failedItems: partialFailure?.failedItems,
      isReconnectFutile: isReconnectFutile)
  }

  /// 自動再接続(P1-3) Fix A: バックオフ待ちの間もjobのstateを.runningのまま維持し、
  /// runningTasks[id]にバックオフ用のTaskを差し替える。これによりactivity barは
  /// 「進行中」の表示のまま(新しい状態・文言を追加しない)、かつ既存のcancel()が
  /// バックオフ待ちのTaskをそのままキャンセルできる(本実行中のキャンセルと同じ経路)。
  private func scheduleAutomaticRetry(
    _ id: UUID, backoff: Duration, execution: @escaping Execution
  ) {
    // Fix C': 呼び出し元(handleAttemptFailure)でplanner await直後に確認済みだが、
    // actor隔離の外から見た構造的な保証として入口でも独立に再確認する。
    if pausedJobIDs.remove(id) != nil {
      finishPaused(id)
      return
    }
    if cancelledJobIDs.remove(id) != nil {
      finish(id, state: .cancelled, errorDescription: "転送をキャンセルしました。")
      return
    }
    guard jobs.contains(where: { $0.id == id }) else { return }
    let queue = self
    runningTasks[id] = Task.detached {
      do {
        try await Task.sleep(for: backoff)
      } catch {
        await queue.finishAutomaticRetryInterruption(id)
        return
      }
      await queue.runJobAttempt(id, execution: execution)
    }
  }

  private func finishAutomaticRetryInterruption(_ id: UUID) {
    if pausedJobIDs.remove(id) != nil {
      finishPaused(id)
      return
    }
    cancelledJobIDs.remove(id)
    finish(id, state: .cancelled, errorDescription: "転送をキャンセルしました。")
  }

  /// 転送途中のファイルは再開時に先頭から書き直すため、表示進捗も検証済みの完了項目
  /// だけへ補正する。サイズ不明の完了項目は安全側に倒して加算しない。
  private func finishPaused(_ id: UUID, errorDescription: String? = nil) {
    if let index = jobs.firstIndex(where: { $0.id == id }) {
      jobs[index].completedBytes = jobs[index].completedItems.reduce(into: Int64(0)) {
        $0 += $1.totalBytes ?? 0
      }
    }
    finish(id, state: .paused, errorDescription: errorDescription)
  }

  private func record(_ progress: FileTransferProgress, for id: UUID) {
    guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .running else {
      return
    }
    // 間引き報告が順序前後すると完了バイト数が後退しうるため単調増加のみ反映する。
    if progress.completedBytes > jobs[index].completedBytes {
      jobs[index].completedBytes = progress.completedBytes
    }
    jobs[index].totalBytes = progress.totalBytes ?? jobs[index].totalBytes
    jobs[index].updatedAt = .now
    publish()
  }

  private func recordCompletedItem(_ item: TransferJob.Item, for id: UUID) {
    guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .running else {
      return
    }
    var completedItemSet = completedItemSets[id] ?? Set(jobs[index].completedItems)
    guard completedItemSet.insert(item).inserted else { return }
    completedItemSets[id] = completedItemSet
    jobs[index].completedItems.append(item)
    jobs[index].updatedAt = .now
    // メモリ上のジョブ一覧(allJobs/updates)は即座に最新化するが、ディスクへの永続化だけ
    // デバウンスする。ジョブの終了確定(finish)やその他の状態変更は必ずpersistAndPublish
    // (即時)を通るため、デバウンス中に消える可能性があるのは実行中ジョブの直近の
    // completedItems追記分のみ。
    publish()
    schedulePersist()
  }

  private func schedulePersist() {
    // 完了間隔がitemCompletionPersistDebounceを切り続けると、毎回ここでcancel+張り直しに
    // なり永久にflushされない。前回の実書き込みからmaximumPersistDelayを超えていたら、
    // デバウンスを張り直さずここで即座に書き込む上限を設ける。
    let now = ContinuousClock().now
    if let lastPersistAt, now - lastPersistAt >= maximumPersistDelay {
      pendingPersistTask?.cancel()
      pendingPersistTask = nil
      persist()
      return
    }
    pendingPersistTask?.cancel()
    let interval = itemCompletionPersistDebounce
    pendingPersistTask = Task { [weak self] in
      try? await Task.sleep(for: interval)
      guard !Task.isCancelled else { return }
      await self?.flushPendingPersist()
    }
  }

  private func flushPendingPersist() {
    pendingPersistTask = nil
    persist()
  }

  private func finish(
    _ id: UUID,
    state: TransferJob.State,
    errorDescription: String?,
    failedItems: [TransferJob.Item]? = nil,
    isReconnectFutile: Bool = false
  ) {
    runningTasks[id] = nil
    executions[id] = nil
    autoRetryPlanners[id] = nil
    cancelledJobIDs.remove(id)
    pausedJobIDs.remove(id)
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    if let failedItems {
      jobs[index].retainFailedItems(failedItems)
    }
    // ジョブが完全に完了したら、以後retryされることはないためレジューム記録は不要。
    if state == .completed {
      jobs[index].completedItems = []
      completedItemSets[id] = nil
    }
    jobs[index].state = state
    jobs[index].errorDescription = errorDescription
    jobs[index].isReconnectFutile = isReconnectFutile
    jobs[index].updatedAt = .now
    persistAndPublish()
    startAvailableJobs()
  }

  private func removeContinuation(_ id: UUID) {
    continuations[id] = nil
  }

  private func persistAndPublish() {
    // これから最新状態を即時書き込むため、合流待ちの古いデバウンス書き込みは不要になる。
    pendingPersistTask?.cancel()
    pendingPersistTask = nil
    persist()
    publish()
  }

  private func persist() {
    trimPersistedHistoryIfNeeded()
    do {
      try store.save(jobs)
    } catch {
      // 転送は継続し、次の状態更新時に保存を再試行する。
    }
    lastPersistAt = ContinuousClock().now
  }

  private func trimPersistedHistoryIfNeeded() {
    let retainedJobs = Self.jobsByTrimmingTerminalHistory(jobs)
    guard retainedJobs.count < jobs.count else { return }
    let retainedIDs = Set(retainedJobs.map(\.id))
    let removedIDs = Set(jobs.lazy.map(\.id).filter { !retainedIDs.contains($0) })
    jobs = retainedJobs
    for id in removedIDs {
      executions[id] = nil
      autoRetryPlanners[id] = nil
      completedItemSets[id] = nil
      cancelledJobIDs.remove(id)
      pausedJobIDs.remove(id)
    }
  }

  nonisolated private static func jobsByTrimmingTerminalHistory(
    _ jobs: [TransferJob]
  ) -> [TransferJob] {
    let candidates = jobs.indices.filter { index in
      switch jobs[index].state {
      case .completed, .failed, .cancelled: true
      case .queued, .running, .paused, .interrupted: false
      }
    }
    guard candidates.count > TransferJobHistoryPolicy.terminalLimit else { return jobs }
    let retainedIDs = Set(
      candidates.sorted { left, right in
        if jobs[left].updatedAt != jobs[right].updatedAt {
          return jobs[left].updatedAt > jobs[right].updatedAt
        }
        return left > right
      }
      .prefix(TransferJobHistoryPolicy.terminalLimit)
      .map { jobs[$0].id })
    return jobs.filter { job in
      switch job.state {
      case .completed, .failed, .cancelled:
        retainedIDs.contains(job.id)
      case .queued, .running, .paused, .interrupted:
        true
      }
    }
  }

  private func publish() {
    let snapshot = allJobs()
    for continuation in continuations.values {
      continuation.yield(snapshot)
    }
  }
}
