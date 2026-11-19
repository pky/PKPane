import Observation
import SwiftUI

enum TransferLogFilter: String, CaseIterable, Identifiable {
  case all
  case completed
  case failed
  case cancelled
  case active

  var id: Self { self }

  var displayName: String {
    switch self {
    case .all: "すべて"
    case .completed: "完了"
    case .failed: "失敗"
    case .cancelled: "転送状態:キャンセル"
    case .active: "実行中・待機・一時停止"
    }
  }

  func includes(_ state: TransferJob.State) -> Bool {
    switch self {
    case .all:
      true
    case .completed:
      state == .completed
    case .failed:
      state == .failed || state == .interrupted
    case .cancelled:
      state == .cancelled
    case .active:
      state == .running || state == .queued || state == .paused
    }
  }
}

enum TransferLogProjection {
  static let maximumVisibleJobCount = 1_000

  struct Snapshot {
    let displayedJobs: [TransferJob]
    let hasTerminalJobs: Bool
    let isDisplayLimited: Bool

    static let empty = Self(
      displayedJobs: [], hasTerminalJobs: false, isDisplayLimited: false)
  }

  static func makeSnapshot(
    _ jobs: [TransferJob],
    filter: TransferLogFilter
  ) -> Snapshot {
    var matchingJobs: [TransferJob] = []
    matchingJobs.reserveCapacity(min(jobs.count, maximumVisibleJobCount + 1))
    var hasTerminalJobs = false
    for job in jobs {
      hasTerminalJobs = hasTerminalJobs || job.state.isTerminal
      if filter.includes(job.state) {
        matchingJobs.append(job)
      }
    }
    let isDisplayLimited = matchingJobs.count > maximumVisibleJobCount
    matchingJobs.sort { lhs, rhs in
      if lhs.createdAt == rhs.createdAt {
        return lhs.id.uuidString > rhs.id.uuidString
      }
      return lhs.createdAt > rhs.createdAt
    }
    return Snapshot(
      displayedJobs: Array(matchingJobs.prefix(maximumVisibleJobCount)),
      hasTerminalJobs: hasTerminalJobs,
      isDisplayLimited: isDisplayLimited)
  }
}

protocol TransferLogJobSource: Sendable {
  func transferLogUpdates() async -> AsyncStream<[TransferJob]>
  func transferLogPauseRequestedJobIDs() async -> Set<UUID>
}

extension TransferLogJobSource {
  func transferLogPauseRequestedJobIDs() async -> Set<UUID> { [] }
}

extension TransferQueue: TransferLogJobSource {
  func transferLogUpdates() async -> AsyncStream<[TransferJob]> {
    updates()
  }

  func transferLogPauseRequestedJobIDs() async -> Set<UUID> {
    pauseRequestedJobIDs()
  }
}

/// メニューからシート表示までの到達状態。表示要求と履歴モデルを同じオブジェクトに置き、
/// 実経路テストがメニュー操作後のモデル操作まで追えるようにする。
@Observable
@MainActor
final class TransferLogPresentationState {
  private(set) var isPresented = false
  let model: TransferLogModel

  init(model: TransferLogModel = TransferLogModel()) {
    self.model = model
  }

  func present() {
    model.startObserving()
    isPresented = true
  }

  func dismiss() {
    isPresented = false
    model.stopObserving()
  }
}

/// TransferQueueの全履歴を購読し、一覧投影と既存操作入口への委譲だけを担当する。
/// 転送の実行・レジューム・検証処理はこの型に持たせない。
@Observable
@MainActor
final class TransferLogModel {
  var filter: TransferLogFilter = .all {
    didSet {
      guard filter != oldValue else { return }
      scheduleProjection()
    }
  }
  private(set) var displayedJobs: [TransferJob] = []
  private(set) var hasTerminalJobs = false
  private(set) var isDisplayLimited = false
  private(set) var projectionComputationCount = 0
  private(set) var isConfirmingRemoveAllTerminalJobs = false
  private var pauseRequestedJobIDs: Set<UUID> = []
  private var resumingJobIDs: Set<UUID> = []

  private let transferQueue: TransferQueue
  private let jobSource: any TransferLogJobSource
  private let projectionThrottle: Duration
  @ObservationIgnored private var retryHandler: (TransferJob) -> Void
  @ObservationIgnored private let pauseHandler: (UUID) -> Void
  @ObservationIgnored private var resumeHandler: (TransferJob) -> Bool
  @ObservationIgnored private let cancelHandler: (UUID) -> Void
  @ObservationIgnored private let removeAllTerminalJobsHandler: () -> Void
  @ObservationIgnored private var updateTask: Task<Void, Never>?
  @ObservationIgnored private var projectionTask: Task<Void, Never>?
  @ObservationIgnored private var latestJobs: [TransferJob]?
  @ObservationIgnored private var lastProjectionAt: ContinuousClock.Instant?
  @ObservationIgnored private let projectionClock = ContinuousClock()
  @ObservationIgnored private var observationGeneration = 0

