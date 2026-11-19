import Foundation
import Observation

@Observable
@MainActor
final class NASConnectionFormModel {
  private let profileID: NASConnectionProfile.ID
  private let reachabilityProbe: any NASReachabilityProbing
  var displayName = ""
  var host = ""
  var shareName = ""
  private(set) var errorMessage: String?
  private(set) var testResultMessage: String?
  private(set) var isTestingConnection = false
  private var testConnectionTask: Task<Void, Never>?

  init(
    profile: NASConnectionProfile? = nil,
    reachabilityProbe: any NASReachabilityProbing = NWReachabilityProbe()
  ) {
    profileID = profile?.id ?? UUID()
    displayName = profile?.displayName ?? ""
    host = profile?.host ?? ""
    shareName = profile?.shareName ?? ""
    self.reachabilityProbe = reachabilityProbe
  }

  isolated deinit {
    testConnectionTask?.cancel()
  }

  func makeProfile() -> NASConnectionProfile? {
    // Finderの⌘Kに慣れた入力(smb://host/share等のURL形式)も受け付けるため、
    // サーバー欄を分解して不足欄を補完してから検証する。明示入力された共有名・接続名は
    // 常に優先し、空欄のときだけ補完する。
    let parsed = Self.parseServerInput(host)
    let resolvedShareName =
      shareName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? (parsed.shareName ?? shareName) : shareName
    let resolvedDisplayName =
      displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? (parsed.shareName ?? parsed.host) : displayName
    do {
      let profile = try NASConnectionProfile(
        id: profileID,
        displayName: resolvedDisplayName,
        host: parsed.host,
        shareName: resolvedShareName)
      // 補完・分解の結果を欄へ書き戻し、保存内容と画面表示を一致させる。
      displayName = profile.displayName
      host = profile.host
      shareName = profile.shareName
      errorMessage = nil
      return profile
    } catch {
      errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
      return nil
    }
  }

  /// サーバー欄の入力を(ホスト, 共有名?)へ分解する。受け付ける形式:
  /// 「host」「host/share」「smb://host/share」「smb://user@host/share」。
  /// スキームは何であっても除去し、資格情報(user@)はホスト部から取り除く。
  static func parseServerInput(_ rawInput: String) -> (host: String, shareName: String?) {
    var text = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
    if let schemeRange = text.range(of: "://") {
      text = String(text[schemeRange.upperBound...])
    }
    var hostPart = text
    var sharePart: String?
    if let slashIndex = text.firstIndex(of: "/") {
      hostPart = String(text[..<slashIndex])
      let pathComponents = text[text.index(after: slashIndex)...]
        .split(separator: "/", omittingEmptySubsequences: true)
      if let firstComponent = pathComponents.first {
        sharePart = String(firstComponent)
      }
    }
    if let atIndex = hostPart.lastIndex(of: "@") {
      hostPart = String(hostPart[hostPart.index(after: atIndex)...])
    }
    return (hostPart, sharePart)
  }

  /// 入力ホストへのTCP到達性(SMB共有ポート445)を確認し、応答時間を計測して表示する。
  /// マウントは行わない副作用のないテストのため、成功してもプロファイルは保存しない。
  func testConnection() {
    guard !isTestingConnection else { return }
    let resolvedHost = Self.parseServerInput(host).host
    guard !resolvedHost.isEmpty else {
      testResultMessage = nil
      errorMessage = PKPaneErrorClassifier.classify(SMBShareError.invalidHost).displayMessage
      return
    }
    isTestingConnection = true
    testResultMessage = nil
    errorMessage = nil
    let probe = reachabilityProbe
    let start = ContinuousClock.now
    testConnectionTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await probe.probe(host: resolvedHost, port: 445, timeout: .seconds(5))
        if Task.isCancelled { return }
        let elapsed = ContinuousClock.now - start
        errorMessage = nil
        testResultMessage = ConnectionTestResultFormatter.successMessage(elapsed: elapsed)
      } catch {
        if Task.isCancelled { return }
        testResultMessage = nil
        errorMessage = ConnectionErrorClassifier.guidanceMessage(for: error)
      }
      isTestingConnection = false
    }
  }
}
