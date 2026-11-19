import Darwin
import Foundation
import Testing
import ZIPFoundation

@testable import PKPane

struct ZipAppleDoubleMetadataTests {
  @Test("Finder形式ZIPの側車を復元して単一ファイルとして配置する")
  func restoresFinderZIPMetadata() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let zipURL = root.appending(path: "photo.zip")
    let archive = try Archive(url: zipURL, accessMode: .create)
    try add(Data("photo".utf8), path: "Photo.jpg", archive: archive)
    var info = Data(repeating: 0, count: 32)
    info[0] = 0x4A
    let fork = Data("resource fork".utf8)
    try add(sidecar(info: info, fork: fork), path: "__MACOSX/._Photo.jpg", archive: archive)
    let output = root.appending(path: "output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    _ = try await ArchiveService().extractArchive(
      at: zipURL, in: output, destination: .currentDirectory)
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["Photo.jpg"])
    #expect(attribute("com.apple.ResourceFork", at: output.appending(path: "Photo.jpg")) == fork)
    #expect(attribute("com.apple.FinderInfo", at: output.appending(path: "Photo.jpg")) == info)
  }

  @Test("バイト転送向け展開は本体と側車と元ZIPを変更せず保持する")
  func preservesSidecarWhenMetadataRestorationDisabled() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let zipURL = root.appending(path: "photo.zip")
    let original = Data("photo".utf8)
    let metadata = sidecar(info: Data(repeating: 0, count: 32), fork: Data("fork".utf8))
    let archive = try Archive(url: zipURL, accessMode: .create)
    try add(original, path: "Photo.jpg", archive: archive)
    try add(metadata, path: "__MACOSX/._Photo.jpg", archive: archive)
    let zipBefore = try Data(contentsOf: zipURL)
    let output = root.appending(path: "output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    _ = try await ArchiveService().extractArchive(
      at: zipURL, in: output, destination: .currentDirectory, restoresZIPMetadata: false)
    #expect(try Data(contentsOf: output.appending(path: "Photo.jpg")) == original)
    #expect(try Data(contentsOf: output.appending(path: "__MACOSX/._Photo.jpg")) == metadata)
    #expect(attribute("com.apple.ResourceFork", at: output.appending(path: "Photo.jpg")) == nil)
    #expect(try Data(contentsOf: zipURL) == zipBefore)
  }

  @Test("ZIP直下の._ユーザーファイルも配置から除外しない", arguments: [false, true], [false, true])
  func preservesRootDotUnderscoreFiles(single: Bool, defaultOpen: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let zipURL = root.appending(path: "sample.zip")
    let archive = try Archive(url: zipURL, accessMode: .create)
    let preserved = Data("user data".utf8)
    try add(preserved, path: "._user", archive: archive)
    if !single { try add(Data("normal".utf8), path: "normal", archive: archive) }
    let zipBefore = try Data(contentsOf: zipURL)
    let destination = root.appending(path: "output")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let result = try await ArchiveService().extractArchive(
      at: zipURL, in: destination, destination: .currentDirectory,
      organizingForDefaultOpen: defaultOpen)
    let target = defaultOpen && single ? result : result.appending(path: "._user")
    #expect(try Data(contentsOf: target) == preserved)
    if defaultOpen { #expect(result.lastPathComponent == (single ? "._user" : "sample")) }
    if !single {
      #expect(try Data(contentsOf: result.appending(path: "normal")) == Data("normal".utf8))
    }
    #expect(try Data(contentsOf: zipURL) == zipBefore)
  }

  @Test("フォルダ名展開の単一フォルダ判定でも._ルートを保持する")
  func preservesRootSidecarBesideNamedFolder() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let zipURL = root.appending(path: "Folder.zip")
    let archive = try Archive(url: zipURL, accessMode: .create)
    try add(Data("inside".utf8), path: "Folder/inside", archive: archive)
    let preserved = Data("user data".utf8)
    try add(preserved, path: "._user", archive: archive)
    let destination = root.appending(path: "output")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let result = try await ArchiveService().extractArchive(
      at: zipURL, in: destination, destination: .folderNamedAfterArchive)
    #expect(try Data(contentsOf: result.appending(path: "._user")) == preserved)
    #expect(try Data(contentsOf: result.appending(path: "Folder/inside")) == Data("inside".utf8))
  }

  @Test("macOS標準PACKのタグを含む側車を復元する")
  func restoresSystemPackedMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let output = root.appending(path: "output")
    let metadata = output.appending(path: "__MACOSX")
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source")
    try Data("source".utf8).write(to: source)
    let tags = try PropertyListSerialization.data(
      fromPropertyList: ["青\n4"], format: .binary, options: 0)
    let fork = Data("fork".utf8)
    var info = Data(repeating: 0, count: 32)
    info[0] = 0x4A
    let attributes = [
      "com.apple.ResourceFork": fork, "com.apple.FinderInfo": info,
      "com.apple.metadata:_kMDItemUserTags": tags,
    ]
    for (name, data) in attributes {
      let status = data.withUnsafeBytes {
        setxattr(source.path, name, $0.baseAddress, $0.count, 0, 0)
      }
      try #require(status == 0)
    }
    let sidecarURL = metadata.appending(path: "._file")
    try #require(
      copyfile(source.path, sidecarURL.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_PACK))
        == 0)
    let decoded = try #require(ZipAppleDoubleMetadata.decode(Data(contentsOf: sidecarURL)))
    #expect(decoded.fullySupported)
    try Data("destination".utf8).write(to: output.appending(path: "file"))
    try ZipAppleDoubleMetadata.restore(
      in: output, paths: ["__MACOSX/._file"], cancellationProgress: Progress())
    for (name, data) in attributes {
      #expect(attribute(name, at: output.appending(path: "file")) == data)
    }
    #expect(!FileManager.default.fileExists(atPath: metadata.path))
  }

  @Test("側車のprovenanceを移植せず本体の由来属性を保持する")
  func doesNotTransplantProvenance() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let metadata = root.appending(path: "__MACOSX")
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appending(path: "file")
    try Data("original".utf8).write(to: target)
    let original = attribute("com.apple.provenance", at: target)
    let foreign = Data(repeating: 0xAB, count: 11)
    let sidecarURL = metadata.appending(path: "._file")
    let packed = extendedSidecar(attributes: [("com.apple.provenance", foreign)])
    try packed.write(to: sidecarURL)
    let decoded = try #require(ZipAppleDoubleMetadata.decode(packed))
    #expect(decoded.fullySupported)
    #expect(decoded.attributes["com.apple.provenance"] == nil)
    try ZipAppleDoubleMetadata.restore(
      in: root, paths: ["__MACOSX/._file"], cancellationProgress: Progress())
    #expect(attribute("com.apple.provenance", at: target) == original)
    #expect(!FileManager.default.fileExists(atPath: metadata.path))
  }

  @Test("ACLと隔離属性を復元せず側車を保持する")
  func preservesUnsupportedSecurityMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let metadata = root.appending(path: "__MACOSX")
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appending(path: "file")
    try Data("original".utf8).write(to: target)
    let sidecarURL = metadata.appending(path: "._file")
    let securityData = extendedSidecar(attributes: [
      ("com.apple.acl.text", Data("!#acl 1\nuser::deny read".utf8)),
      ("com.apple.quarantine", Data("0081;00000000;test;".utf8)),
    ])
    try securityData.write(to: sidecarURL)
    let decoded = try #require(ZipAppleDoubleMetadata.decode(securityData))
    #expect(!decoded.fullySupported)
    #expect(decoded.attributes.isEmpty)
    try ZipAppleDoubleMetadata.restore(
      in: root, paths: ["__MACOSX/._file"], cancellationProgress: Progress())
    #expect(attribute("com.apple.quarantine", at: target) == nil)
    #expect(try Data(contentsOf: target) == Data("original".utf8))
    #expect(try Data(contentsOf: sidecarURL) == securityData)
  }

  @Test("本体の既存拡張属性を上書きせず側車を保持する")
  func preservesExistingAttributes() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let metadata = root.appending(path: "__MACOSX")
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appending(path: "file")
    try Data("original".utf8).write(to: target)
    let original = Data("existing fork".utf8)
    try #require(
      original.withUnsafeBytes {
        setxattr(target.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0)
      } == 0)
    let sidecarURL = metadata.appending(path: "._file")
    let metadataData = sidecar(info: Data(repeating: 0, count: 32), fork: Data("new fork".utf8))
    try metadataData.write(to: sidecarURL)
    try ZipAppleDoubleMetadata.restore(
      in: root, paths: ["__MACOSX/._file"], cancellationProgress: Progress())
    #expect(attribute("com.apple.ResourceFork", at: target) == original)
    #expect(try Data(contentsOf: target) == Data("original".utf8))
    #expect(try Data(contentsOf: sidecarURL) == metadataData)
  }

  @Test("キャンセル時は本体と側車を保持する")
  func cancellationPreservesFiles() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let metadata = root.appending(path: "__MACOSX")
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appending(path: "file")
    try Data("original".utf8).write(to: target)
    let sidecarURL = metadata.appending(path: "._file")
    try sidecar(info: Data(repeating: 0, count: 32), fork: Data([1])).write(to: sidecarURL)
    let progress = Progress()
    progress.cancel()
    #expect(throws: CancellationError.self) {
      try ZipAppleDoubleMetadata.restore(
        in: root, paths: ["__MACOSX/._file"], cancellationProgress: progress)
    }
    #expect(attribute("com.apple.ResourceFork", at: target) == nil)
    #expect(try Data(contentsOf: target) == Data("original".utf8))
    #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
  }

  @Test("既定openはメタデータ側車を除いた単一項目を連番で配置する")
  func defaultOpenPreservesExistingFile() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let zipURL = root.appending(path: "photo.zip")
    let archive = try Archive(url: zipURL, accessMode: .create)
    try add(Data("photo".utf8), path: "Photo.jpg", archive: archive)
    try add(
      sidecar(info: Data(repeating: 0, count: 32), fork: Data("fork".utf8)),
      path: "__MACOSX/._Photo.jpg", archive: archive)
    let existing = root.appending(path: "Photo.jpg")
    try Data("existing".utf8).write(to: existing)
    let output = try await ArchiveService().extractArchive(
      at: zipURL, in: root, destination: .currentDirectory, organizingForDefaultOpen: true)
    #expect(output.lastPathComponent == "Photo 2.jpg")
    #expect(try Data(contentsOf: output) == Data("photo".utf8))
    #expect(try Data(contentsOf: existing) == Data("existing".utf8))
    #expect(attribute("com.apple.ResourceFork", at: output) == Data("fork".utf8))
    #expect(FileManager.default.fileExists(atPath: zipURL.path))
  }

  @Test("不正な側車と任意のMACOSX内データは保持する")
  func preservesUnverifiedFiles() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let metadata = root.appending(path: "__MACOSX")
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("original".utf8).write(to: root.appending(path: "file"))
    try Data("user data".utf8).write(to: metadata.appending(path: "._file"))
    try Data("keep".utf8).write(to: metadata.appending(path: "notes"))
    try ZipAppleDoubleMetadata.restore(
      in: root, paths: ["__MACOSX/._file"], cancellationProgress: Progress())
    #expect(try Data(contentsOf: metadata.appending(path: "._file")) == Data("user data".utf8))
    #expect(FileManager.default.fileExists(atPath: metadata.appending(path: "notes").path))
  }

  @Test("本体のsymlinkを越えて属性を書き込まない")
  func rejectsSymlinkTarget() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let metadata = root.appending(path: "__MACOSX")
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appending(path: "original")
    try Data().write(to: original)
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: "link"), withDestinationURL: original)
    try sidecar(info: Data(repeating: 0, count: 32), fork: Data([1])).write(
      to: metadata.appending(path: "._link"))
    try ZipAppleDoubleMetadata.restore(
      in: root, paths: ["__MACOSX/._link"], cancellationProgress: Progress())
    #expect(attribute("com.apple.ResourceFork", at: original) == nil)
    #expect(FileManager.default.fileExists(atPath: metadata.appending(path: "._link").path))
  }

  @Test("正常な側車の復元後も未検証の側車を再帰削除しない")
  func preservesUnverifiedSidecarBesideConsumedMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let metadataRoot = root.appending(path: "__MACOSX")
    try FileManager.default.createDirectory(at: metadataRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appending(path: "file")
    try Data("original".utf8).write(to: target)
    let fork = Data("fork".utf8)
    try sidecar(info: Data(repeating: 0, count: 32), fork: fork).write(
      to: metadataRoot.appending(path: "._file"))
    let unverified = Data("user data".utf8)
    let preserved = metadataRoot.appending(path: "._other")
    try unverified.write(to: preserved)
    try ZipAppleDoubleMetadata.restore(in: root, cancellationProgress: Progress())
    #expect(attribute("com.apple.ResourceFork", at: target) == fork)
    #expect(try Data(contentsOf: preserved) == unverified)
    #expect(!FileManager.default.fileExists(atPath: metadataRoot.appending(path: "._file").path))
  }

  @Test("隠しサブフォルダ内の側車も除外せず列挙する")
  func restoresHiddenNestedSidecars() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let targetFolder = root.appending(path: ".nested")
    let metadataRoot = root.appending(path: "__MACOSX")
    let metadataFolder = metadataRoot.appending(path: ".nested")
    try FileManager.default.createDirectory(at: metadataFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = targetFolder.appending(path: "file")
    try Data("original".utf8).write(to: target)
    let fork = Data("fork".utf8)
    try sidecar(info: Data(repeating: 0, count: 32), fork: fork).write(
      to: metadataFolder.appending(path: "._file"))
    try ZipAppleDoubleMetadata.restore(in: root, cancellationProgress: Progress())
    #expect(attribute("com.apple.ResourceFork", at: target) == fork)
    #expect(try Data(contentsOf: target) == Data("original".utf8))
    #expect(!FileManager.default.fileExists(atPath: metadataRoot.path))
  }

  @Test("側車ルートのシンボリックリンクを列挙しない")
  func rejectsSymlinkMetadataRoot() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let external = root.appending(path: "external")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("original".utf8).write(to: root.appending(path: "file"))
    let metadata = sidecar(info: Data(repeating: 0, count: 32), fork: Data([1]))
    let sidecarURL = external.appending(path: "._file")
    try metadata.write(to: sidecarURL)
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: "__MACOSX"), withDestinationURL: external)
    try ZipAppleDoubleMetadata.restore(in: root, cancellationProgress: Progress())
    #expect(attribute("com.apple.ResourceFork", at: root.appending(path: "file")) == nil)
    #expect(try Data(contentsOf: sidecarURL) == metadata)
  }

  @Test("AppleDoubleの範囲不正と過大入力を拒否する")
  func rejectsInvalidBounds() {
    var data = sidecar(info: Data(repeating: 0, count: 32), fork: Data([1]))
    data.replaceSubrange(42..<46, with: [255, 255, 255, 255])
    #expect(ZipAppleDoubleMetadata.decode(data) == nil)
    #expect(
      ZipAppleDoubleMetadata.decode(
        Data(repeating: 0, count: ZipAppleDoubleMetadata.maximumBytes + 1)) == nil)
  }

  private func add(_ data: Data, path: String, archive: Archive) throws {
    try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) {
      position, size in
      data.subdata(in: Int(position)..<min(Int(position) + size, data.count))
    }
  }

  private func sidecar(info: Data, fork: Data) -> Data {
    var data = Data()
    func append(_ value: Int, bytes: Int) {
      for shift in (0..<bytes).reversed() {
        data.append(UInt8(truncatingIfNeeded: value >> (shift * 8)))
      }
    }
    append(0x0005_1607, bytes: 4)
    append(0x0002_0000, bytes: 4)
    data.append(Data(repeating: 0, count: 16))
    append(2, bytes: 2)
    append(9, bytes: 4)
    append(50, bytes: 4)
    append(32, bytes: 4)
    append(2, bytes: 4)
    append(82, bytes: 4)
    append(fork.count, bytes: 4)
    data.append(info)
    data.append(fork)
    return data
  }

  private func extendedSidecar(attributes: [(String, Data)]) -> Data {
    var names = Data()
    var payload = Data()
    let tableSize = attributes.reduce(0) { $0 + ((11 + $1.0.utf8.count + 1 + 3) & ~3) }
    let dataStart = 120 + tableSize
    func integer(_ value: Int, bytes: Int) -> Data {
      Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    for (name, value) in attributes {
      names.append(integer(dataStart + payload.count, bytes: 4))
      names.append(integer(value.count, bytes: 4))
      names.append(Data(repeating: 0, count: 2))
      names.append(UInt8(name.utf8.count + 1))
      names.append(Data(name.utf8))
      names.append(0)
      while names.count % 4 != 0 { names.append(0) }
      payload.append(value)
    }
    let total = dataStart + payload.count
    var data = sidecar(info: Data(repeating: 0, count: 32), fork: Data())
    data.replaceSubrange(34..<38, with: integer(total - 50, bytes: 4))
    data.replaceSubrange(42..<46, with: integer(total, bytes: 4))
    data.append(Data(repeating: 0, count: 2))
    data.append(integer(0x4154_5452, bytes: 4))
    data.append(Data(repeating: 0, count: 4))
    data.append(integer(total, bytes: 4))
    data.append(integer(dataStart, bytes: 4))
    data.append(integer(payload.count, bytes: 4))
    data.append(Data(repeating: 0, count: 14))
    data.append(integer(attributes.count, bytes: 2))
    data.append(names)
    data.append(payload)
    return data
  }

  private func attribute(_ name: String, at url: URL) -> Data? {
    let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
    guard size >= 0 else { return nil }
    var bytes = Data(count: size)
    let read = bytes.withUnsafeMutableBytes {
      getxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
    }
    return read == size ? bytes : nil
  }
}
