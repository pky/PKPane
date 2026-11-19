@preconcurrency import Citadel
import Foundation
import NIOCore
import Synchronization

struct SFTPDirectoryEntry: Equatable, Sendable {
  let name: String
  let isDirectory: Bool
  let isSymbolicLink: Bool
  let size: Int64?
  let modifiedAt: Date?
  let posixPermissions: Int?

  init(
    name: String,
    isDirectory: Bool,
    isSymbolicLink: Bool = false,
    size: Int64? = nil,
    modifiedAt: Date? = nil,
    posixPermissions: Int? = nil
  ) {
    self.name = name
    self.isDirectory = isDirectory
    self.isSymbolicLink = isSymbolicLink
    self.size = size
    self.modifiedAt = modifiedAt
    self.posixPermissions = posixPermissions
  }
}

protocol SFTPDirectoryListing: Sendable {
  func contents(of remotePath: String) async throws -> [SFTPDirectoryEntry]
}

/// SFTPClientSession.fileSize(at:)の既定実装(列挙フォールバック)専用の経路分解。
/// SFTPFileProvider内のparentPath(of:)/childPathと同じ規則(./は相対、それ以外は絶対)。
private func sftpSplitRemotePath(_ remotePath: String) -> (parent: String, name: String) {
  if remotePath.hasPrefix("./") {
    let components = remotePath.dropFirst(2).split(separator: "/", omittingEmptySubsequences: true)
    guard let name = components.last else { return (".", "") }
    let parentComponents = components.dropLast()
    return (
      parentComponents.isEmpty ? "." : "./" + parentComponents.joined(separator: "/"), String(name)
    )
  }
  let components = remotePath.split(separator: "/", omittingEmptySubsequences: true)
  guard let name = components.last else { return ("/", "") }
  let parentComponents = components.dropLast()
  return (
    parentComponents.isEmpty ? "/" : "/" + parentComponents.joined(separator: "/"), String(name)
  )
}

enum SFTPDirectoryListingError: LocalizedError {
  case directoryNotFound

  var errorDescription: String? {
    switch self {
    case .directoryNotFound:
      "指定されたフォルダが見つかりません。"
    }
  }
}

protocol SFTPClientSession: SFTPDirectoryListing {
  func realPath(of remotePath: String) async throws -> String
  func createDirectory(at remotePath: String) async throws
  func remove(at remotePath: String, isDirectory: Bool) async throws
  func rename(at remotePath: String, to destinationPath: String) async throws
  func copy(
    at remotePath: String,
    to destinationPath: String,
    replacingExisting: Bool
  ) async throws
  func streamFileContents(
    of remotePath: String,
    chunkSize: Int,
    receive: @escaping @Sendable (Data) async throws -> Void
  ) async throws
  func writeFileContents(
    to remotePath: String,
    chunks: AsyncThrowingStream<Data, Error>,
    replacingExisting: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws
  func fileContents(of remotePath: String) async throws -> Data
  func isActive() async -> Bool
  func close() async throws
  /// ストール/キャンセル検知時に、進行中の転送を強制解放するために呼ばれる。
  /// 実体を持つセッションは接続をcloseして待機中のawaitを解放する。テスト用フェイクは空実装でよい。
  func abortActiveTransfers()
  /// 閲覧セッションとは独立した、転送専用のセッションを取得する。実体を持つセッションは
  /// 初回呼び出し時のみ新規接続を張って以後使い回し、既定実装は自分自身を返す
  /// (閲覧・転送を分離しない単純な実装・フェイク向け)。
  func transferSession() async throws -> any SFTPClientSession
  /// transferSession()で取得したセッションでの操作が失敗した際に呼ぶ。実体を持つセッションは
  /// 渡されたセッションが今も自分の保持するものと同一の場合のみキャッシュを破棄してcloseし、
  /// 次回のtransferSession()で作り直させる。既定実装は何もしない。
  func invalidateTransferSession(_ failedSession: any SFTPClientSession) async
  /// 単一エントリの実サイズだけを取得する(SSH_FXP_STAT相当)。転送検証がdestinationの実サイズを
  /// 取得する際に使う軽量経路で、親ディレクトリの全列挙(contents(of:))より安価。
  /// 既定実装は現行の列挙フォールバック(テスト用フェイクを壊さないため)。実体を持つ
  /// セッション(CitadelSFTPClientSession)は単一stat呼び出しで上書きする。
  func fileSize(at remotePath: String) async throws -> Int64?
  func setPosixPermissions(_ permissions: Int, at remotePath: String) async throws
}

extension SFTPClientSession {
  func isActive() async -> Bool { true }

  func realPath(of remotePath: String) async throws -> String { remotePath }

  func fileSize(at remotePath: String) async throws -> Int64? {
    let (parentPath, name) = sftpSplitRemotePath(remotePath)
    let entries = try await contents(of: parentPath)
    return entries.first(where: { $0.name == name })?.size
  }

  func setPosixPermissions(_: Int, at _: String) async throws {
    throw SFTPClientSessionError.permissionsUnavailable
  }

  func abortActiveTransfers() {}

  func transferSession() async throws -> any SFTPClientSession { self }

  func invalidateTransferSession(_: any SFTPClientSession) async {}

  func fileContents(of _: String) async throws -> Data {
    throw SFTPClientSessionError.previewUnavailable
  }

  func copy(at _: String, to _: String, replacingExisting _: Bool) async throws {
    throw SFTPClientSessionError.copyUnavailable
  }

  func streamFileContents(
    of _: String,
    chunkSize _: Int,
    receive _: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    throw SFTPClientSessionError.transferUnavailable
  }

  func writeFileContents(
    to _: String,
    chunks _: AsyncThrowingStream<Data, Error>,
    replacingExisting _: Bool,
    progress _: @escaping @Sendable (Int64) -> Void
  ) async throws {
    throw SFTPClientSessionError.transferUnavailable
  }
}

struct CitadelSFTPClientSession: SFTPClientSession {
  let client: SFTPClient

  func realPath(of remotePath: String) async throws -> String {
    try await client.getRealPath(atPath: remotePath)
  }

  func contents(of remotePath: String) async throws -> [SFTPDirectoryEntry] {
    do {
      let responses = try await client.listDirectory(atPath: remotePath)
      return responses.flatMap(\.components).map(Self.entry)
    } catch let SFTPError.errorStatus(status) where status.errorCode == .noSuchFile {
      throw SFTPDirectoryListingError.directoryNotFound
    }
  }

  /// SSH_FXP_STATによる単一エントリのstat。親ディレクトリを全列挙するcontents(of:)より
  /// 軽量なため、転送検証(TransferSizeVerifier)の実サイズ取得経路として使う。
  func fileSize(at remotePath: String) async throws -> Int64? {
    let attributes = try await client.getAttributes(at: remotePath)
    return attributes.size.flatMap(Int64.init(exactly:))
  }

  func setPosixPermissions(_ permissions: Int, at remotePath: String) async throws {
    var attributes = SFTPFileAttributes()
    attributes.permissions = UInt32(PosixPermissions.normalizedMode(permissions))
    try await client.setAttributes(at: remotePath, to: attributes)
  }

  func close() async throws {
    try await client.close()
  }

  func isActive() async -> Bool {
    client.isActive
  }

  func abortActiveTransfers() {
    let client = client
    Task { try? await client.close() }
  }

  func createDirectory(at remotePath: String) async throws {
    try await client.createDirectory(atPath: remotePath)
  }

  func remove(at remotePath: String, isDirectory: Bool) async throws {
    if isDirectory {
      try await client.rmdir(at: remotePath)
    } else {
      try await client.remove(at: remotePath)
    }
  }

  func rename(at remotePath: String, to destinationPath: String) async throws {
    try await client.rename(at: remotePath, to: destinationPath)
  }

