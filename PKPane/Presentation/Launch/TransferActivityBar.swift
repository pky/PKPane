import SwiftUI

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let seconds = Double(components.seconds)
    let attoseconds = Double(components.attoseconds) / 1e18
    return seconds + attoseconds
  }
}

/// TransferQueueを購読し、実行中・待機中のジョブに加えて終了直後のジョブも
/// しばらく(既定10秒)表示する。終了ジョブはdismiss(_:)で即座に消せる。
@Observable
@MainActor
final class TransferActivityModel {
  static let browserMinimumDisplayDelay: Duration = .seconds(1)

  private(set) var activeJobs: [TransferJob] = []
  let minimumDisplayDelay: Duration
  private let transferQueue: TransferQueue
  private let rateLimiter: TransferRateLimiter
  private let preferencesStore: TransferPreferencesStore
  private let recentTerminalDuration: Duration
  @ObservationIgnored private let isQuietJob: @MainActor (TransferJob) -> Bool
  @ObservationIgnored private let resumeHandler: @MainActor (TransferJob) -> Bool
  private var pauseRequestedJobIDs: Set<UUID> = []
  private var resumingJobIDs: Set<UUID> = []
  private var dismissedJobIDs: Set<UUID> = []
  private var scheduledExpiryJobIDs: Set<UUID> = []
  @ObservationIgnored private var updateTask: Task<Void, Never>?
  @ObservationIgnored private var quietJobsByID: [UUID: Bool] = [:]
  @ObservationIgnored private var latestSnapshot:
    (jobs: [TransferJob], pauseRequestedIDs: Set<UUID>) =
      ([], [])
  @ObservationIgnored private var displayReevaluation: (date: Date, task: Task<Void, Never>)?

  init(
    transferQueue: TransferQueue = .shared,
    recentTerminalDuration: Duration = .seconds(10),
    rateLimiter: TransferRateLimiter = .shared,
    preferencesStore: TransferPreferencesStore = .shared,
    minimumDisplayDelay: Duration = .zero,
    isQuietJob: @escaping @MainActor (TransferJob) -> Bool = { _ in false },
    resume: @escaping @MainActor (TransferJob) -> Bool = { _ in false }
  ) {
    self.transferQueue = transferQueue
    self.recentTerminalDuration = recentTerminalDuration
    self.rateLimiter = rateLimiter
    self.preferencesStore = preferencesStore
    self.minimumDisplayDelay = minimumDisplayDelay
    self.isQuietJob = isQuietJob
    resumeHandler = resume
    updateTask = Task { [weak self, transferQueue] in
      for await jobs in await transferQueue.updates() {
        guard let self else { return }
        let pauseRequestedJobIDs = await transferQueue.pauseRequestedJobIDs()
        self.apply(jobs, pauseRequestedJobIDs: pauseRequestedJobIDs)
      }
    }
  }

  static func forBrowser(
    transferQueue: TransferQueue = .shared,
    rateLimiter: TransferRateLimiter = .shared,
    preferencesStore: TransferPreferencesStore = .shared,
    resume: @escaping @MainActor (TransferJob) -> Bool
  ) -> TransferActivityModel {
    TransferActivityModel(
      transferQueue: transferQueue,
      rateLimiter: rateLimiter,
      preferencesStore: preferencesStore,
      minimumDisplayDelay: browserMinimumDisplayDelay,
      isQuietJob: { $0.isLocalSameVolumeMove },
      resume: resume)
  }

  var bandwidthLimitBytesPerSecond: Int64? {
    preferencesStore.current.bandwidthLimitBytesPerSecond
  }

  func cancel(_ jobID: UUID) {
    Task { [transferQueue] in await transferQueue.cancel(jobID) }
  }

  func pause(_ jobID: UUID) {
    guard let job = activeJobs.first(where: { $0.id == jobID }), canPause(job) else { return }
    if job.state == .running {
      pauseRequestedJobIDs.insert(jobID)
    }
    Task { [transferQueue] in await transferQueue.pause(jobID) }
  }

  func resume(_ job: TransferJob) {
    guard canResume(job) else { return }
    resumingJobIDs.insert(job.id)
    if !resumeHandler(job) {
      resumingJobIDs.remove(job.id)
    }
  }

  func moveQueuedJobEarlier(_ jobID: UUID) {
    Task { [transferQueue] in await transferQueue.moveQueuedJobEarlier(jobID) }
  }

  func moveQueuedJobLater(_ jobID: UUID) {
    Task { [transferQueue] in await transferQueue.moveQueuedJobLater(jobID) }
  }

  func setBandwidthLimitBytesPerSecond(_ value: Int64?) {
    let normalized = TransferBandwidthOptions.normalized(value)
    preferencesStore.save(
      TransferPreferences(bandwidthLimitBytesPerSecond: normalized))
    Task { [rateLimiter] in
      await rateLimiter.setBytesPerSecond(normalized)
    }
  }