  init(
    transferQueue: TransferQueue = .shared,
    jobSource: (any TransferLogJobSource)? = nil,
    projectionThrottle: Duration = .milliseconds(200),
    retry: @escaping (TransferJob) -> Void = { _ in },
    pause: ((UUID) -> Void)? = nil,
    resume: @escaping (TransferJob) -> Bool = { _ in false },
    cancel: ((UUID) -> Void)? = nil,
    removeAllTerminalJobs: (() -> Void)? = nil
  ) {
    self.transferQueue = transferQueue
    self.jobSource = jobSource ?? transferQueue
    self.projectionThrottle = projectionThrottle
    retryHandler = retry
    pauseHandler =
      pause ?? { jobID in
        Task { await transferQueue.pause(jobID) }
      }
    resumeHandler = resume
    cancelHandler =
      cancel ?? { jobID in
        Task { await transferQueue.cancel(jobID) }
      }
    removeAllTerminalJobsHandler =
      removeAllTerminalJobs ?? {
        Task { await transferQueue.removeTerminalJobs() }
      }
  }

  var isObserving: Bool {
    updateTask != nil
  }

  func startObserving() {
    guard updateTask == nil else { return }
    observationGeneration &+= 1
    let generation = observationGeneration
    let source = jobSource
    updateTask = Task { [weak self] in
      for await jobs in await source.transferLogUpdates() {
        guard !Task.isCancelled, let self,
          generation == observationGeneration
        else { return }
        let pauseRequestedJobIDs = await source.transferLogPauseRequestedJobIDs()
        receive(jobs, pauseRequestedJobIDs: pauseRequestedJobIDs)
      }
    }
  }

  func stopObserving() {
    observationGeneration &+= 1
    updateTask?.cancel()
    updateTask = nil
    projectionTask?.cancel()
    projectionTask = nil
    latestJobs = nil
    pauseRequestedJobIDs.removeAll()
    resumingJobIDs.removeAll()
    lastProjectionAt = nil
    isConfirmingRemoveAllTerminalJobs = false
  }

  func registerRetryHandler(_ handler: @escaping (TransferJob) -> Void) {
    retryHandler = handler
  }

  func registerResumeHandler(_ handler: @escaping (TransferJob) -> Bool) {
    resumeHandler = handler
  }

  func canRetry(_ job: TransferJob) -> Bool {
    switch job.state {
    case .failed, .cancelled, .interrupted: true
    case .queued, .running, .paused, .completed: false
    }
  }

  func retry(_ job: TransferJob) {
    guard canRetry(job) else { return }
    retryHandler(job)
  }

  func canPause(_ job: TransferJob) -> Bool {
    (job.state == .running || job.state == .queued)
      && !pauseRequestedJobIDs.contains(job.id)
  }

  func pause(_ job: TransferJob) {
    guard canPause(job) else { return }
    if job.state == .running {
      pauseRequestedJobIDs.insert(job.id)
    }
    pauseHandler(job.id)
  }

  func isPausing(_ job: TransferJob) -> Bool {
    job.state == .running && pauseRequestedJobIDs.contains(job.id)
  }

  func canResume(_ job: TransferJob) -> Bool {
    job.state == .paused && !resumingJobIDs.contains(job.id)
  }

  func resume(_ job: TransferJob) {
    guard canResume(job) else { return }
    resumingJobIDs.insert(job.id)
    if !resumeHandler(job) {
      resumingJobIDs.remove(job.id)
    }
  }

  func canCancel(_ job: TransferJob) -> Bool {
    job.state == .running || job.state == .queued || job.state == .paused
  }

  func cancel(_ job: TransferJob) {
    guard canCancel(job) else { return }
    cancelHandler(job.id)
  }

  static func stateLabel(_ state: TransferJob.State) -> String {
    switch state {
    case .queued: "待機中"
    case .running: "実行中"
    case .paused: "一時停止中"
    case .completed: "完了"
    case .failed: "失敗"
    case .cancelled: "転送状態:キャンセル"
    case .interrupted: "中断"
    }
  }

  func stateLabel(_ job: TransferJob) -> String {
    isPausing(job) ? "停止しています…" : Self.stateLabel(job.state)
  }

  func remove(_ job: TransferJob) {
    guard job.state.isTerminal else { return }
    Task { [transferQueue] in
      await transferQueue.removeTerminalJob(job.id)
    }
  }