  func copy(
    at remotePath: String,
    to destinationPath: String,
    replacingExisting: Bool
  ) async throws {
    try await client.withFile(filePath: remotePath, flags: .read) { source in
      let destinationOpened = Mutex(false)
      do {
        try await self.client.withFile(
          filePath: destinationPath,
          flags: replacingExisting
            ? [.write, .create, .truncate] : [.write, .create, .forceCreate]
        ) { destination in
          destinationOpened.withLock { $0 = true }
          _ = try await SFTPChunkedTransfer.copy(
            read: { offset, maximumLength in
              let buffer = try await source.read(
                from: offset,
                length: UInt32(maximumLength))
              return Data(buffer.readableBytesView)
            },
            write: { data, offset in
              let buffer = ByteBuffer(bytes: data)
              try await destination.write(buffer, at: offset)
            })
        }
      } catch {
        guard !replacingExisting else { throw error }
        let destinationError = error
        if destinationOpened.withLock({ $0 }) {
          try? await remove(at: destinationPath, isDirectory: false)
          throw destinationError
        }
        let (parentPath, name) = sftpSplitRemotePath(destinationPath)
        if let entries = try? await contents(of: parentPath),
          entries.contains(where: { $0.name == name })
        {
          throw CocoaError(.fileWriteFileExists)
        }
        throw destinationError
      }
    }
  }

  func streamFileContents(
    of remotePath: String,
    chunkSize: Int,
    receive: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    let client = client
    let session = self
    let stallGuard = SFTPStallGuard { [session] in session.abortActiveTransfers() }
    try await stallGuard.run {
      try await client.withFile(filePath: remotePath, flags: .read) { file in
        let fileBox = UncheckedSendableSFTPFileBox(file)
        let reader = SFTPPipelinedReader(chunkSize: chunkSize)
        try await reader.read { offset, length in
          let buffer = try await fileBox.value.read(from: offset, length: UInt32(length))
          // SFTP側の読み取りが完了した時点で進捗とみなす。receive(転送先への書き込み)が
          // 遅いだけでSFTP接続自体は健全なケースを、誤ってストールと判定しないようにするため。
          stallGuard.recordActivity()
          return Data(buffer.readableBytesView)
        } receive: { chunk in
          try await receive(chunk)
        }
      }
    }
  }

  func writeFileContents(
    to remotePath: String,
    chunks: AsyncThrowingStream<Data, Error>,
    replacingExisting: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    let flags: SFTPOpenFileFlags
    if replacingExisting {
      flags = [.write, .create, .truncate]
    } else {
      flags = [.write, .create, .forceCreate]
    }
    let client = client
    let session = self
    let stallGuard = SFTPStallGuard { [session] in session.abortActiveTransfers() }
    try await stallGuard.run {
      try await client.withFile(filePath: remotePath, flags: flags) { file in
        let fileBox = UncheckedSendableSFTPFileBox(file)
        let writer = SFTPPipelinedWriter()
        try await writer.write(chunks: chunks) { data, offset in
          try await fileBox.value.write(ByteBuffer(bytes: data), at: offset)
          stallGuard.recordActivity()
        } progress: { confirmed in
          progress(confirmed)
        }
      }
    }
  }

  func fileContents(of remotePath: String) async throws -> Data {
    let buffer = try await client.withFile(filePath: remotePath, flags: .read) { file in
      try await file.readAll()
    }
    return Data(buffer.readableBytesView)
  }

