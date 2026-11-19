import Foundation
import Testing

@testable import PKPane

struct DistributionConfigurationTests {
  @Test("通常ReleaseのentitlementsはMac App Store用Sandbox権限を持つ")
  func releaseEntitlementsContainRequiredSandboxCapabilities() throws {
    let entitlements = try loadEntitlements(named: "PKPane.entitlements")

    #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
    #expect(
      entitlements["com.apple.security.files.user-selected.read-write"] as? Bool == true)
    #expect(entitlements["com.apple.security.files.bookmarks.app-scope"] as? Bool == true)
    #expect(entitlements["com.apple.security.network.client"] as? Bool == true)
  }

  @Test("Release entitlementsは.sshとCloudStorageの読み取り例外を持つ")
  func releaseEntitlementsAllowReadingSSHAndCloudStorage() throws {
    let entitlements = try loadEntitlements(named: "PKPane.entitlements")

    let readOnlyPaths = try #require(
      entitlements["com.apple.security.temporary-exception.files.home-relative-path.read-only"]
        as? [String])
    #expect(readOnlyPaths.contains("/.ssh/"))
    #expect(readOnlyPaths.contains("/Library/CloudStorage/"))
  }

  @Test("iCloud構成はSandbox基底とKVS権限を併せ持つ")
  func iCloudEntitlementsContainSandboxAndKVS() throws {
    let entitlements = try loadEntitlements(named: "PKPane-icloud.entitlements")

    #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
    #expect(
      entitlements["com.apple.security.files.user-selected.read-write"] as? Bool == true)
    #expect(entitlements["com.apple.security.files.bookmarks.app-scope"] as? Bool == true)
    #expect(entitlements["com.apple.security.network.client"] as? Bool == true)
    #expect(
      entitlements["com.apple.developer.ubiquity-kvstore-identifier"] as? String
        == "$(TeamIdentifierPrefix)$(CFBundleIdentifier)")
  }

  @Test("ad-hoc entitlementsはテスト専用で製品Release設定から参照しない")
  func adHocEntitlementsRemainTestOnly() throws {
    let entitlements = try loadEntitlements(named: "PKPane-adhoc.entitlements")
    #expect(entitlements.isEmpty)

    let projectYAML = try String(
      contentsOf: repositoryRoot.appending(path: "project.yml"),
      encoding: .utf8)
    #expect(projectYAML.contains("CODE_SIGN_ENTITLEMENTS: Config/PKPane.entitlements"))
    #expect(!projectYAML.contains("CODE_SIGN_ENTITLEMENTS: Config/PKPane-adhoc.entitlements"))
  }

  @Test("App IconはmacOSの全必須サイズをAsset Catalogへ登録する")
  func appIconContainsAllRequiredMacSizes() throws {
    let iconSet = repositoryRoot.appending(path: "PKPane/Assets.xcassets/AppIcon.appiconset")
    let data = try Data(contentsOf: iconSet.appending(path: "Contents.json"))
    let contents = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    let images = try #require(contents["images"] as? [[String: String]])
    let registered = Set(
      images.compactMap { image -> String? in
        guard let size = image["size"], let scale = image["scale"] else { return nil }
        return "\(size)@\(scale)"
      })
    #expect(
      registered == [
        "16x16@1x", "16x16@2x", "32x32@1x", "32x32@2x", "128x128@1x",
        "128x128@2x", "256x256@1x", "256x256@2x", "512x512@1x", "512x512@2x",
      ])
    for image in images {
      let filename = try #require(image["filename"])
      #expect(FileManager.default.fileExists(atPath: iconSet.appending(path: filename).path))
    }

    let projectYAML = try String(
      contentsOf: repositoryRoot.appending(path: "project.yml"), encoding: .utf8)
    #expect(projectYAML.contains("ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon"))
  }

  @Test("Privacy Manifestは追跡とデータ収集を行わない構成を明示する")
  func privacyManifestDeclaresNoCollectionOrTracking() throws {
    let data = try Data(
      contentsOf: repositoryRoot.appending(path: "PKPane/PrivacyInfo.xcprivacy"))
    let manifest = try #require(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

    #expect(manifest["NSPrivacyTracking"] as? Bool == false)
    #expect((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
    #expect((manifest["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
    #expect(!(manifest["NSPrivacyAccessedAPITypes"] as? [Any] ?? []).isEmpty)
  }

  @Test("Sandbox版は起動時にフルディスクアクセスを一律要求しない")
  func sandboxUsesContextualFolderAuthorizationGuidance() throws {
    let obsoleteGuide = repositoryRoot.appending(
      path: "PKPane/Presentation/Launch/FullDiskAccessGuideView.swift")
    #expect(!FileManager.default.fileExists(atPath: obsoleteGuide.path))

    let launchSource = try String(
      contentsOf: repositoryRoot.appending(path: "PKPane/Presentation/Launch/LaunchView.swift"),
      encoding: .utf8)
    #expect(!launchSource.contains("presentFullDiskAccessGuideIfNeeded"))

    let browserSource = try String(
      contentsOf: repositoryRoot.appending(
        path: "PKPane/Presentation/SFTP/SFTPBrowserView.swift"),
      encoding: .utf8)
    #expect(browserSource.contains("アクセスを許可したフォルダに限られます"))
    #expect(browserSource.contains("requestFolderAccess()"))
  }

  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func loadEntitlements(named name: String) throws -> [String: Any] {
    let data = try Data(contentsOf: repositoryRoot.appending(path: "Config/\(name)"))
    return try #require(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
  }
}
