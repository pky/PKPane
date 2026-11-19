import Foundation
import Testing

@testable import PKPane

@MainActor
struct NASConnectionFormModelTests {
  @Test("接続テストが成功すると応答時間を表示する")
  func testConnectionShowsResponseTimeOnSuccess() async throws {
    let probe = RecordingNASReachabilityProbe(outcome: .success)
    let model = NASConnectionFormModel(reachabilityProbe: probe)
    model.host = "smb://nas.example.local/Documents"

    model.testConnection()
    await waitForConnectionTest(model)

    let testResultMessage = try #require(model.testResultMessage)
    #expect(testResultMessage.hasPrefix("応答 "))
    #expect(testResultMessage.hasSuffix("ms"))
    #expect(model.errorMessage == nil)
    #expect(!model.isTestingConnection)
    #expect(probe.recordedHost == "nas.example.local")
    #expect(probe.recordedPort == 445)
  }

  @Test("接続テストが失敗するとエラー分類器の文言を表示する")
  func testConnectionShowsClassifiedGuidanceOnFailure() async throws {
    let probe = RecordingNASReachabilityProbe(
      outcome: .failure(ConnectionReachabilityError.timedOut))
    let model = NASConnectionFormModel(reachabilityProbe: probe)
    model.host = "nas.example.local"

    model.testConnection()
    await waitForConnectionTest(model)

    #expect(
      model.errorMessage
        == ConnectionErrorClassifier.guidanceMessage(for: ConnectionReachabilityError.timedOut))
    #expect(model.testResultMessage == nil)
    #expect(!model.isTestingConnection)
  }

  @Test("サーバー欄が空なら接続テストを実行しない")
  func testConnectionSkipsWhenHostIsEmpty() {
    let probe = RecordingNASReachabilityProbe(outcome: .success)
    let model = NASConnectionFormModel(reachabilityProbe: probe)

    model.testConnection()

    #expect(model.errorMessage == SMBShareError.invalidHost.localizedDescription)
    #expect(model.testResultMessage == nil)
    #expect(!model.isTestingConnection)
    #expect(probe.recordedHost == nil)
  }

  private func waitForConnectionTest(_ model: NASConnectionFormModel) async {
    await waitUntil("接続テストが期限内に完了しなかった") {
      !model.isTestingConnection
    }
  }
  @Test("有効な入力からNAS接続先を作る")
  func makesProfile() {
    let model = NASConnectionFormModel()
    model.displayName = "開発用NAS"
    model.host = "nas.example.local"
    model.shareName = "Documents"

    #expect(model.makeProfile()?.displayName == "開発用NAS")
    #expect(model.errorMessage == nil)
  }

  @Test("不正な入力ではNAS接続先を作らない")
  func rejectsInvalidProfile() {
    let model = NASConnectionFormModel()
    #expect(model.makeProfile() == nil)
    #expect(model.errorMessage == NASConnectionProfileError.invalidDisplayName.errorDescription)
  }

  @Test("サーバー欄のURL形式入力を分解して接続先を作る")
  func acceptsURLStyleServerInput() {
    let model = NASConnectionFormModel()
    model.host = "smb://nas.example/tester"

    let profile = model.makeProfile()

    #expect(profile?.host == "nas.example")
    #expect(profile?.shareName == "tester")
    #expect(profile?.displayName == "tester")
    #expect(model.errorMessage == nil)
    #expect(model.host == "nas.example")
    #expect(model.shareName == "tester")
  }

  @Test("資格情報付きURLはホストから利用者名を取り除く")
  func stripsCredentialsFromURLStyleInput() {
    let model = NASConnectionFormModel()
    model.host = "smb://tester@nas.example.local/Documents/sub"

    let profile = model.makeProfile()

    #expect(profile?.host == "nas.example.local")
    #expect(profile?.shareName == "Documents")
  }

  @Test("明示入力された共有名と接続名はURLの分解結果より優先する")
  func explicitFieldsWinOverParsedInput() {
    let model = NASConnectionFormModel()
    model.displayName = "自宅NAS"
    model.host = "smb://nas.example.local/Media"
    model.shareName = "Documents"

    let profile = model.makeProfile()

    #expect(profile?.displayName == "自宅NAS")
    #expect(profile?.shareName == "Documents")
    #expect(profile?.host == "nas.example.local")
  }

  @Test("ホストだけの入力では接続時に共有を選ぶサーバー接続先を作る")
  func acceptsServerWithoutShareName() {
    let model = NASConnectionFormModel()
    model.host = "nas.example.local"

    let profile = model.makeProfile()

    #expect(profile?.host == "nas.example.local")
    #expect(profile?.shareName == "")
    #expect(profile?.displayName == "nas.example.local")
    #expect(model.errorMessage == nil)
  }

  @Test("既存のNAS接続先を同じ識別子のまま編集する")
  func updatesExistingProfile() throws {
    let profile = try NASConnectionProfile(
      displayName: "開発用NAS", host: "nas.example.local", shareName: "Documents")
    let model = NASConnectionFormModel(profile: profile)
    model.displayName = "設計用NAS"
    model.shareName = "Projects"

    let updatedProfile = model.makeProfile()

    #expect(updatedProfile?.id == profile.id)
    #expect(updatedProfile?.displayName == "設計用NAS")
    #expect(updatedProfile?.shareName == "Projects")
  }
}

/// フェイクのTCP到達性プローブ。実ネットワークへ依存せず成功/失敗/計測値を検証するため、
/// 呼び出し引数を記録しつつ指定した結果を返す。
private final class RecordingNASReachabilityProbe: NASReachabilityProbing, @unchecked Sendable {
  enum Outcome {
    case success
    case failure(Error)
  }

  private let outcome: Outcome
  private let lock = NSLock()
  private var _recordedHost: String?
  private var _recordedPort: UInt16?

  var recordedHost: String? {
    lock.withLock { _recordedHost }
  }

  var recordedPort: UInt16? {
    lock.withLock { _recordedPort }
  }

  init(outcome: Outcome) {
    self.outcome = outcome
  }

  func probe(host: String, port: UInt16, timeout _: Duration) async throws {
    lock.withLock {
      _recordedHost = host
      _recordedPort = port
    }
    switch outcome {
    case .success:
      return
    case .failure(let error):
      throw error
    }
  }
}
