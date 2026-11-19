import Foundation
import Testing

@testable import PKPane

struct FileBrowserProviderContractTests {
  @Test("製品Providerの操作Capabilityには対応する実行経路がある")
  func providerOperationCapabilitiesHaveExecutionRoutes() throws {
    let volumeURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: volumeURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: volumeURL) }
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let ftpTarget = try FTPConnectionTarget(host: "ftp.example.com", username: "tester")
    let ftpSession = EmptyFTPClientSession()
    let providers: [any FileBrowserProvider] = [
      LocalFileProvider(),
      MountedVolumeProvider(volumeURL: volumeURL),
      SFTPFileProvider(target: target, directoryListing: EmptySFTPClientSession()),
      FTPFileProvider(
        target: ftpTarget,
        session: ftpSession,
        sessionFactory: { ftpSession }),
    ]

    for provider in providers {
      let capabilities = provider.capabilities
      if capabilities.contains(.write) || capabilities.contains(.rename) {
        #expect(provider is any FileBrowserOperationProvider)
      }
      if capabilities.contains(.moveWithinProvider)
        || capabilities.contains(.copyWithinProvider)
      {
        #expect(provider is any FileBrowserTransferProvider)
      }
      if capabilities.contains(.trash) {
        #expect(provider is any FileBrowserTrashProvider)
      }
      if capabilities.contains(.deletePermanently) {
        #expect(provider is any FileBrowserPermanentDeleteProvider)
      }
      #expect(provider.executableCapabilities == capabilities)
    }
  }

  @Test("FTPは全操作メニューが必要とする実行プロトコルを公開する")
  @MainActor
  func ftpExposesEveryOperationRouteUsedByMenus() throws {
    let target = try FTPConnectionTarget(host: "ftp.example.com", username: "tester")
    let session = EmptyFTPClientSession()
    let provider = FTPFileProvider(
      target: target,
      session: session,
      sessionFactory: { session })
    let browser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/", providerID: provider.id),
      transferQueue: .isolatedForTesting())

    #expect(provider is any FileBrowserOperationProvider)
    #expect(provider is any FileBrowserTransferProvider)
    #expect(provider is any FileBrowserPermanentDeleteProvider)
    #expect(provider is any FileBrowserDuplicateProvider)
    #expect(provider is any FileBrowserPreviewProvider)
    #expect(provider is any FileBrowserItemDetailProvider)
    #expect(provider is any FileBrowserPosixPermissionsProvider)
    #expect(provider is any RemoteEditProvider)
    #expect(browser.canDuplicate)
    #expect(browser.canResolveDetailThumbnailURL)
    #expect(browser.canSetPosixPermissions)
    #expect(browser.canEditRemotely)
  }

  @Test("実行プロトコルのないCapabilityはメニュー向けCapabilityから除外する")
  func executableCapabilitiesExcludeMissingExecutionRoutes() {
    let provider = CapabilityOnlyProvider()

    #expect(
      provider.executableCapabilities == [.read])
  }

  @Test("SFTPは全操作メニューが必要とする実行プロトコルを公開する")
  @MainActor
  func sftpExposesEveryOperationRouteUsedByMenus() throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let provider = SFTPFileProvider(
      target: target,
      directoryListing: EmptySFTPClientSession())
    let browser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: ".", providerID: provider.id),
      transferQueue: .isolatedForTesting())

    #expect(provider is any FileBrowserOperationProvider)
    #expect(provider is any FileBrowserTransferProvider)
    #expect(provider is any FileBrowserPermanentDeleteProvider)
    #expect(provider is any FileBrowserDuplicateProvider)
    #expect(provider is any FileBrowserPreviewProvider)
    #expect(provider is any FileBrowserItemDetailProvider)
    #expect(provider is any FileBrowserPosixPermissionsProvider)
    #expect(provider is any RemoteEditProvider)
    #expect(browser.canDuplicate)
    #expect(browser.canResolveDetailThumbnailURL)
    #expect(browser.canSetPosixPermissions)
    #expect(browser.canEditRemotely)
  }

  @Test("ローカル・NAS・SFTP・FTPは共通の閲覧Capabilityを公開する")
  func providersExposeCommonReadCapabilities() throws {
    let local = LocalFileProvider()
    let volumeURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: volumeURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: volumeURL) }
    let nas = MountedVolumeProvider(volumeURL: volumeURL)
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let sftp = SFTPFileProvider(target: target, directoryListing: EmptySFTPClientSession())
    let ftpTarget = try FTPConnectionTarget(host: "ftp.example.com", username: "tester")
    let ftpSession = EmptyFTPClientSession()
    let ftp = FTPFileProvider(
      target: ftpTarget, session: ftpSession, sessionFactory: { ftpSession })

    for provider in [
      ProviderCapabilitySnapshot(provider: local),
      ProviderCapabilitySnapshot(provider: nas),
      ProviderCapabilitySnapshot(provider: sftp),
      ProviderCapabilitySnapshot(provider: ftp),
    ] {
      #expect(provider.capabilities.contains(FileProviderCapabilities.read))
      #expect(provider.capabilities.contains(FileProviderCapabilities.write))
      #expect(provider.capabilities.contains(FileProviderCapabilities.rename))
    }
    #expect(local.connectionID == nil)
    #expect(nas.connectionID != nil)
    #expect(sftp.connectionID != nil)
    #expect(ftp.connectionID != nil)
  }

  @Test("ローカル・NAS・SFTP・FTPは共通のパンくず契約で開始位置を示す")
  func providersProduceBreadcrumbs() async throws {
    let localURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: localURL) }
    let local = LocalFileProvider()
    let nas = MountedVolumeProvider(volumeURL: localURL)
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let sftp = SFTPFileProvider(target: target, directoryListing: EmptySFTPClientSession())
    let ftpTarget = try FTPConnectionTarget(host: "ftp.example.com", username: "tester")
    let ftpSession = EmptyFTPClientSession()
    let ftp = FTPFileProvider(
      target: ftpTarget, session: ftpSession, sessionFactory: { ftpSession })

    let localLocation = FileLocation(localURL: localURL, providerID: local.id)
    let nasLocation = FileLocation(localURL: localURL, providerID: nas.id)
    let sftpLocation = FileLocation(remotePath: ".", providerID: sftp.id)
    let ftpLocation = FileLocation(remotePath: "/incoming", providerID: ftp.id)

    #expect(!local.breadcrumbs(for: localLocation, constrainedTo: nil).isEmpty)
    #expect(!nas.breadcrumbs(for: nasLocation, constrainedTo: nil).isEmpty)
    #expect(sftp.breadcrumbs(for: sftpLocation, constrainedTo: nil).first?.name == "ホームディレクトリ")
    #expect(ftp.breadcrumbs(for: ftpLocation, constrainedTo: nil).map(\.name) == ["/", "incoming"])
  }

  @Test("NAS直接SMB接続に失敗した場合はマウント経由の書き込みへフォールバックする")
  func mountedVolumeFallsBackWhenDirectSMBConnectionFails() async throws {
    let volumeURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: volumeURL) }
    try FileManager.default.createDirectory(at: volumeURL, withIntermediateDirectories: true)
    let provider = MountedVolumeProvider(
      volumeURL: volumeURL,
      credentialResolver: ContractSMBCredentialResolver(),
      sharePathResolver: { _ in
        SMBSharePath(
          host: "nas.example.local",
          shareName: "Documents",
          relativePathComponents: [".PKPane-transfer"])
      },
      directTransferEngine: { _ in
        SMBDirectTransferEngine(factory: ContractFailingSMBTransferClientFactory())
      },
      directTransferCache: SMBDirectEngineCache())
    let destinationURL = volumeURL.appending(path: "fallback.txt")
    let destination = FileLocation(localURL: destinationURL, providerID: provider.id)
    let chunks = AsyncThrowingStream<Data, Error> { continuation in
      continuation.yield(Data("フォールバック".utf8))
      continuation.finish()
    }

    try await provider.writeFileChunks(chunks, to: destination, replacingExisting: false) { _ in }

    #expect(try Data(contentsOf: destinationURL) == Data("フォールバック".utf8))
  }

  @Test("NASのSMB資格情報がない場合はマウント経由の書き込みを使う")
  func mountedVolumeUsesFallbackWhenSMBCredentialIsMissing() async throws {
    let volumeURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: volumeURL) }
    try FileManager.default.createDirectory(at: volumeURL, withIntermediateDirectories: true)
    let provider = MountedVolumeProvider(
      volumeURL: volumeURL,
      credentialResolver: MissingSMBCredentialResolver(),
      sharePathResolver: { _ in
        SMBSharePath(
          host: "nas.example.local",
          shareName: "Documents",
          relativePathComponents: [])
      })
    let destinationURL = volumeURL.appending(path: "fallback.txt")
    let destination = FileLocation(localURL: destinationURL, providerID: provider.id)
    let chunks = AsyncThrowingStream<Data, Error> { continuation in
      continuation.yield(Data("資格情報なし".utf8))
      continuation.finish()
    }

    try await provider.writeFileChunks(chunks, to: destination, replacingExisting: false) { _ in }

    #expect(try Data(contentsOf: destinationURL) == Data("資格情報なし".utf8))
  }
}