  static func entry(from component: SFTPPathComponent) -> SFTPDirectoryEntry {
    let fileType = component.attributes.permissions.map { $0 & 0o170000 }
    return SFTPDirectoryEntry(
      name: component.filename,
      isDirectory: fileType == 0o040000,
      isSymbolicLink: fileType == 0o120000,
      size: component.attributes.size.flatMap(Int64.init(exactly:)),
      modifiedAt: component.attributes.accessModificationTime?.modificationTime,
      posixPermissions: component.attributes.permissions.map {
        PosixPermissions.normalizedMode(Int($0))
      })
  }
}

actor SFTPReconnectingSession: SFTPClientSession {
  typealias SessionFactory = @Sendable () async throws -> any SFTPClientSession

  private var session: any SFTPClientSession
  private let reconnect: SessionFactory
  private let maximumReconnects: Int
  private var remainingReconnects: Int
  /// 再接続の試行間バックオフ(自動再接続P1-3、既定1秒/2秒/4秒)。要素数を超える試行回数
  /// では最後の値を使い回す。
  private let backoff: [Duration]
  private let sleep: @Sendable (Duration) async -> Void
  private var isClosed = false
  /// 自動再接続(P1-3) Fix B再修正: remainingReconnectsを使い果たした時点のsessionは
  /// 死んでおり(reconnect()を経ない限り以後どの操作も成功しない)、perform()の通常
  /// 成功経路のリセットには永久に到達できない。そこで時間経過による枠復元を併用する。
  /// これが復元窓の起点。「最後に枠を消費した時刻」、または枠を消費した呼び出しが
  /// 枠切れのまま脱出した場合は「諦めた時刻」(1試行が復元間隔を超える無応答サーバー
  /// では、試行開始時刻のままだと諦めた瞬間に復元窓が既に開いてしまうため)。
  private var lastReconnectBudgetConsumedAt: ContinuousClock.Instant?
  /// 枠を使い果たしてから、実際の接続状態を問わず枠を復元するまでの経過時間(既定60秒)。
  private let reconnectBudgetRecoveryInterval: Duration
  private let now: @Sendable () -> ContinuousClock.Instant

  /// 転送専用セッションの生成中Task。transferSession()の同時呼び出しをこのTaskへ合流させる
  /// ことで、二重に接続を張ってしまい片方が孤児化する競合を防ぐ(生成の開始からTaskへの
  /// 格納までの間にawaitを挟まないため、actorの直列実行により競合の余地がない)。
  private var transferSessionTask: Task<any SFTPClientSession, Error>?
  /// 現在キャッシュ中の転送セッションを識別するID。invalidateTransferSession(_:)が
  /// 「今も自分がキャッシュしている、まさにそのセッション」からの通知かどうかを判定するために
  /// 使う。転送セッションは常に自分自身が生成するSFTPReconnectingSession(参照型)のため、
  /// existentialをAnyObjectへブリッジして安定したIDを得られる。
  private var transferSessionIdentifier: ObjectIdentifier?

  init(
    session: any SFTPClientSession,
    maximumReconnects: Int = 3,
    backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4)],
    reconnectBudgetRecoveryInterval: Duration = .seconds(60),
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
    sleep: @escaping @Sendable (Duration) async -> Void = { duration in
      try? await Task.sleep(for: duration)
    },
    reconnect: @escaping SessionFactory
  ) {
    self.session = session
    self.maximumReconnects = maximumReconnects
    remainingReconnects = maximumReconnects
    self.backoff = backoff
    self.reconnectBudgetRecoveryInterval = reconnectBudgetRecoveryInterval
    self.now = now
    self.sleep = sleep
    self.reconnect = reconnect
  }

  func contents(of remotePath: String) async throws -> [SFTPDirectoryEntry] {
    try await perform { session in
      try await session.contents(of: remotePath)
    }
  }

  func realPath(of remotePath: String) async throws -> String {
    try await perform { session in
      try await session.realPath(of: remotePath)
    }
  }

  func createDirectory(at remotePath: String) async throws {
    try await perform { session in
      try await session.createDirectory(at: remotePath)
    }
  }

  func remove(at remotePath: String, isDirectory: Bool) async throws {
    try await perform { session in
      try await session.remove(at: remotePath, isDirectory: isDirectory)
    }
  }

  func rename(at remotePath: String, to destinationPath: String) async throws {
    try await perform { session in
      try await session.rename(at: remotePath, to: destinationPath)
    }
  }

  func copy(
    at remotePath: String,
    to destinationPath: String,
    replacingExisting: Bool
  ) async throws {
    try await perform { session in
      try await session.copy(
        at: remotePath,
        to: destinationPath,
        replacingExisting: replacingExisting)
    }
  }

  func fileSize(at remotePath: String) async throws -> Int64? {
    try await perform { session in
      try await session.fileSize(at: remotePath)
    }
  }

  func setPosixPermissions(_ permissions: Int, at remotePath: String) async throws {
    try await perform { session in
      try await session.setPosixPermissions(permissions, at: remotePath)
    }
  }

  // streamFileContents/writeFileContentsはperform()の再接続リトライを経由しない。
  // perform()の再試行はoperationをそのまま再実行するため、ストリーム系操作では
  // receive/chunksクロージャに対してチャンクを二重に流してしまい、ダウンロード先の
  // 一時ファイルに内容が重複コピーされる（サイレントなデータ破損）。ストリームは
  // 再生不可能な操作であり、転送単位の再試行はTransferQueue.retryが別途担うため、
  // ここでは現在のセッションへ直接委譲するのみとする。
  func streamFileContents(
    of remotePath: String,
    chunkSize: Int,
    receive: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    try await session.streamFileContents(of: remotePath, chunkSize: chunkSize, receive: receive)
  }

  func writeFileContents(
    to remotePath: String,
    chunks: AsyncThrowingStream<Data, Error>,
    replacingExisting: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    try await session.writeFileContents(
      to: remotePath,
      chunks: chunks,
      replacingExisting: replacingExisting,
      progress: progress)
  }

  func fileContents(of remotePath: String) async throws -> Data {
    try await perform { session in
      try await session.fileContents(of: remotePath)
    }
  }

  func isActive() async -> Bool {
    guard !isClosed else { return false }
    return await session.isActive()
  }

  func close() async throws {
    isClosed = true
    if let transferSessionTask {
      self.transferSessionTask = nil
      transferSessionIdentifier = nil
      if let transferSession = try? await transferSessionTask.value {
        try? await transferSession.close()
      }
    }
    try await session.close()
  }

  /// 閲覧セッションとは別に、reconnectファクトリで独立した接続を新規に張った転送専用
  /// セッションを遅延生成し、以後使い回す。転送側のabort(接続close)は独立した接続にのみ
  /// 及ぶため閲覧セッションを巻き添えにしない。同時に複数呼ばれても生成中のTaskへ合流する
  /// ため接続が二重に張られることはない。
  func transferSession() async throws -> any SFTPClientSession {
    guard !isClosed else { throw SFTPClientSessionError.transferUnavailable }
    if let transferSessionTask {
      return try await transferSessionTask.value
    }
    let reconnect = reconnect
    let task = Task<any SFTPClientSession, Error> {
      let newSession = try await reconnect()
      return SFTPReconnectingSession(
        session: newSession,
        maximumReconnects: maximumReconnects,
        backoff: backoff,
        reconnectBudgetRecoveryInterval: reconnectBudgetRecoveryInterval,
        now: now,
        sleep: sleep,
        reconnect: reconnect)
    }
    transferSessionTask = task
    do {
      let created = try await task.value
      // close()はTaskの完了を待つ前に同期的にisClosedをtrueにしてから転送セッションの
      // closeを試みる。そのため、reconnect()のawait中にclose()が先に走っていた場合、
      // ここでcreatedを受け取った時点で既にisClosedが立っている(close()側は
      // transferSessionTaskをまだ待っているか、待ち終えてcreatedをcloseしている最中)。
      // いずれにせよcreatedは信頼できないため、キャッシュへ登録せずcloseしてから
      // 失敗として返す。
      guard !isClosed else {
        try? await created.close()
        throw SFTPClientSessionError.transferUnavailable
      }
      transferSessionIdentifier = ObjectIdentifier(created as AnyObject)
      return created
    } catch {
      transferSessionTask = nil
      throw error
    }
  }

  /// 渡されたセッションが今もキャッシュ中の転送セッションと同一の場合のみキャッシュを破棄し
  /// closeする。すでに別の呼び出しで作り直された後の古い通知は無視することで、新しい
  /// キャッシュを誤って破棄する競合を避ける。
  func invalidateTransferSession(_ failedSession: any SFTPClientSession) async {
    guard let transferSessionIdentifier,
      transferSessionIdentifier == ObjectIdentifier(failedSession as AnyObject)
    else { return }
    transferSessionTask = nil
    self.transferSessionIdentifier = nil
    try? await failedSession.close()
  }

  private func perform<Result: Sendable>(
    _ operation: @Sendable (any SFTPClientSession) async throws -> Result
  ) async throws -> Result {
    do {
      let result = try await operation(session)
      // 再接続を経ずに素通りで成功した操作もremainingReconnectsをmaximumへ戻す。
      // 通常成功経路はrecoverAndRetryを経由しないため、ここでリセットしないと
      // 過去の切断回数(素の切断が数回続いただけでも)が将来の切断へ持ち越され、
      // 長時間開きっぱなしのセッションが自動再接続を永久に使い果たしてしまう。
      remainingReconnects = maximumReconnects
      return result
    } catch {
      return try await recoverAndRetry(operation, after: error)
    }
  }

  /// 切断由来のエラーだけを、バックオフを挟みながら最大maximumReconnects回まで
  /// 再接続して再試行する(自動再接続P1-3、既定3回・1秒/2秒/4秒)。
  ///
  /// - CancellationError/SFTPTransferStallError: SFTPStallGuardによるキャンセル/
  ///   ストール中断はabortActiveTransfers経由で接続をcloseするためisActive()もfalseを
  ///   返しうる。これを「接続断による失敗」と誤認して再接続・再試行してしまうと、
  ///   キャンセル済みの転送を勝手に継続させたり、応答がないサーバーへの再試行を
  ///   繰り返したりする。呼び出し元の意図した中断をそのまま伝播させる。
  /// - TransferReconnectionPolicy.isEligibleForAutoReconnect(_:)がfalseと判定する
  ///   エラー(資格情報エラー等のReconnectFutileError)も、再接続しても同じ理由で必ず
  ///   失敗するため対象外にする。reconnect()自体がこの種のエラーで失敗した場合(例:
  ///   パスワード未保存)を含む。
  /// - セッションがisActive()==trueなのに操作が失敗した場合(対象が存在しない等):
  ///   接続自体は生きているため、再接続しても同じ理由で必ず失敗する。ここでも
  ///   再接続を試みず即座に伝播する。
  /// - 再接続後の操作が成功した時点でremainingReconnectsをmaximumへ戻す。切断は
  ///   独立した事象であり、過去の切断回数を将来の切断へ持ち越すと、長時間開きっぱなしの
  ///   セッションが素の切断を数回経験しただけで自動再接続を永久に使い果たしてしまうため。
  /// - 枠を使い果たした時点のsessionはreconnect()が返した(が結局失敗した)セッションの
  ///   まま保持され続け、以後どの操作を試みても死んだセッションで永久に失敗する。この
  ///   状態はperform()の通常成功経路のリセットに到達できないため、最後に枠を消費して
  ///   からreconnectBudgetRecoveryInterval(既定60秒)以上経過していれば、実際の
  ///   接続状態を問わず枠を復元してから試す(時間ベース復元)。復元判定は入口の1回だけ
  ///   行い、同じ呼び出し内の長時間失敗では復元しない。復元窓の起点は「最後に枠を
  ///   消費した時刻」だが、枠を消費した呼び出しが枠切れのまま脱出する場合は「諦めた
  ///   時刻」へ記録し直す(lastReconnectBudgetConsumedAtの説明を参照)。
  private func recoverAndRetry<Result: Sendable>(
    _ operation: @Sendable (any SFTPClientSession) async throws -> Result,
    after firstError: Error
  ) async throws -> Result {
    var lastError = firstError
    var consumedBudgetInThisCall = false
    // この呼び出しで枠を消費し、枠切れのまま脱出する場合は、復元窓の起点を「諦めた
    // 時刻」へ記録し直す。試行開始時刻のままだと、1試行が復元間隔を超える無応答
    // サーバーでは諦めた瞬間に復元窓が既に開いており、直後の呼び出しが入口で必ず
    // 満枠復元されてしまう。deferで全脱出経路(枠切れguard、キャンセル・不適格エラー
    // の伝播、isClosed)を覆う。成功経路は直前に満枠へリセットされるため発火せず、
    // 枠を消費していない呼び出しでも更新しない(即時失敗の繰り返しで復元窓が永遠に
    // 先送りされるのを防ぐ)。
    defer {
      if remainingReconnects == 0, consumedBudgetInThisCall {
        lastReconnectBudgetConsumedAt = now()
      }
    }
    if remainingReconnects == 0,
      let lastConsumedAt = lastReconnectBudgetConsumedAt,
      now() - lastConsumedAt >= reconnectBudgetRecoveryInterval
    {
      remainingReconnects = maximumReconnects
    }
    while true {
      if lastError is SFTPTransferStallError
        || !TransferReconnectionPolicy.isEligibleForAutoReconnect(lastError)
      {
        throw lastError
      }
      guard !isClosed, remainingReconnects > 0 else { throw lastError }
      let isSessionActive = await session.isActive()
      guard !isSessionActive else { throw lastError }

      let attemptIndex = maximumReconnects - remainingReconnects
      remainingReconnects -= 1
      lastReconnectBudgetConsumedAt = now()
      consumedBudgetInThisCall = true
      let delay = backoff[min(attemptIndex, backoff.count - 1)]
      await sleep(delay)
      guard !isClosed else { throw lastError }

      do {
        try? await session.close()
        session = try await reconnect()
      } catch {
        lastError = error
        continue
      }
      do {
        let result = try await operation(session)
        remainingReconnects = maximumReconnects
        return result
      } catch {
        lastError = error
        continue
      }
    }
  }
}