  func requestRemoveAllTerminalJobs() {
    guard hasTerminalJobs else { return }
    isConfirmingRemoveAllTerminalJobs = true
  }

  func cancelRemoveAllTerminalJobs() {
    isConfirmingRemoveAllTerminalJobs = false
  }

  func confirmRemoveAllTerminalJobs() {
    guard isConfirmingRemoveAllTerminalJobs else { return }
    isConfirmingRemoveAllTerminalJobs = false
    removeAllTerminalJobsHandler()
  }

  private func receive(_ jobs: [TransferJob], pauseRequestedJobIDs requestedIDs: Set<UUID>) {
    latestJobs = jobs
    let runningIDs = Set(jobs.lazy.filter { $0.state == .running }.map(\.id))
    pauseRequestedJobIDs.formIntersection(runningIDs)
    pauseRequestedJobIDs.formUnion(requestedIDs.intersection(runningIDs))
    let pausedIDs = Set(jobs.lazy.filter { $0.state == .paused }.map(\.id))
    resumingJobIDs.formIntersection(pausedIDs)
    scheduleProjection()
  }

  /// 高頻度の進捗publishを1つの最新スナップショットへ合流させる。検索結果の
  /// スナップショット発行と同様、待機中はTaskを張り直さず末尾の値だけを更新する。
  /// 直近の投影からスロットル間隔が空いている場合は先頭即時適用する(表示直後や
  /// フィルタ切替の初回反映がスロットル分だけ空白にならないように)。
  private func scheduleProjection() {
    guard isObserving, let jobs = latestJobs, projectionTask == nil else { return }
    let elapsedSinceLastProjection = lastProjectionAt.map { projectionClock.now - $0 }
    if elapsedSinceLastProjection.map({ $0 >= projectionThrottle }) ?? true {
      applyProjection(to: jobs)
      return
    }
    let generation = observationGeneration
    let throttle = projectionThrottle
    projectionTask = Task { [weak self] in
      do {
        try await Task.sleep(for: throttle)
      } catch {
        return
      }
      guard let self, generation == observationGeneration, isObserving,
        let latestJobs
      else { return }
      projectionTask = nil
      applyProjection(to: latestJobs)
    }
  }

  private func applyProjection(to jobs: [TransferJob]) {
    let snapshot = TransferLogProjection.makeSnapshot(jobs, filter: filter)
    displayedJobs = snapshot.displayedJobs
    hasTerminalJobs = snapshot.hasTerminalJobs
    isDisplayLimited = snapshot.isDisplayLimited
    lastProjectionAt = projectionClock.now
    projectionComputationCount += 1
  }
}