private struct CapabilityOnlyProvider: FileBrowserProvider {
  let id = FileProviderID(rawValue: "capability-only")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [
    .read, .write, .rename, .moveWithinProvider, .copyWithinProvider, .trash,
    .deletePermanently,
  ]

  func contents(of _: FileLocation) async throws -> [FileItem] { [] }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }
}

private struct ProviderCapabilitySnapshot {
  let capabilities: FileProviderCapabilities
  let connectionID: FileProviderConnectionID?

  init(provider: any FileBrowserProvider) {
    capabilities = provider.capabilities
    connectionID = provider.connectionID
  }
}

private struct EmptySFTPClientSession: SFTPClientSession {
  func contents(of _: String) async throws -> [SFTPDirectoryEntry] { [] }

  func createDirectory(at _: String) async throws {}

  func remove(at _: String, isDirectory _: Bool) async throws {}

  func rename(at _: String, to _: String) async throws {}

  func close() async throws {}
}

private struct EmptyFTPClientSession: FTPClientSession {
  func contents(of _: String) async throws -> [FTPDirectoryEntry] { [] }
  func createDirectory(at _: String) async throws {}
  func remove(at _: String, isDirectory _: Bool) async throws {}
  func rename(at _: String, to _: String) async throws {}
  func streamFileContents(
    of _: String,
    receive _: @escaping @Sendable (Data) async throws -> Void
  ) async throws {}
  func writeFileContents(
    to _: String,
    chunks _: AsyncThrowingStream<Data, Error>,
    progress _: @escaping @Sendable (Int64) -> Void
  ) async throws {}
  func fileSize(at _: String) async throws -> Int64? { nil }
  func setPosixPermissions(_: Int, at _: String) async throws {}
  func isActive() async -> Bool { true }
  func close() async {}
}

private struct ContractSMBCredentialResolver: SMBDirectCredentialResolving {
  func credentials(forServer _: String, preferredAccount _: String?) -> SMBDirectCredentials? {
    SMBDirectCredentials(account: "tester", password: "password")
  }
}

private struct MissingSMBCredentialResolver: SMBDirectCredentialResolving {
  func credentials(forServer _: String, preferredAccount _: String?) -> SMBDirectCredentials? {
    nil
  }
}

private struct ContractFailingSMBTransferClientFactory: SMBDirectTransferClientFactory {
  func connect() async throws -> any SMBDirectTransferClient {
    throw SMBDirectTransferError.connectionFailed
  }
}