private final class SFTPHomeDirectoryResumeBox: Sendable {
  private let continuation: Mutex<CheckedContinuation<String?, Never>?>

  init(_ continuation: CheckedContinuation<String?, Never>) {
    self.continuation = Mutex(continuation)
  }

  func resume(returning value: String?) {
    continuation.withLock { continuation in
      continuation?.resume(returning: value)
      continuation = nil
    }
  }
}

private final class SFTPHomeDirectoryState: Sendable {
  private struct State {
    var resolutionTask: Task<String?, Never>?
    var absolutePath: String?
  }

  private let state = Mutex(State())

  func resolutionTask(
    using session: any SFTPClientSession,
    timeout: Duration
  ) -> Task<String?, Never> {
    state.withLock { state in
      if let task = state.resolutionTask { return task }
      let task = Task<String?, Never> {
        await withCheckedContinuation { continuation in
          let resumeBox = SFTPHomeDirectoryResumeBox(continuation)
          let resolutionTask = Task {
            guard let path = try? await session.realPath(of: "."), path.hasPrefix("/") else {
              resumeBox.resume(returning: nil)
              return
            }
            var normalizedPath = path
            while normalizedPath.count > 1, normalizedPath.hasSuffix("/") {
              normalizedPath.removeLast()
            }
            resumeBox.resume(returning: normalizedPath)
          }
          Task {
            do {
              try await Task.sleep(for: timeout)
            } catch {
              return
            }
            resumeBox.resume(returning: nil)
            resolutionTask.cancel()
          }
        }
      }
      state.resolutionTask = task
      return task
    }
  }

  func store(_ absolutePath: String?) {
    state.withLock { $0.absolutePath = absolutePath }
  }

  var absolutePath: String? {
    state.withLock { $0.absolutePath }
  }
}

struct SFTPFileProvider: Sendable {
  private struct RemovalTarget: Sendable {
    let path: String
    let isDirectory: Bool
  }

  private struct RemovalTraversalEntry: Sendable {
    let path: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let expanded: Bool
  }

  private struct CopyTraversalEntry: Sendable {
    let sourcePath: String
    let destinationPath: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
  }

  private enum CopyAction: Sendable {
    case createDirectory(String)
    case copyFile(source: String, destination: String)
  }

  let target: SFTPConnectionTarget
  let id: FileProviderID
  let connectionID: FileProviderConnectionID?
  let capabilities: FileProviderCapabilities = [
    .read, .write, .rename, .moveWithinProvider, .copyWithinProvider,
    .deletePermanently, .readSymbolicLink,
  ]

  private let session: any SFTPClientSession
  private let previewCache: RemotePreviewCache
  private let homeDirectoryState = SFTPHomeDirectoryState()

  init(
    target: SFTPConnectionTarget,
    directoryListing: any SFTPClientSession,
    previewCache: RemotePreviewCache = .shared
  ) {
    self.target = target
    session = directoryListing
    self.previewCache = previewCache
    let connectionID = Self.connectionID(for: target)
    self.connectionID = connectionID
    id = FileProviderID(rawValue: connectionID.rawValue)
  }

  static func connectionID(for target: SFTPConnectionTarget) -> FileProviderConnectionID {
    FileProviderConnectionID(
      rawValue: "sftp-\(target.host.lowercased()):\(target.port):\(target.username)")
  }

  /// 相対パスの基点であるホームを絶対パスへ一度だけ解決する。
  /// 解決できないサーバーでは従来の相対パス動作を維持する。
  func resolveHomeDirectory(timeout: Duration = .seconds(3)) async {
    let task = homeDirectoryState.resolutionTask(using: session, timeout: timeout)
    homeDirectoryState.store(await task.value)
  }

  /// 転送専用セッションを取得して操作を実行する。操作が失敗した場合、そのセッションが
  /// abort等で使い物にならなくなった可能性があるため無効化し、次回は作り直させる。
  private func withTransferSession<Result: Sendable>(
    _ operation: @Sendable (any SFTPClientSession) async throws -> Result
  ) async throws -> Result {
    let transferSession = try await session.transferSession()
    do {
      return try await operation(transferSession)
    } catch {
      await session.invalidateTransferSession(transferSession)
      throw error
    }
  }