  /// 終了ジョブ行を即座に消す。既定の猶予期間(recentTerminalDuration)を待たずに
  /// ユーザーが明示的に閉じた場合に使う。
  func dismiss(_ jobID: UUID) {
    dismissedJobIDs.insert(jobID)
    activeJobs.removeAll { $0.id == jobID }
  }

  /// 失敗・キャンセル・中断のみ再試行対象とする。成功済みジョブは再試行の意味がない。
  func canRetry(_ job: TransferJob) -> Bool {
    switch job.state {
    case .failed, .cancelled, .interrupted: true
    case .queued, .running, .paused, .completed: false
    }
  }

  func canPause(_ job: TransferJob) -> Bool {
    (job.state == .running || job.state == .queued)
      && !pauseRequestedJobIDs.contains(job.id)
  }

  func isPausing(_ job: TransferJob) -> Bool {
    job.state == .running && pauseRequestedJobIDs.contains(job.id)
  }

  func canResume(_ job: TransferJob) -> Bool {
    job.state == .paused && !resumingJobIDs.contains(job.id)
  }

  /// 終了ジョブには猶予期間を適用し、表示待ちのジョブがあれば最も早い時刻に再評価する。
  private func apply(_ jobs: [TransferJob], pauseRequestedJobIDs requestedIDs: Set<UUID>) {
    latestSnapshot = (jobs, requestedIDs)
    let now = Date.now
    let delay = minimumDisplayDelay.timeInterval
    let terminalDuration = recentTerminalDuration.timeInterval
    var nextDisplayAt: Date?
    let visibleJobs = jobs.filter { job in
      guard !dismissedJobIDs.contains(job.id) else { return false }
      if job.state.isTerminal {
        guard now.timeIntervalSince(job.updatedAt) < terminalDuration else { return false }
        if job.state != .completed { return true }
      }
      guard !isQuiet(job) else { return false }
      if job.state == .completed {
        return job.updatedAt.timeIntervalSince(job.createdAt) >= delay
      }
      if delay <= 0 { return true }
      let displayAt = job.createdAt.addingTimeInterval(delay)
      if displayAt <= now { return true }
      nextDisplayAt = min(nextDisplayAt ?? displayAt, displayAt)
      return false
    }
    activeJobs = Self.displayOrdered(visibleJobs)
    let runningIDs = Set(jobs.lazy.filter { $0.state == .running }.map(\.id))
    pauseRequestedJobIDs.formIntersection(runningIDs)
    pauseRequestedJobIDs.formUnion(requestedIDs.intersection(runningIDs))
    let pausedIDs = Set(jobs.lazy.filter { $0.state == .paused }.map(\.id))
    resumingJobIDs.formIntersection(pausedIDs)
    // 自動消去は実際に表示しているジョブにだけ予約する(古い履歴分まで予約しない)。
    for job in activeJobs where job.state.isTerminal {
      scheduleAutoDismissIfNeeded(for: job)
    }
    scheduleDisplayReevaluation(at: nextDisplayAt)
  }

  private func isQuiet(_ job: TransferJob) -> Bool {
    if let wasQuiet = quietJobsByID[job.id] { return wasQuiet }
    let quiet = isQuietJob(job)
    quietJobsByID[job.id] = quiet
    return quiet
  }

  private func scheduleDisplayReevaluation(at date: Date?) {
    guard displayReevaluation?.date != date else { return }
    displayReevaluation?.task.cancel()
    displayReevaluation = nil
    guard let date else { return }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(date.timeIntervalSinceNow))
    let task = Task { [weak self] in
      try? await clock.sleep(until: deadline)
      guard !Task.isCancelled, let self else { return }
      self.displayReevaluation = nil
      self.apply(
        self.latestSnapshot.jobs, pauseRequestedJobIDs: self.latestSnapshot.pauseRequestedIDs)
    }
    displayReevaluation = (date, task)
  }

  /// TransferQueueの新しい順スナップショットを、操作と一致する表示順へ並べ替える。
  /// 待機中だけは内部の実行順が逆向きなので反転し、終了ジョブは更新日時の新しい順にする。
  static func displayOrdered(_ jobs: [TransferJob]) -> [TransferJob] {
    let running = jobs.filter { $0.state == .running }
    let queued = jobs.filter { $0.state == .queued }.reversed()
    let paused = jobs.filter { $0.state == .paused }
    let terminal = jobs.filter(\.state.isTerminal).sorted { $0.updatedAt > $1.updatedAt }
    return running + Array(queued) + paused + terminal
  }

  static func stateLabel(_ state: TransferJob.State) -> String {
    switch state {
    case .queued: "待機中"
    case .running: "転送中"
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

  /// 進捗バーに添える「45% (450 MB / 1.0 GB)」形式のテキスト。totalBytesが不明(nil・0以下)
  /// なフォルダ転送等では、パーセントを出せないため転送済みバイト数のみを返す。
  static func progressText(completedBytes: Int64, totalBytes: Int64?) -> String {
    let completedText = ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)
    guard let totalBytes, totalBytes > 0 else {
      return completedText
    }
    let percent = min(
      max(Int((Double(completedBytes) / Double(totalBytes) * 100).rounded()), 0), 100)
    let totalText = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    return "\(percent)% (\(completedText) / \(totalText))"
  }

  /// 終了直後のジョブを猶予期間後に自動で消す。期限到来時になお同じ終了状態のまま
  /// (updatedAtが変わっていない)場合だけ消す。再試行等でジョブが更新されていれば
  /// 何もしない(古い期限がその後の状態を誤って消してしまうことを防ぐ)。
  private func scheduleAutoDismissIfNeeded(for job: TransferJob) {
    guard !dismissedJobIDs.contains(job.id), !scheduledExpiryJobIDs.contains(job.id) else {
      return
    }
    scheduledExpiryJobIDs.insert(job.id)
    let jobID = job.id
    let updatedAt = job.updatedAt
    let duration = recentTerminalDuration
    Task { [weak self] in
      try? await Task.sleep(for: duration)
      guard let self else { return }
      self.scheduledExpiryJobIDs.remove(jobID)
      guard let current = self.activeJobs.first(where: { $0.id == jobID }),
        current.updatedAt == updatedAt
      else { return }
      self.dismiss(jobID)
    }
  }
}