struct TransferLogView: View {
  @Bindable var model: TransferLogModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      filterPicker
      jobTable
      footer
    }
    .padding(16)
    .frame(minWidth: 1_100, minHeight: 520)
    .alert(
      "終了済みの転送履歴をすべて消去しますか？",
      isPresented: Binding(
        get: { model.isConfirmingRemoveAllTerminalJobs },
        set: { if !$0 { model.cancelRemoveAllTerminalJobs() } })
    ) {
      Button("すべて消去", role: .destructive) {
        model.confirmRemoveAllTerminalJobs()
      }
      Button("キャンセル", role: .cancel) {
        model.cancelRemoveAllTerminalJobs()
      }
    } message: {
      Text("完了、失敗、キャンセル、中断の履歴が削除されます。この操作は取り消せません。")
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("転送履歴")
        .font(.title2)
        .fontWeight(.semibold)
      Text("コピーと移動の転送ジョブを表示します。削除やリネームなどの操作履歴は対象外です。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var filterPicker: some View {
    Picker("表示", selection: $model.filter) {
      ForEach(TransferLogFilter.allCases) { filter in
        Text(LocalizedStringKey(filter.displayName)).tag(filter)
      }
    }
    .pickerStyle(.segmented)
    .frame(maxWidth: 620)
  }

  private var jobTable: some View {
    Table(model.displayedJobs) {
      TableColumn("種別") { job in
        Text(job.kind == .copy ? "コピー" : "移動")
      }
      .width(min: 60, ideal: 75)
      TableColumn("項目数") { job in
        VStack(alignment: .leading) {
          Text("\(job.items.count)")
            .monospacedDigit()
          if job.skippedItemCount > 0 {
            Text("スキップ \(job.skippedItemCount)件")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .width(min: 90, ideal: 110)
      TableColumn("宛先") { job in
        TransferDestinationNamesCell(job: job, directoryText: destinationText(job.destination))
      }
      .width(min: 150, ideal: 230)
      TableColumn("状態") { job in
        Text(LocalizedStringKey(model.stateLabel(job)))
      }
      .width(min: 70, ideal: 90)
      TableColumn("合計バイト") { job in
        Text(byteCountText(job.totalBytes))
          .monospacedDigit()
      }
      .width(min: 80, ideal: 100)
      TableColumn("開始時刻") { job in
        Text(dateText(job.startedAt))
          .monospacedDigit()
      }
      .width(min: 120, ideal: 145)
      TableColumn("終了時刻") { job in
        Text(job.state.isTerminal ? dateText(job.updatedAt) : "—")
          .monospacedDigit()
      }
      .width(min: 120, ideal: 145)
      TableColumn("エラー概要") { job in
        Text(job.errorDescription ?? "—")
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .width(min: 140, ideal: 220)
      TableColumn("操作") { job in
        HStack(spacing: 8) {
          if model.canRetry(job) {
            Button("再試行") { model.retry(job) }
          }
          if model.canPause(job) {
            Button("一時停止") { model.pause(job) }
          } else if job.state == .running || job.state == .queued {
            Button("一時停止") { model.pause(job) }
              .disabled(true)
          }
          if job.state == .paused {
            Button("再開") { model.resume(job) }
              .disabled(!model.canResume(job))
          }
          if model.canCancel(job) {
            Button("キャンセル") { model.cancel(job) }
          }
          if job.state.isTerminal {
            Button("削除") { model.remove(job) }
          }
        }
      }
      .width(min: 120, ideal: 220)
    }
    .overlay {
      if model.displayedJobs.isEmpty {
        ContentUnavailableView(
          "該当する転送履歴はありません",
          systemImage: "clock.arrow.circlepath")
      }
    }
  }

  private var footer: some View {
    HStack {
      Text(footerText)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      Button("完了済みをすべて消去", role: .destructive) {
        model.requestRemoveAllTerminalJobs()
      }
      .disabled(!model.hasTerminalJobs)
      Button("閉じる") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
    }
  }

  private var footerText: String {
    let countText = "\(model.displayedJobs.count)件"
    return model.isDisplayLimited ? "\(countText)（最新1,000件まで表示）" : countText
  }

  private func destinationText(_ location: FileLocation) -> String {
    SecretMasker.maskForDisplay(location.localURL?.path ?? location.remotePath ?? "—")
  }

  private func byteCountText(_ byteCount: Int64?) -> String {
    guard let byteCount else { return "—" }
    return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
  }

  private func dateText(_ date: Date?) -> String {
    guard let date else { return "—" }
    return date.formatted(date: .numeric, time: .shortened)
  }
}

/// 部分失敗でitemsが絞られても、先に完成した項目の実名を履歴から落とさない。
enum TransferDestinationNamesProjection {
  static func items(for job: TransferJob) -> [TransferJob.Item] {
    var result: [TransferJob.Item] = []
    var indexes: [FileLocation: Int] = [:]
    for group in [job.completedItems, job.items] {
      for item in group {
        if let index = indexes[item.location] {
          result[index] = item
        } else {
          indexes[item.location] = result.count
          result.append(item)
        }
      }
    }
    return result
  }
}

private struct TransferDestinationNamesCell: View {
  let job: TransferJob
  let directoryText: String
  @State private var showsNames = false

  var body: some View {
    VStack(alignment: .leading) {
      Text(directoryText)
        .lineLimit(1)
        .truncationMode(.middle)
      Button("保存名を表示") { showsNames = true }
        .buttonStyle(.borderless)
        .font(.caption)
        .popover(isPresented: $showsNames) {
          // 閉じている通常行では全件の投影も名前文字列の生成も行わない。
          if showsNames {
            TransferDestinationNamesDetail(
              items: TransferDestinationNamesProjection.items(for: job),
              directoryText: directoryText,
              completed: job.state == .completed, close: { showsNames = false })
          }
        }
    }
  }
}

private struct TransferDestinationNamesDetail: View {
  let items: [TransferJob.Item]
  let directoryText: String
  let completed: Bool
  let close: @MainActor () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("保存名").font(.headline)
      Text(directoryText).font(.caption).textSelection(.enabled)
      Text("転送元の名前 → 保存先の名前").font(.caption).foregroundStyle(.secondary)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(items.indices, id: \.self) { index in
            let item = items[index]
            VStack(alignment: .leading, spacing: 4) {
              Text(item.name + " → " + (item.transferOptions.destinationName ?? item.name))
                .textSelection(.enabled)
              if item.transferOptions.destinationNameWasReserved {
                Text("サーバーが予約した実名").font(.caption).foregroundStyle(.secondary)
              } else if !completed {
                Text("予定名（作成結果が不明な場合があります）")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Spacer()
        Button("閉じる", action: close).keyboardShortcut(.cancelAction)
      }
    }
    .padding(16)
    .frame(width: 600, height: 360)
  }
}