  func contents(of remotePath: String) async throws -> [FileItem] {
    let normalizedPath = normalized(remotePath)
    let entries: [SFTPDirectoryEntry]
    do {
      entries = try await session.contents(of: normalizedPath)
    } catch SFTPDirectoryListingError.directoryNotFound {
      throw SFTPFileProviderError.directoryNotFound(normalizedPath)
    }
    let visibleEntries = entries.filter { $0.name != "." && $0.name != ".." }

    return visibleEntries.map { entry in
      let path = childPath(named: entry.name, in: normalizedPath)
      return FileItem(
        remotePath: path,
        url: url(for: path),
        providerID: id,
        isDirectory: entry.isDirectory,
        isSymbolicLink: entry.isSymbolicLink,
        size: entry.size,
        modifiedAt: entry.modifiedAt,
        posixPermissions: entry.posixPermissions)
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func createDirectory(named name: String, in remotePath: String) async throws {
    try await session.createDirectory(
      at: childPath(named: try validatedName(name), in: normalized(remotePath)))
  }

  func rename(_ item: FileItem, to name: String) async throws {
    guard let sourcePath = item.location.remotePath else {
      throw SFTPFileProviderError.invalidLocation
    }
    let destinationPath = childPath(
      named: try validatedName(name),
      in: parentPath(of: sourcePath))
    try await session.rename(at: sourcePath, to: destinationPath)
  }

  func move(_ item: FileItem, to remotePath: String) async throws {
    guard let sourcePath = item.location.remotePath else { return }
    try await session.rename(
      at: sourcePath,
      to: childPath(named: item.name, in: normalized(remotePath)))
  }

  func copy(_ item: FileItem, to remotePath: String, replacingExisting: Bool) async throws {
    guard let sourcePath = item.location.remotePath else { return }
    let destinationDirectoryPath = normalized(remotePath)
    let destinationPath = childPath(named: item.name, in: destinationDirectoryPath)
    guard item.isDirectory, !item.isSymbolicLink else {
      if replacingExisting {
        // ファイルも同じ実体をtruncateする前に拒否する。既存リンク先も解決する。
        try await validateDirectoryCopyDestination(
          sourcePath: sourcePath,
          destinationDirectoryPath: destinationDirectoryPath,
          destinationPath: destinationPath,
          resolveExistingDestination: true)
      }
      try await session.copy(
        at: sourcePath,
        to: destinationPath,
        replacingExisting: replacingExisting)
      return
    }
    try await validateDirectoryCopyDestination(
      sourcePath: sourcePath,
      destinationDirectoryPath: destinationDirectoryPath,
      destinationPath: destinationPath)
    try await copyDirectoryTree(from: sourcePath, to: destinationPath)
  }

  private func validateDirectoryCopyDestination(
    sourcePath: String,
    destinationDirectoryPath: String,
    destinationPath: String,
    resolveExistingDestination: Bool = false
  ) async throws {
    let normalizedSourcePath = normalized(sourcePath)
    if destinationPath == normalizedSourcePath
      || normalizedSourcePath.hasPrefix("\(destinationPath)/")
      || destinationDirectoryPath == normalizedSourcePath
      || destinationDirectoryPath.hasPrefix("\(normalizedSourcePath)/")
    {
      throw SFTPFileProviderError.invalidLocation
    }

    let resolvedSourcePath = normalized(try await session.realPath(of: sourcePath))
    let resolvedDirectoryPath = normalized(
      try await session.realPath(of: destinationDirectoryPath))
    var resolvedDestinationPath = childPath(
      named: itemName(of: destinationPath),
      in: resolvedDirectoryPath)
    if resolvedDestinationPath == resolvedSourcePath
      || resolvedSourcePath.hasPrefix("\(resolvedDestinationPath)/")
    {
      throw SFTPFileProviderError.invalidLocation
    }
    if resolveExistingDestination {
      let entries = try await session.contents(of: destinationDirectoryPath)
      if entries.contains(where: { $0.name == itemName(of: destinationPath) }) {
        resolvedDestinationPath = normalized(try await session.realPath(of: destinationPath))
      }
    }
    if resolvedDestinationPath == resolvedSourcePath
      || resolvedSourcePath.hasPrefix("\(resolvedDestinationPath)/")
      || resolvedDirectoryPath == resolvedSourcePath
      || resolvedDirectoryPath.hasPrefix("\(resolvedSourcePath)/")
    {
      throw SFTPFileProviderError.invalidLocation
    }
  }

  private func copyDirectoryTree(
    from sourcePath: String,
    to destinationPath: String
  ) async throws {
    let plan = try await makeCopyPlan(from: sourcePath, to: destinationPath)
    var createdRoot = false
    do {
      for (index, action) in plan.enumerated() {
        try Task.checkCancellation()
        switch action {
        case .createDirectory(let path):
          try await session.createDirectory(at: path)
          if index == 0 { createdRoot = true }
        case .copyFile(let source, let destination):
          try await session.copy(at: source, to: destination, replacingExisting: false)
        }
      }
    } catch {
      if createdRoot {
        try? await removeDirectoryTree(at: destinationPath)
      }
      throw error
    }
  }

  private func makeCopyPlan(from sourcePath: String, to destinationPath: String) async throws
    -> [CopyAction]
  {
    var plan: [CopyAction] = []
    var pending = [
      CopyTraversalEntry(
        sourcePath: normalized(sourcePath),
        destinationPath: normalized(destinationPath),
        isDirectory: true,
        isSymbolicLink: false)
    ]
    while let current = pending.popLast() {
      try Task.checkCancellation()
      guard current.isDirectory, !current.isSymbolicLink else {
        plan.append(
          .copyFile(source: current.sourcePath, destination: current.destinationPath))
        continue
      }

      plan.append(.createDirectory(current.destinationPath))
      let entries = try await safeChildEntries(at: current.sourcePath)
      for entry in entries.reversed() {
        pending.append(
          CopyTraversalEntry(
            sourcePath: childPath(named: entry.name, in: current.sourcePath),
            destinationPath: childPath(named: entry.name, in: current.destinationPath),
            isDirectory: entry.isDirectory,
            isSymbolicLink: entry.isSymbolicLink))
      }
    }
    return plan
  }

  private func itemName(of remotePath: String) -> String {
    String(remotePath.split(separator: "/", omittingEmptySubsequences: true).last ?? "")
  }

  private func duplicateName(for name: String, existingNames: Set<String>) -> String {
    let path = name as NSString
    let fileExtension = path.pathExtension
    let baseName = path.deletingPathExtension
    var number = 1
    while true {
      let suffix = number == 1 ? "のコピー" : "のコピー\(number)"
      let candidate =
        fileExtension.isEmpty ? baseName + suffix : baseName + suffix + "." + fileExtension
      if !existingNames.contains(candidate) { return candidate }
      number += 1
    }
  }

  private func copyForDuplicate(_ item: FileItem, to destinationPath: String) async throws {
    guard let sourcePath = item.location.remotePath else {
      throw SFTPFileProviderError.invalidLocation
    }
    guard item.isDirectory, !item.isSymbolicLink else {
      try await session.copy(at: sourcePath, to: destinationPath, replacingExisting: false)
      return
    }
    let destinationDirectoryPath = parentPath(of: destinationPath)
    try await validateDirectoryCopyDestination(
      sourcePath: sourcePath,
      destinationDirectoryPath: destinationDirectoryPath,
      destinationPath: destinationPath)
    try await copyDirectoryTree(from: sourcePath, to: destinationPath)
  }

  private func safeChildEntries(at remotePath: String) async throws -> [SFTPDirectoryEntry] {
    let entries = try await session.contents(of: remotePath)
      .filter { $0.name != "." && $0.name != ".." }
    var childNames = Set<String>()
    for entry in entries {
      guard isSafeRemovalEntryName(entry.name), childNames.insert(entry.name).inserted else {
        throw SFTPFileProviderError.invalidLocation
      }
    }
    return entries
  }

  func delete(_ item: FileItem) async throws {
    guard item.location.providerID == id else {
      throw SFTPFileProviderError.invalidLocation
    }
    throw FileBrowserOperationError.trashUnavailable
  }

  private func permanentlyDeleteItem(_ item: FileItem) async throws {
    guard let remotePath = item.location.remotePath else { return }
    if item.isDirectory, !item.isSymbolicLink {
      try await removeDirectoryTree(at: remotePath)
    } else {
      try Task.checkCancellation()
      try await session.remove(at: remotePath, isDirectory: false)
    }
  }

  /// 削除開始後に不正な列挙名が見つかって部分削除になることを避けるため、対象ツリーを
  /// すべて検証してから、子→親の順で作った計画を実行する。シンボリックリンクは
  /// リンク自身をunlinkし、リンク先は列挙しない。
  private func removeDirectoryTree(at remotePath: String) async throws {
    let removalPlan = try await makeRemovalPlan(at: remotePath)
    for target in removalPlan {
      try Task.checkCancellation()
      try await session.remove(at: target.path, isDirectory: target.isDirectory)
    }
  }

  private func makeRemovalPlan(at remotePath: String) async throws -> [RemovalTarget] {
    let rootPath = normalized(remotePath)
    guard rootPath != "/", rootPath != "." else {
      throw SFTPFileProviderError.invalidLocation
    }

    var plan: [RemovalTarget] = []
    var pending = [
      RemovalTraversalEntry(
        path: rootPath,
        isDirectory: true,
        isSymbolicLink: false,
        expanded: false)
    ]
    while let current = pending.popLast() {
      try Task.checkCancellation()
      if !current.isDirectory || current.isSymbolicLink {
        plan.append(RemovalTarget(path: current.path, isDirectory: false))
        continue
      }
      if current.expanded {
        plan.append(RemovalTarget(path: current.path, isDirectory: true))
        continue
      }

      let entries = try await safeChildEntries(at: current.path)

      pending.append(
        RemovalTraversalEntry(
          path: current.path,
          isDirectory: true,
          isSymbolicLink: false,
          expanded: true))
      for entry in entries.reversed() {
        pending.append(
          RemovalTraversalEntry(
            path: childPath(named: entry.name, in: current.path),
            isDirectory: entry.isDirectory,
            isSymbolicLink: entry.isSymbolicLink,
            expanded: false))
      }
    }
    return plan
  }

  private func isSafeRemovalEntryName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
  }

  private func normalized(_ path: String) -> String {
    guard !path.isEmpty else { return "." }
    var normalizedPath =
      path == "." || path.hasPrefix("./") || path.hasPrefix("/") ? path : "/\(path)"
    while normalizedPath.count > 1, normalizedPath.hasSuffix("/") {
      normalizedPath.removeLast()
    }
    return normalizedPath
  }

  private func childPath(named name: String, in directory: String) -> String {
    switch directory {
    case ".":
      "./\(name)"
    case "/":
      "/\(name)"
    default:
      "\(directory)/\(name)"
    }
  }

  private func parentPath(of remotePath: String) -> String {
    let normalizedPath = normalized(remotePath)
    if normalizedPath.hasPrefix("./") {
      let components = normalizedPath.dropFirst(2).split(
        separator: "/",
        omittingEmptySubsequences: true)
      guard components.count > 1 else { return "." }
      return "./" + components.dropLast().joined(separator: "/")
    }
    let components = normalizedPath.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count > 1 else { return "/" }
    return "/" + components.dropLast().joined(separator: "/")
  }

  private func validatedName(_ name: String) throws -> String {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty,
      normalizedName != ".",
      normalizedName != "..",
      !normalizedName.contains("/")
    else {
      throw SFTPFileProviderError.invalidName
    }
    return normalizedName
  }

  private func url(for remotePath: String) -> URL {
    var components = URLComponents()
    components.scheme = "sftp"
    components.user = target.username
    components.host = target.host
    components.port = target.port
    components.path = remotePath
    return components.url ?? URL(fileURLWithPath: remotePath)
  }
}

extension SFTPFileProvider: FileBrowserDuplicateProvider {
  func duplicate(_ item: FileItem) async throws {
    guard item.location.providerID == id, let sourcePath = item.location.remotePath else {
      throw SFTPFileProviderError.invalidLocation
    }
    let directoryPath = parentPath(of: sourcePath)
    let entries = try await safeChildEntries(at: directoryPath)
    let destinationName = duplicateName(
      for: item.name,
      existingNames: Set(entries.map(\.name)))
    try await copyForDuplicate(
      item,
      to: childPath(named: destinationName, in: directoryPath))
  }
}

extension SFTPFileProvider: FileBrowserPermanentDeleteProvider {
  func permanentlyDelete(_ item: FileItem) async throws {
    guard item.location.providerID == id else {
      throw SFTPFileProviderError.invalidLocation
    }
    try await permanentlyDeleteItem(item)
  }
}

/// 自動再接続(P1-3)はSFTP(直接クライアント)限定のスコープ決定のため、この適合により
/// SFTPが関わる転送だけが対象になる(ローカル/マウント経由NASは対象外のまま)。
extension SFTPFileProvider: AutoReconnectEligibleProvider {}

extension SFTPFileProvider: FileBrowserOperationProvider, FileBrowserPreviewProvider {
  func contents(of location: FileLocation) async throws -> [FileItem] {
    guard location.providerID == id, let remotePath = location.remotePath else {
      throw SFTPFileProviderError.invalidLocation
    }
    return try await contents(of: remotePath)
  }