struct TransferActivityBar: View {
  @Environment(\.themePalette) private var themePalette
  let model: TransferActivityModel
  var onRetry: (TransferJob) -> Void = { _ in }

  var body: some View {
    if !model.activeJobs.isEmpty {
      VStack(spacing: 4) {
        HStack {
          Spacer()
          Menu {
            Picker("帯域制限", selection: bandwidthLimitSelection) {
              ForEach(TransferBandwidthOptions.values, id: \.self) { bytesPerSecond in
                Text(TransferBandwidthOptions.label(for: bytesPerSecond))
                  .tag(bytesPerSecond)
              }
            }
            .pickerStyle(.inline)
          } label: {
            Label("帯域制限", systemImage: "speedometer")
          }
          .menuStyle(.borderlessButton)
        }
        ForEach(model.activeJobs, id: \.id) { job in
          row(for: job)
        }
      }
      .padding(8)
      .background(.bar)
      .accessibilityIdentifier("transfer-activity-bar")
    }
  }

  var bandwidthLimitSelection: Binding<Int64> {
    Binding(
      get: { model.bandwidthLimitBytesPerSecond ?? 0 },
      set: { model.setBandwidthLimitBytesPerSecond($0 == 0 ? nil : $0) })
  }

  @ViewBuilder
  private func row(for job: TransferJob) -> some View {
    HStack(spacing: 12) {
      Text(jobTitle(job))
        .lineLimit(1)
        .truncationMode(.middle)
      if job.state.isTerminal {
        Text(statusText(job))
          .lineLimit(1)
          .foregroundStyle(job.state == .completed ? Color.secondary : themePalette.error)
          .frame(maxWidth: .infinity, alignment: .leading)
        if model.canRetry(job) {
          Button("再試行") { onRetry(job) }
        }
        Button {
          model.dismiss(job.id)
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("閉じる")
      } else {
        VStack(alignment: .leading, spacing: 2) {
          Text(LocalizedStringKey(model.stateLabel(job)))
            .font(.caption)
            .foregroundStyle(.secondary)
          progressView(for: job)
          Text(
            TransferActivityModel.progressText(
              completedBytes: job.completedBytes, totalBytes: job.totalBytes)
          )
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        if job.state == .running, !model.isPausing(job),
          let throughput = job.throughputBytesPerSecond
        {
          Text(
            "\(ByteCountFormatter.string(fromByteCount: Int64(throughput), countStyle: .file))/秒"
          )
          .monospacedDigit()
          .foregroundStyle(.secondary)
        }
        if job.state == .queued {
          Button("先に実行") {
            model.moveQueuedJobEarlier(job.id)
          }
          Button("後に実行") {
            model.moveQueuedJobLater(job.id)
          }
        }
        if job.state == .running || job.state == .queued {
          Button("一時停止") {
            model.pause(job.id)
          }
          .disabled(!model.canPause(job))
        } else if job.state == .paused {
          Button("再開") {
            model.resume(job)
          }
          .disabled(!model.canResume(job))
        }
        Button("転送をキャンセル") {
          model.cancel(job.id)
        }
      }
    }
  }

  @ViewBuilder
  private func progressView(for job: TransferJob) -> some View {
    if let total = job.totalBytes, total > 0 {
      ProgressView(value: Double(job.completedBytes) / Double(total))
    } else {
      ProgressView()
    }
  }

  private func jobTitle(_ job: TransferJob) -> String {
    let head = job.items.first.map { $0.transferOptions.destinationName ?? $0.name } ?? "項目"
    return job.items.count > 1 ? "\(head) ほか\(job.items.count - 1)件" : head
  }

  private func statusText(_ job: TransferJob) -> String {
    switch job.state {
    case .completed:
      "完了"
    case .failed, .interrupted:
      job.errorDescription ?? "転送に失敗しました。"
    case .cancelled:
      "キャンセルしました"
    case .queued, .running, .paused:
      ""
    }
  }
}