  func parent(of location: FileLocation) -> FileLocation? {
    guard location.providerID == id,
      let remotePath = location.remotePath,
      remotePath != "/"
    else {
      return nil
    }
    if remotePath == "." {
      guard let homeAbsolutePath = homeDirectoryState.absolutePath else { return nil }
      guard homeAbsolutePath != "/" else { return nil }
      return FileLocation(remotePath: parentPath(of: homeAbsolutePath), providerID: id)
    }
    return FileLocation(remotePath: parentPath(of: remotePath), providerID: id)
  }

  func breadcrumbs(
    for location: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    guard location.providerID == id, let remotePath = location.remotePath else { return [] }
    if remotePath.hasPrefix("/") {
      if let homeAbsolutePath = homeDirectoryState.absolutePath,
        remotePath == homeAbsolutePath
          || (homeAbsolutePath == "/"
            ? remotePath.hasPrefix("/") : remotePath.hasPrefix("\(homeAbsolutePath)/"))
      {
        let suffix = String(remotePath.dropFirst(homeAbsolutePath.count))
          .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relativeBreadcrumbs(relativePath: suffix, homeAbsolutePath: homeAbsolutePath)
      }
      return absoluteBreadcrumbs(for: remotePath)
    }

    let relativePath =
      remotePath == "." ? "" : String(remotePath.dropFirst(remotePath.hasPrefix("./") ? 2 : 0))
    return relativeBreadcrumbs(
      relativePath: relativePath,
      homeAbsolutePath: homeDirectoryState.absolutePath)
  }

  private func absoluteBreadcrumbs(for remotePath: String) -> [FileBrowserBreadcrumb] {
    var path = ""
    var breadcrumbs = [
      FileBrowserBreadcrumb(
        location: FileLocation(remotePath: "/", providerID: id),
        name: "/")
    ]
    for component in remotePath.split(separator: "/", omittingEmptySubsequences: true) {
      path += "/\(component)"
      breadcrumbs.append(
        FileBrowserBreadcrumb(
          location: FileLocation(remotePath: path, providerID: id),
          name: String(component)))
    }
    return breadcrumbs
  }

  private func relativeBreadcrumbs(
    relativePath: String,
    homeAbsolutePath: String?
  ) -> [FileBrowserBreadcrumb] {
    var breadcrumbs: [FileBrowserBreadcrumb]
    if let homeAbsolutePath, homeAbsolutePath != "/" {
      breadcrumbs = absoluteBreadcrumbs(for: parentPath(of: homeAbsolutePath))
    } else {
      breadcrumbs = []
    }
    breadcrumbs.append(
      FileBrowserBreadcrumb(
        location: FileLocation(remotePath: ".", providerID: id),
        name: "ホームディレクトリ"))
    var path = "."
    for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
      path = path == "." ? "./\(component)" : "\(path)/\(component)"
      breadcrumbs.append(
        FileBrowserBreadcrumb(
          location: FileLocation(remotePath: path, providerID: id),
          name: String(component)))
    }
    return breadcrumbs
  }

  func createDirectory(named name: String, in location: FileLocation) async throws {
    guard location.providerID == id, let remotePath = location.remotePath else {
      throw SFTPFileProviderError.invalidLocation
    }
    try await createDirectory(named: name, in: remotePath)
  }

  func previewURL(for item: FileItem) async throws -> URL {
    let (key, remotePath) = try previewCacheKey(for: item)
    do {
      return try await previewCache.cachedURL(for: key, fileName: item.name) { [session] in
        try await session.fileContents(of: remotePath)
      }
    } catch RemotePreviewCacheError.fileTooLarge {
      throw SFTPFileProviderError.previewTooLarge
    }
  }

  func detailThumbnailURL(for item: FileItem) async throws -> URL? {
    let (key, _) = try previewCacheKey(for: item)
    return await previewCache.cachedURLIfPresent(for: key)
  }

  private func previewCacheKey(
    for item: FileItem
  ) throws -> (key: RemotePreviewCache.Key, remotePath: String) {
    guard item.location.providerID == id,
      let remotePath = item.location.remotePath,
      !item.isDirectory
    else {
      throw SFTPFileProviderError.invalidLocation
    }
    if let size = item.size, size > Int64(RemotePreviewCache.maximumFileBytes) {
      throw SFTPFileProviderError.previewTooLarge
    }
    guard let connectionID else {
      throw SFTPFileProviderError.invalidLocation
    }
    return (
      RemotePreviewCache.Key(
        connectionID: connectionID,
        remotePath: remotePath,
        modifiedAt: item.modifiedAt,
        size: item.size),
      remotePath
    )
  }
}

extension SFTPFileProvider: FileBrowserTransferProvider {
  func move(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting: Bool
  ) async throws {
    guard directory.providerID == id,
      let remotePath = directory.remotePath,
      let sourcePath = item.location.remotePath
    else {
      throw SFTPFileProviderError.invalidLocation
    }
    let normalizedPath = normalized(remotePath)
    let normalizedSourcePath = normalized(sourcePath)
    let destinationPath = childPath(named: item.name, in: normalizedPath)
    if destinationPath == normalizedSourcePath {
      return
    }
    let sourceDirectoryPrefix =
      normalizedSourcePath.hasSuffix("/") ? normalizedSourcePath : "\(normalizedSourcePath)/"
    if normalizedPath == normalizedSourcePath
      || normalizedPath.hasPrefix(sourceDirectoryPrefix)
    {
      throw SFTPFileProviderError.invalidLocation
    }
    if !replacingExisting {
      do {
        // v3のRENAMEによる既存拒否を使い、正常時の宛先全列挙を省く。
        try await move(item, to: normalizedPath)
      } catch {
        let renameError = error
        try Task.checkCancellation()
        if renameError is CancellationError { throw renameError }
        // 失敗の分類だけに列挙を使う。列挙自体の失敗で元のエラーを隠さない。
        if let entries = try? await session.contents(of: normalizedPath),
          entries.contains(where: { $0.name == item.name })
        {
          throw CocoaError(.fileWriteFileExists)
        }
        throw renameError
      }
      return
    }
    if replacingExisting {
      let resolvedPaths: (source: String, directory: String)
      do {
        let resolvedSourcePath = try await session.realPath(of: sourcePath)
        let resolvedDirectoryPath = try await session.realPath(of: normalizedPath)
        resolvedPaths = (
          source: normalized(resolvedSourcePath),
          directory: normalized(resolvedDirectoryPath)
        )
      } catch {
        // 実体パスを確認できない場合は宛先を削除せず、サーバーのrename判定へ委ねる。
        try await move(item, to: normalizedPath)
        return
      }

      let resolvedDestinationPath = childPath(
        named: item.name,
        in: resolvedPaths.directory)
      if resolvedDestinationPath == resolvedPaths.source {
        return
      }
      // 宛先フォルダを削除すると移動元まで消える祖先への置換を拒否する。
      if resolvedPaths.source.hasPrefix("\(resolvedDestinationPath)/") {
        throw SFTPFileProviderError.invalidLocation
      }
      let resolvedSourceDirectoryPrefix = "\(resolvedPaths.source)/"
      if resolvedPaths.directory == resolvedPaths.source
        || resolvedPaths.directory.hasPrefix(resolvedSourceDirectoryPrefix)
      {
        throw SFTPFileProviderError.invalidLocation
      }
    }
    if let entries = try? await session.contents(of: normalizedPath),
      let existingItem = entries.first(where: { $0.name == item.name })
    {
      guard replacingExisting else {
        throw CocoaError(.fileWriteFileExists)
      }
      let existingPath = childPath(named: existingItem.name, in: normalizedPath)
      if existingItem.isDirectory, !existingItem.isSymbolicLink {
        try await removeDirectoryTree(at: existingPath)
      } else {
        try Task.checkCancellation()
        try await session.remove(at: existingPath, isDirectory: false)
      }
    }
    // protocol extensionのFileLocation版ではなく、SFTP内部のString版move(_:to:)を呼ぶ。
    try await move(item, to: normalizedPath)
  }

  func copy(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting: Bool
  ) async throws {
    guard directory.providerID == id,
      let remotePath = directory.remotePath
    else {
      throw SFTPFileProviderError.invalidLocation
    }
    let normalizedPath = normalized(remotePath)
    let existingItem = try? await session.contents(of: normalizedPath)
      .first(where: { $0.name == item.name })
    guard item.isDirectory, !item.isSymbolicLink else {
      if !replacingExisting, existingItem != nil {
        throw CocoaError(.fileWriteFileExists)
      }
      try await copy(item, to: remotePath, replacingExisting: replacingExisting)
      return
    }

    guard let sourcePath = item.location.remotePath else {
      throw SFTPFileProviderError.invalidLocation
    }
    let destinationPath = childPath(named: item.name, in: normalizedPath)
    try await validateDirectoryCopyDestination(
      sourcePath: sourcePath,
      destinationDirectoryPath: normalizedPath,
      destinationPath: destinationPath)
    if let existingItem {
      guard replacingExisting else { throw CocoaError(.fileWriteFileExists) }
      if existingItem.isDirectory, !existingItem.isSymbolicLink {
        try await removeDirectoryTree(at: destinationPath)
      } else {
        try Task.checkCancellation()
        try await session.remove(at: destinationPath, isDirectory: false)
      }
    }
    try await copyDirectoryTree(from: sourcePath, to: destinationPath)
  }

  func removeAfterCrossProviderMove(_ item: FileItem) async throws {
    guard item.location.providerID == id else {
      throw SFTPFileProviderError.invalidLocation
    }
    try await permanentlyDeleteItem(item)
  }
}

extension SFTPFileProvider: FileStreamTransferProvider {
  /// このSFTP接続へのアップロード(自身がwriteFileChunksの転送先になる場合)で、
  /// 読み側(source.fileChunks)に使わせるチャンクサイズ。ダウンロード側の
  /// SFTPChunkedTransfer.defaultChunkSizeとは独立している(SFTPFileProvider.fileChunks
  /// 参照)。
  var preferredTransferChunkSize: Int { SFTPChunkedTransfer.uploadChunkSize }

  /// 呼び出し元(転送先が決めた)chunkSizeは無視し、ダウンロード専用の
  /// SFTPChunkedTransfer.defaultChunkSizeでSFTPワイヤを読む。preferredTransferChunkSize
  /// (アップロード用)をそのまま使うとCitadel内部で32,000バイト単位へ再分割され
  /// 往復数が増えるため、SFTP読み出しは常にダウンロード用の最適値に揃える。
  func fileChunks(for item: FileItem, chunkSize _: Int) -> AsyncThrowingStream<Data, Error> {
    let wireChunkSize = SFTPChunkedTransfer.defaultChunkSize
    // 約4MB分をバッファする(チャンクサイズが小さいほど多くの個数を許容する)。
    let limit = max(4, (4 * 1_048_576) / wireChunkSize)
    return BoundedChunkPipe.stream(limit: limit) { yield in
      guard item.location.providerID == id,
        let remotePath = item.location.remotePath
      else {
        throw SFTPFileProviderError.invalidLocation
      }
      try await withTransferSession { transferSession in
        try await transferSession.streamFileContents(of: remotePath, chunkSize: wireChunkSize) {
          chunk in
          try await yield(chunk)
        }
      }
    }
  }

  func writeFileChunks(
    _ chunks: AsyncThrowingStream<Data, Error>,
    to destination: FileLocation,
    replacingExisting: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    guard destination.providerID == id,
      let remotePath = destination.remotePath
    else {
      throw SFTPFileProviderError.invalidLocation
    }
    try await withTransferSession { transferSession in
      try await transferSession.writeFileContents(
        to: remotePath,
        chunks: chunks,
        replacingExisting: replacingExisting,
        progress: progress)
    }
  }
}

extension SFTPFileProvider: FileTransferCommitProvider {
  func commitTransferFile(
    from temporaryLocation: FileLocation,
    to destination: FileLocation,
    replacingExisting: Bool
  ) async throws {
    guard temporaryLocation.providerID == id,
      destination.providerID == id,
      let temporaryPath = temporaryLocation.remotePath,
      let destinationPath = destination.remotePath
    else {
      throw SFTPFileProviderError.invalidLocation
    }
    try Task.checkCancellation()
    guard normalized(temporaryPath) != normalized(destinationPath),
      let parent = destination.deletingLastPathComponent(),
      let parentPath = parent.remotePath
    else {
      throw SFTPFileProviderError.invalidLocation
    }
    let existing = try await contents(of: parent).first {
      $0.location.remotePath == destinationPath
    }
    guard let existing else {
      try Task.checkCancellation()
      try await session.rename(at: temporaryPath, to: destinationPath)
      return
    }
    guard replacingExisting else { throw CocoaError(.fileWriteFileExists) }
    // フォルダを退避後に再帰削除せず、ファイルとリンクだけを確定対象とする。
    guard !existing.isDirectory || existing.isSymbolicLink else {
      throw CocoaError(.fileWriteFileExists)
    }
    let resolvedTemporary = normalized(try await session.realPath(of: temporaryPath))
    let resolvedDestination = normalized(try await session.realPath(of: destinationPath))
    guard resolvedTemporary != resolvedDestination else {
      throw SFTPFileProviderError.invalidLocation
    }
    let backupName = ".pkpane-replaced-" + UUID().uuidString
    let backupPath = childPath(named: backupName, in: parentPath)
    try Task.checkCancellation()
    // v3のrenameは既存名を拒否する。退避名に競合があっても旧宛先を変更しない。
    do {
      try await session.rename(at: destinationPath, to: backupPath)
    } catch {
      if let cocoaError = error as? CocoaError, cocoaError.code == .fileWriteFileExists {
        throw error
      }
      // 応答喪失なら退避先の所有も成否も断定できない。自動復元・削除は行わない。
      throw SFTPCommitRecoveryError(
        backupFileName: backupName, operation: .backup,
        originalFileName: itemName(of: destinationPath))
    }
    do {
      try Task.checkCancellation()
      try await session.rename(at: temporaryPath, to: destinationPath)
    } catch {
      // 取消済みの呼出しからでも復元を完了させる。外部作成された宛先は上書きしない。
      let recoverySession = session
      do {
        try await Task {
          try await recoverySession.rename(at: backupPath, to: destinationPath)
        }.value
      } catch {
        throw SFTPCommitRecoveryError(backupFileName: backupName, operation: .restore)
      }
      throw error
    }
    let cleanupSession = session
    do {
      // リンクの場合もリンク自身だけを除去する。再帰削除やリンク先の削除は行わない。
      try await Task {
        try await cleanupSession.remove(at: backupPath, isDirectory: false)
      }.value
    } catch {
      throw SFTPCommitRecoveryError(backupFileName: backupName, operation: .cleanup)
    }
  }

  func discardTransferFile(at temporaryLocation: FileLocation) async {
    guard temporaryLocation.providerID == id,
      let temporaryPath = temporaryLocation.remotePath
    else { return }
    try? await session.remove(at: temporaryPath, isDirectory: false)
  }
}

/// 情報パネル(SFTPBrowserView)向けのフルメタデータ取得。item(at:)(RemoteEditProvider)と
/// 同じく専用stat手段が無いため親ディレクトリを列挙して該当項目を探す。転送検証
/// (TransferSizeVerifier)はこちらではなく、単一stat相当で軽量なFileBrowserItemSizeProvider
/// (下記itemSize)を優先して使う。
extension SFTPFileProvider: FileBrowserItemDetailProvider {
  func detailedItem(at location: FileLocation) async throws -> FileItem {
    guard location.providerID == id,
      let parent = location.deletingLastPathComponent(),
      let remotePath = location.remotePath
    else {
      throw SFTPFileProviderError.invalidLocation
    }
    guard
      let item = try await contents(of: parent).first(where: {
        $0.location.remotePath == remotePath
      })
    else {
      throw SFTPFileProviderError.invalidLocation
    }
    return item
  }
}

extension SFTPFileProvider: FileBrowserPosixPermissionsProvider {
  func setPosixPermissions(_ permissions: Int, at location: FileLocation) async throws {
    guard location.providerID == id, let remotePath = location.remotePath else {
      throw SFTPFileProviderError.invalidLocation
    }
    try await session.setPosixPermissions(
      PosixPermissions.normalizedMode(permissions),
      at: remotePath)
  }
}

/// 転送検証(TransferSizeVerifier)がdestinationの実サイズを取得するための軽量経路。
/// SSH_FXP_STAT相当の単一stat(SFTPClientSession.fileSize)を使い、親ディレクトリの
/// 全列挙(detailedItemの経路)を避ける。1万件級ディレクトリへの多数ファイル転送でも
/// 検証1件あたりのコストが一定に保たれる。
extension SFTPFileProvider: FileBrowserItemSizeProvider {
  func itemSize(at location: FileLocation) async throws -> Int64? {
    guard location.providerID == id, let remotePath = location.remotePath else {
      throw SFTPFileProviderError.invalidLocation
    }
    return try await session.fileSize(at: remotePath)
  }
}

extension SFTPFileProvider: RemoteEditProvider {
  func downloadWorkingCopy(for item: FileItem, to localURL: URL) async throws {
    guard item.location.providerID == id,
      let remotePath = item.location.remotePath,
      !item.isDirectory
    else {
      throw SFTPFileProviderError.invalidLocation
    }
    try FileManager.default.createDirectory(
      at: localURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: localURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: localURL)
    defer { try? handle.close() }
    try await withTransferSession { transferSession in
      try await transferSession.streamFileContents(
        of: remotePath,
        chunkSize: SFTPChunkedTransfer.defaultChunkSize
      ) { chunk in
        try handle.write(contentsOf: chunk)
      }
    }
  }

  func item(at location: FileLocation) async throws -> FileItem? {
    guard location.providerID == id,
      let parent = location.deletingLastPathComponent(),
      let remotePath = location.remotePath
    else {
      throw SFTPFileProviderError.invalidLocation
    }
    return try await contents(of: parent).first { $0.location.remotePath == remotePath }
  }

  func uploadWorkingCopySafely(from localURL: URL, to location: FileLocation) async throws {
    guard location.providerID == id,
      let parent = location.deletingLastPathComponent()
    else {
      throw SFTPFileProviderError.invalidLocation
    }
    let temporaryName = [
      ".", localURL.lastPathComponent, ".pkpane-edit-", UUID().uuidString,
    ].joined()
    let temporary = parent.appending(pathComponent: temporaryName)!
    let cancellation = ChunkPipeCancellation()
    defer { cancellation.cancel() }
    let stream = BoundedChunkPipe.fileStream(
      at: localURL, chunkSize: SFTPChunkedTransfer.uploadChunkSize, cancellation: cancellation)
    do {
      try await writeFileChunks(stream, to: temporary, replacingExisting: false) { _ in }
      try Task.checkCancellation()
      try await commitTransferFile(from: temporary, to: location, replacingExisting: true)
    } catch {
      cancellation.cancel()
      await cancellation.waitForCompletion()
      await discardTransferFile(at: temporary)
      throw error
    }
  }
}

enum SFTPFileProviderError: LocalizedError, Equatable {
  case invalidName
  case invalidLocation
  case previewTooLarge
  case directoryNotFound(String)

  var errorDescription: String? {
    switch self {
    case .invalidName:
      "ファイル名またはフォルダ名が正しくありません。"
    case .invalidLocation:
      "このSFTP接続に属さない場所です。"
    case .previewTooLarge:
      "16 MBを超えるファイルはプレビューできません。"
    case .directoryNotFound(let path):
      "「\(path)」フォルダが存在しません。"
    }
  }
}

enum SFTPClientSessionError: LocalizedError {
  case previewUnavailable
  case copyUnavailable
  case transferUnavailable
  case permissionsUnavailable

  var errorDescription: String? {
    switch self {
    case .previewUnavailable:
      "このSFTP接続ではファイルのプレビューを利用できません。"
    case .copyUnavailable:
      "このSFTP接続ではコピーを利用できません。"
    case .transferUnavailable:
      "このSFTP接続ではストリーム転送を利用できません。"
    case .permissionsUnavailable:
      "このSFTP接続ではアクセス権を変更できません。"
    }
  }
}

/// 接続先の識別情報を含めず、手動救済に必要な退避名だけを通知する。
struct SFTPCommitRecoveryError: LocalizedError, Equatable {
  enum Operation: Sendable, Equatable { case backup, restore, cleanup }
  let backupFileName: String
  let operation: Operation
  let originalFileName: String?

  init(backupFileName: String, operation: Operation, originalFileName: String? = nil) {
    self.backupFileName = backupFileName
    self.operation = operation
    self.originalFileName = originalFileName
  }

  var errorDescription: String? {
    switch operation {
    case .backup:
      "退避の結果を確認できません。元名「\(originalFileName ?? "")」と退避名「\(backupFileName)」を確認してください。"
    case .restore:
      "復元の結果を確認できません。元のファイルと退避名「\(backupFileName)」を確認してください。"
    case .cleanup:
      "更新は確定しましたが、退避ファイル「\(backupFileName)」の除去結果を確認できません。"
    }
  }
}
