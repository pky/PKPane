import Foundation
import PLzmaSDK
import SWCompression
import Testing
import ZIPFoundation
import zlib

@testable import PKPane

struct ArchiveServiceTests {
  @Test("アーカイブ形式は拡張子と表示名を提供する")
  func archiveFormatsProvideExtensionsAndDisplayNames() {
    #expect(ArchiveFormat.zip.fileExtension == "zip")
    #expect(ArchiveFormat.zip.displayName == "ZIP")
    #expect(ArchiveFormat.sevenZip.fileExtension == "7z")
    #expect(ArchiveFormat.sevenZip.displayName == "7z")
    #expect(ArchiveFormat.tar.fileExtension == "tar")
    #expect(ArchiveFormat.tarGzip.fileExtension == "tar.gz")
    #expect(ArchiveFormat.tarBzip2.fileExtension == "tar.bz2")
    #expect(ArchiveFormat.tarXz.fileExtension == "tar.xz")
    #expect(ArchiveFormat.gzip.fileExtension == "gz")
    #expect(ArchiveFormat.bzip2.fileExtension == "bz2")
    #expect(ArchiveFormat.xz.fileExtension == "xz")
    #expect(ArchiveFormat.rar.fileExtension == "rar")
    #expect(ArchiveFormat.creationFormats == [.zip, .sevenZip])
  }

  @Test("アーカイブ形式は拡張子を大文字小文字を区別せず判定する")
  func detectsArchiveFormatFromExtensionCaseInsensitively() {
    #expect(ArchiveFormat(url: URL(fileURLWithPath: "/tmp/sample.ZIP")) == .zip)
    #expect(ArchiveFormat(url: URL(fileURLWithPath: "/tmp/sample.7Z")) == .sevenZip)
    #expect(ArchiveFormat(url: URL(fileURLWithPath: "/tmp/sample.TAR")) == .tar)
    #expect(ArchiveFormat(url: URL(fileURLWithPath: "/tmp/sample.TAR.GZ")) == .tarGzip)
    #expect(ArchiveFormat(url: URL(fileURLWithPath: "/tmp/sample.TgZ")) == .tarGzip)
    #expect(ArchiveFormat(url: URL(fileURLWithPath: "/tmp/sample.tar.BZ2")) == .tarBzip2)
    #expect(ArchiveFormat(url: URL(fileURLWithPath: "/tmp/sample.TBZ")) == .tarBzip2)
    #expect(ArchiveFormat(url: URL(fileURLWithPath: "/tmp/sample.tar.XZ")) == .tarXz)
    #expect(ArchiveFormat(url: URL(fileURLWithPath: "/tmp/sample.TXZ")) == .tarXz)
    #expect(ArchiveFormat(url: URL(fileURLWithPath: "/tmp/sample.GZ")) == .gzip)
    #expect(ArchiveFormat(url: URL(fileURLWithPath: "/tmp/sample.BZ2")) == .bzip2)
    #expect(ArchiveFormat(url: URL(fileURLWithPath: "/tmp/sample.XZ")) == .xz)
    #expect(ArchiveFormat(url: URL(fileURLWithPath: "/tmp/sample.RAR")) == .rar)
    #expect(ArchiveFormat(url: URL(fileURLWithPath: "/tmp/sample.txt")) == nil)
  }

  @Test("二重拡張子は単体圧縮より先に判定し同名フォルダ名から全体を除く")
  func compoundArchiveExtensionsTakePriority() {
    let tarGzipURL = URL(fileURLWithPath: "/tmp/backup.tar.gz")
    let gzipURL = URL(fileURLWithPath: "/tmp/report.gz")

    #expect(ArchiveFormat(url: tarGzipURL) == .tarGzip)
    #expect(ArchiveFormat.tarGzip.baseName(for: tarGzipURL) == "backup")
    #expect(ArchiveFormat.gzip.baseName(for: gzipURL) == "report")
  }

  @Test("展開専用形式は作成処理へ渡してもcodecを呼ばない")
  func extractionOnlyFormatsCannotBeCreated() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let tarCodec = RecordingArchiveCodec()
    let service = ArchiveService(codecs: [.tar: tarCodec])

    await #expect(throws: ArchiveServiceError.self) {
      _ = try await service.createArchive(
        from: [root.appending(path: "source.txt")],
        in: root,
        name: "sample.tar",
        format: .tar)
    }

    #expect(tarCodec.createCallCount == 0)
  }

  @Test("作成形式と展開対象の拡張子に対応するcodecを選ぶ")
  func routesArchiveOperationsToMatchingCodec() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let zipCodec = RecordingArchiveCodec()
    let sevenZipCodec = RecordingArchiveCodec()
    let service = ArchiveService(codecs: [.zip: zipCodec, .sevenZip: sevenZipCodec])

    _ = try await service.createArchive(
      from: [root.appending(path: "source.txt")],
      in: root,
      name: "sample.7z",
      format: .sevenZip)
    let extractionDirectory = root.appending(path: "extracted", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: extractionDirectory,
      withIntermediateDirectories: true)
    _ = try await service.extractArchive(
      at: root.appending(path: "EXTERNAL.7Z"),
      in: extractionDirectory,
      destination: .currentDirectory)

    #expect(zipCodec.createCallCount == 0)
    #expect(zipCodec.extractCallCount == 0)
    #expect(sevenZipCodec.createCallCount == 1)
    #expect(sevenZipCodec.extractCallCount == 1)
  }

  @Test("未対応拡張子のアーカイブはcodec実行前に拒否する")
  func rejectsUnsupportedArchiveExtension() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ArchiveService()

    do {
      _ = try await service.extractArchive(
        at: root.appending(path: "sample.cab"),
        in: root,
        destination: .currentDirectory)
      Issue.record("未対応形式の展開が成功しました")
    } catch let error as ArchiveServiceError {
      guard case .unsupportedFormat(let fileExtension) = error else {
        Issue.record("想定外のArchiveServiceErrorです: \(error)")
        return
      }
      #expect(fileExtension == "cab")
    }
  }

  @Test("壊れた7zのPLzmaSDKエラーを形式付きドメインエラーへ変換する")
  func mapsCorruptSevenZipToOperationFailed() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "corrupt.7z")
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try Data("not-a-seven-zip".utf8).write(to: archiveURL)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    do {
      _ = try await ArchiveService().extractArchive(
        at: archiveURL,
        in: destination,
        destination: .currentDirectory)
      Issue.record("壊れた7zの展開が成功しました")
    } catch let error as ArchiveServiceError {
      guard case .operationFailed(let format) = error else {
        Issue.record("想定外のArchiveServiceErrorです: \(error)")
        return
      }
      #expect(format == .sevenZip)
    }
  }

  @Test("展開失敗時の一時出力はArchiveServiceが削除する")
  func archiveServiceRemovesTemporaryOutputAfterExtractionFailure() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let service = ArchiveService(codecs: [.sevenZip: FailingExtractionArchiveCodec()])

    await #expect(throws: ArchiveServiceError.self) {
      _ = try await service.extractArchive(
        at: root.appending(path: "sample.7z"),
        in: destination,
        destination: .currentDirectory)
    }

    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
  }

  @Test("tar・tar.gz・tar.bz2・tar.xzを既存の展開経路で展開する")
  func extractsTarFamilyArchivesThroughArchiveService() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let tarData = makeTarArchive(entries: [
      ("documents/", .directory, Data()),
      ("documents/report.txt", .regular, Data("tar本文".utf8)),
    ])
    let tarXzData = try #require(Data(base64Encoded: Self.tarXzFixtureBase64))
    let archives: [(String, Data)] = [
      ("sample.tar", tarData),
      ("sample.tar.gz", try GzipArchive.archive(data: tarData)),
      ("sample.tar.bz2", BZip2.compress(data: tarData)),
      ("sample.tar.xz", tarXzData),
    ]

    for (archiveName, archiveData) in archives {
      let caseRoot = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: true)
      let archiveURL = caseRoot.appending(path: archiveName)
      try archiveData.write(to: archiveURL)
      let progress = ProgressCollector()

      _ = try await ArchiveService().extractArchive(
        at: archiveURL,
        in: caseRoot,
        destination: .currentDirectory,
        progress: { progress.append($0) })

      let expectedURL =
        archiveName.hasSuffix(".xz")
        ? caseRoot.appending(path: "report.txt")
        : caseRoot.appending(path: "documents/report.txt")
      let expectedText = archiveName.hasSuffix(".xz") ? "hello xz" : "tar本文"
      #expect(try String(contentsOf: expectedURL, encoding: .utf8) == expectedText)
      assertMonotonicCompletedProgress(progress.values)
    }
  }

  @Test("tarは危険なパスとリンクを出力前に拒否する")
  func rejectsUnsafeTarEntriesBeforeWriting() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let sentinel = destination.appending(path: "keep.txt")
    try Data("保持".utf8).write(to: sentinel)

    for (name, data) in [
      ("traversal.tar", makeTarArchive(entries: [("../outside.txt", .regular, Data("外".utf8))])),
      ("link.tar", makeTarArchive(entries: [("shortcut", .symbolicLink, Data())])),
    ] {
      let archiveURL = root.appending(path: name)
      try data.write(to: archiveURL)

      #expect(throws: ArchiveServiceError.self) {
        try TarArchiveCodec(format: .tar).extractArchive(
          at: archiveURL,
          to: destination,
          limits: .default,
          cancellationProgress: Progress(),
          progress: { _ in })
      }
      #expect(try String(contentsOf: sentinel, encoding: .utf8) == "保持")
      #expect(!FileManager.default.fileExists(atPath: root.appending(path: "outside.txt").path))
    }
  }

  @Test("tar codecは項目数・展開後サイズ・圧縮率の上限を適用する")
  func appliesTarSafetyLimits() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let tarData = makeTarArchive(entries: [
      ("a.txt", .regular, Data(repeating: 0, count: 4_096)),
      ("b.txt", .regular, Data("b".utf8)),
    ])
    let archiveURL = root.appending(path: "bomb.tar.gz")
    try GzipArchive.archive(data: tarData).write(to: archiveURL)

    let limits = ArchiveSafetyLimits(
      maximumEntryCount: 1,
      maximumUncompressedBytes: 1_024,
      maximumCompressionRatio: 2)
    #expect(throws: ArchiveServiceError.self) {
      try TarArchiveCodec(format: .tarGzip).extractArchive(
        at: archiveURL,
        to: destination,
        limits: limits,
        cancellationProgress: Progress(),
        progress: { _ in })
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
  }

  @Test("tarの非対応項目は実際の種別を示して拒否する")
  func rejectsUnsupportedTarEntriesWithSpecificTypes() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let cases: [(TarFixtureEntryType, ArchiveUnsupportedEntryType, String)] = [
      (.hardLink, .hardLink, "ハードリンク"),
      (.fifo, .fifo, "FIFO"),
      (.blockDevice, .blockDevice, "ブロックデバイス"),
      (.characterDevice, .characterDevice, "キャラクターデバイス"),
      (.contiguousFile, .contiguousFile, "連続ファイル"),
      (.unknown, .unknown, "不明な種別の項目"),
    ]

    for (fixtureType, expectedType, expectedDescription) in cases {
      let archiveURL = root.appending(path: "\(expectedType.rawValue).tar")
      try makeTarArchive(entries: [("special", fixtureType, Data())]).write(to: archiveURL)
      do {
        try TarArchiveCodec(format: .tar).extractArchive(
          at: archiveURL,
          to: destination,
          limits: .default,
          cancellationProgress: Progress(),
          progress: { _ in })
        Issue.record("非対応tar項目が展開されました: \(expectedType)")
      } catch ArchiveServiceError.unsupportedArchiveEntry(let path, let type, let format) {
        #expect(path == "special")
        #expect(type == expectedType)
        #expect(format == .tar)
        let classifiedError = ArchiveServiceError.unsupportedArchiveEntry(path, type, format)
        #expect(classifiedError.localizedDescription.contains(expectedDescription))
      } catch {
        Issue.record("想定外のエラー: \(error)")
      }
    }
  }

  @Test("tar codecはキャンセル済み処理を開始せず展開先を削除しない")
  func cancelledTarExtractionPreservesCallerOwnedDestination() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "sample.tar")
    try makeTarArchive(entries: [("a.txt", .regular, Data("a".utf8))]).write(to: archiveURL)
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let sentinel = destination.appending(path: "keep.txt")
    try Data("保持".utf8).write(to: sentinel)
    let cancellationProgress = Progress()
    cancellationProgress.cancel()

    #expect(throws: CancellationError.self) {
      try TarArchiveCodec(format: .tar).extractArchive(
        at: archiveURL,
        to: destination,
        limits: .default,
        cancellationProgress: cancellationProgress,
        progress: { _ in })
    }

    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "保持")
  }

  @Test("gz・bz2・xzを元の拡張子を除いた単一ファイルへ展開する")
  func extractsSingleFileCompressionFormats() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let content = Data("単体圧縮の本文".utf8)
    let xzData = try #require(Data(base64Encoded: Self.singleFileXzFixtureBase64))
    let fixtures: [(archiveName: String, archiveData: Data, expectedName: String, expected: Data)] =
      [
        ("report.txt.gz", try GzipArchive.archive(data: content), "report.txt", content),
        ("report.txt.bz2", BZip2.compress(data: content), "report.txt", content),
        ("greeting.txt.xz", xzData, "greeting.txt", Data("Hello, World!\n".utf8)),
      ]

    for fixture in fixtures {
      let caseRoot = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: true)
      let archiveURL = caseRoot.appending(path: fixture.archiveName)
      try fixture.archiveData.write(to: archiveURL)
      let progress = ProgressCollector()

      _ = try await ArchiveService().extractArchive(
        at: archiveURL,
        in: caseRoot,
        destination: .currentDirectory,
        progress: { progress.append($0) })

      #expect(
        try Data(contentsOf: caseRoot.appending(path: fixture.expectedName)) == fixture.expected)
      assertMonotonicCompletedProgress(progress.values)
    }
  }

  @Test("単体圧縮の出力名が衝突した場合は既存規則で連番にする")
  func singleFileExtractionUsesAvailableNumberedName() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("既存1".utf8).write(to: root.appending(path: "report.txt"))
    try Data("既存2".utf8).write(to: root.appending(path: "report2.txt"))
    let archiveURL = root.appending(path: "report.txt.gz")
    try GzipArchive.archive(data: Data("新規".utf8)).write(to: archiveURL)

    _ = try await ArchiveService().extractArchive(
      at: archiveURL,
      in: root,
      destination: .currentDirectory)

    #expect(try String(contentsOf: root.appending(path: "report.txt"), encoding: .utf8) == "既存1")
    #expect(try String(contentsOf: root.appending(path: "report2.txt"), encoding: .utf8) == "既存2")
    #expect(try String(contentsOf: root.appending(path: "report3.txt"), encoding: .utf8) == "新規")
  }

  @Test("単体圧縮codecは展開後サイズと圧縮率の上限を適用する")
  func appliesSingleFileCompressionSafetyLimits() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "large.txt.gz")
    try GzipArchive.archive(data: Data(repeating: 0, count: 4_096)).write(to: archiveURL)
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    let sizeLimit = ArchiveSafetyLimits(
      maximumEntryCount: 1,
      maximumUncompressedBytes: 1_024,
      maximumCompressionRatio: 100)
    #expect(throws: ArchiveServiceError.self) {
      try SingleFileCompressionCodec(format: .gzip).extractArchive(
        at: archiveURL,
        to: destination,
        limits: sizeLimit,
        cancellationProgress: Progress(),
        progress: { _ in })
    }

    let ratioLimit = ArchiveSafetyLimits(
      maximumEntryCount: 1,
      maximumUncompressedBytes: 8_192,
      maximumCompressionRatio: 1)
    #expect(throws: ArchiveServiceError.self) {
      try SingleFileCompressionCodec(format: .gzip).extractArchive(
        at: archiveURL,
        to: destination,
        limits: ratioLimit,
        cancellationProgress: Progress(),
        progress: { _ in })
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
  }

  @Test("gzip bombは全量展開前に圧縮率で停止し固定長バッファだけを使う")
  func rejectsGzipBombBeforeFullExpansionWithBoundedBuffers() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "one-gibibyte-bomb.gz")
    let outputURL = root.appending(path: "partial-output")
    // 1GiBのゼロ列を全量保持せず作る実gzip fixture。level 1では圧縮後が約4.5MiBになる。
    let bomb = try makeGzipBomb(uncompressedByteCount: 1 * 1_024 * 1_024 * 1_024)
    #expect(bomb.count > 4 * 1_024 * 1_024)
    #expect(bomb.count < 8 * 1_024 * 1_024)
    try bomb.write(to: archiveURL)
    let probe = StreamingDecompressionProbe()
    let chunkSize = 64 * 1_024
    let configuration = StreamingDecompressionConfiguration(
      inputChunkSize: chunkSize,
      outputChunkSize: chunkSize,
      ratioCheckMinimumOutputBytes: UInt64(256 * 1_024),
      didAllocateBuffers: { probe.recordAllocatedBytes($0) },
      didProduceOutput: { probe.recordProducedBytes($0) })
    let limits = ArchiveSafetyLimits(
      maximumEntryCount: 1,
      maximumUncompressedBytes: 16 * 1_024 * 1_024,
      maximumCompressionRatio: 1)

    do {
      _ = try StreamingArchiveDecoder.decompress(
        at: archiveURL,
        to: outputURL,
        format: .gzip,
        limits: limits,
        cancellationProgress: Progress(),
        configuration: configuration)
      Issue.record("gzip bombの全量展開が成功しました")
    } catch ArchiveServiceError.suspiciousCompressionRatio(_, let format) {
      #expect(format == .gzip)
    } catch {
      Issue.record("想定外のエラー: \(error)")
    }

    let partialSize = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    #expect(probe.maximumAllocatedBytes <= chunkSize * 2)
    #expect(probe.maximumProducedBytes <= UInt64(bomb.count))
    #expect(partialSize <= bomb.count)
    #expect(partialSize < 1 * 1_024 * 1_024 * 1_024)
  }

  @Test("gz・bz2・xz解除中のキャンセルは次の出力チャンク境界で停止する")
  func cancelsAllFormatsDuringStreamingDecompression() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // 出力チャンク64KiBを2回分用意し、初回出力後のキャンセルを次の境界で検出する。
    let content = Data(repeating: 0, count: 128 * 1_024)
    let fixtures: [(ArchiveFormat, Data)] = [
      (.gzip, try GzipArchive.archive(data: content)),
      (.bzip2, BZip2.compress(data: content)),
      (.xz, try #require(Data(base64Encoded: Self.singleFileXzFixtureBase64))),
    ]

    for (format, archiveData) in fixtures {
      let destination = root.appending(path: format.fileExtension, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      let archiveURL = root.appending(path: "large.txt.\(format.fileExtension)")
      try archiveData.write(to: archiveURL)
      let cancellationProgress = Progress()
      let configuration = StreamingDecompressionConfiguration(
        inputChunkSize: 64 * 1_024,
        outputChunkSize: 64 * 1_024,
        ratioCheckMinimumOutputBytes: 1 * 1_024 * 1_024,
        didAllocateBuffers: nil,
        didProduceOutput: { _ in cancellationProgress.cancel() })
      let limits = ArchiveSafetyLimits(
        maximumEntryCount: 1,
        maximumUncompressedBytes: 8 * 1_024 * 1_024,
        maximumCompressionRatio: .max)

      #expect(throws: CancellationError.self) {
        try SingleFileCompressionCodec(
          format: format,
          streamingConfiguration: configuration
        ).extractArchive(
          at: archiveURL,
          to: destination,
          limits: limits,
          cancellationProgress: cancellationProgress,
          progress: { _ in })
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }
  }

  @Test("単体圧縮codecはキャンセル時に呼び出し元所有の展開先を削除しない")
  func cancelledSingleFileExtractionPreservesCallerOwnedDestination() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "sample.txt.bz2")
    try BZip2.compress(data: Data("本文".utf8)).write(to: archiveURL)
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let sentinel = destination.appending(path: "keep.txt")
    try Data("保持".utf8).write(to: sentinel)
    let cancellationProgress = Progress()
    cancellationProgress.cancel()

    #expect(throws: CancellationError.self) {
      try SingleFileCompressionCodec(format: .bzip2).extractArchive(
        at: archiveURL,
        to: destination,
        limits: .default,
        cancellationProgress: cancellationProgress,
        progress: { _ in })
    }

    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "保持")
  }

  @Test("破損した単体圧縮データは形式別の処理失敗へ分類する")
  func corruptSingleFileCompressionMapsToOperationFailure() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    for format in [ArchiveFormat.gzip, .bzip2, .xz] {
      let archiveURL = root.appending(path: "broken.\(format.fileExtension)")
      try Data("破損".utf8).write(to: archiveURL)
      do {
        try SingleFileCompressionCodec(format: format).extractArchive(
          at: archiveURL,
          to: destination,
          limits: .default,
          cancellationProgress: Progress(),
          progress: { _ in })
        Issue.record("破損した\(format.displayName)が成功扱いになった")
      } catch ArchiveServiceError.operationFailed(let failedFormat) {
        #expect(failedFormat == format)
      } catch {
        Issue.record("想定外のエラー: \(error)")
      }
    }
  }

  @Test("RAR5とRAR4を既存の展開経路で展開する")
  func extractsRAR5AndRAR4ThroughArchiveService() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixtures: [(name: String, base64: String, expectedPath: String, expectedText: String)] = [
      (
        "rar5.rar", Self.rar5FixtureBase64, "README.md",
        "# Unrar\n\nA description of this package.\n"
      ),
      (
        "rar4.rar", ArchiveTestFixtures.windowsBackslashRAR4FixtureBase64,
        "アーカイブ/サンプル.txt", "こんにちは"
      ),
    ]

    for fixture in fixtures {
      let caseRoot = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: true)
      let archiveURL = caseRoot.appending(path: fixture.name)
      let archiveData = try #require(
        Data(base64Encoded: fixture.base64, options: .ignoreUnknownCharacters))
      try archiveData.write(to: archiveURL)
      let progress = ProgressCollector()

      _ = try await ArchiveService().extractArchive(
        at: archiveURL,
        in: caseRoot,
        destination: .currentDirectory,
        progress: { progress.append($0) })

      let actualText = try String(
        contentsOf: caseRoot.appending(path: fixture.expectedPath),
        encoding: .utf8)
      #expect(actualText == fixture.expectedText)
      assertMonotonicCompletedProgress(progress.values)
    }
  }

  @Test("Windows製RARのバックスラッシュ区切りを正規化して展開する")
  func extractsWindowsRARWithNormalizedBackslashPaths() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "windows-paths.rar")
    let archiveData = try #require(
      Data(
        base64Encoded: ArchiveTestFixtures.windowsBackslashRAR4FixtureBase64,
        options: .ignoreUnknownCharacters))
    try archiveData.write(to: archiveURL)

    _ = try await ArchiveService().extractArchive(
      at: archiveURL,
      in: root,
      destination: .currentDirectory)

    #expect(
      try String(
        contentsOf: root.appending(path: "アーカイブ/フォルダ/サンプル.txt"),
        encoding: .utf8) == "こんにちは")
  }

  @Test("RARパスは区切り正規化後にトラバーサルと絶対パスを拒否する")
  func validatesRARPathsAfterBackslashNormalization() throws {
    #expect(RARPathNormalizer.normalized("folder\\file.txt") == "folder/file.txt")
    let unsafePaths = ["..\\outside.txt", "\\absolute.txt", "C:\\absolute.txt"]
    for path in unsafePaths {
      let normalized = RARPathNormalizer.normalized(path)
      #expect(throws: ArchiveServiceError.self) {
        _ = try ArchiveEntrySafety.validatedPathComponents(normalized, format: .rar)
      }
    }
  }

  @Test("RARのリンク項目はシンボリックリンクとして出力せず展開を拒否する")
  func rejectsRARLinkEntryWithoutCreatingSymbolicLink() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "links.rar")
    let archiveData = try #require(
      Data(base64Encoded: Self.rarLinkFixtureBase64, options: .ignoreUnknownCharacters))
    try archiveData.write(to: archiveURL)

    await #expect(throws: ArchiveServiceError.self) {
      _ = try await ArchiveService().extractArchive(
        at: archiveURL,
        in: root,
        destination: .currentDirectory)
    }

    let linkOutput = root.appending(path: "testlink")
    #expect(!FileManager.default.fileExists(atPath: linkOutput.path))
  }

  @Test("RAR codecは件数・展開後サイズ・圧縮率の上限を出力前に適用する")
  func appliesRARSafetyLimitsBeforeWriting() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "sample.rar")
    let archiveData = try #require(
      Data(base64Encoded: Self.rar5FixtureBase64, options: .ignoreUnknownCharacters))
    try archiveData.write(to: archiveURL)
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let limits = ArchiveSafetyLimits(
      maximumEntryCount: 1,
      maximumUncompressedBytes: 20,
      maximumCompressionRatio: 1)

    #expect(throws: ArchiveServiceError.self) {
      try RARArchiveCodec().extractArchive(
        at: archiveURL,
        to: destination,
        limits: limits,
        cancellationProgress: Progress(),
        progress: { _ in })
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
  }

  @Test("RAR codecはキャンセル時に呼び出し元所有の展開先を削除しない")
  func cancelledRARExtractionPreservesCallerOwnedDestination() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "sample.rar")
    let archiveData = try #require(
      Data(base64Encoded: Self.rar5FixtureBase64, options: .ignoreUnknownCharacters))
    try archiveData.write(to: archiveURL)
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let sentinel = destination.appending(path: "keep.txt")
    try Data("保持".utf8).write(to: sentinel)
    let cancellationProgress = Progress()
    cancellationProgress.cancel()

    #expect(throws: CancellationError.self) {
      try RARArchiveCodec().extractArchive(
        at: archiveURL,
        to: destination,
        limits: .default,
        cancellationProgress: cancellationProgress,
        progress: { _ in })
    }
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "保持")
  }

  @Test("暗号化RARは専用の非対応エラーへ分類し何も出力しない")
  func rejectsEncryptedRARWithSpecificError() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "encrypted.rar")
    let archiveData = try #require(
      Data(base64Encoded: Self.encryptedRARFixtureBase64, options: .ignoreUnknownCharacters))
    try archiveData.write(to: archiveURL)
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    do {
      try RARArchiveCodec().extractArchive(
        at: archiveURL,
        to: destination,
        limits: .default,
        cancellationProgress: Progress(),
        progress: { _ in })
      Issue.record("暗号化RARが成功扱いになった")
    } catch ArchiveServiceError.encryptedArchive(let format) {
      #expect(format == .rar)
    } catch {
      Issue.record("想定外のエラー: \(error)")
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
  }

  @Test("7z圧縮はファイルを含む階層を保持し空フォルダを含めない")
  func createsSevenZipArchiveWithNestedItems() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceFile = root.appending(path: "メモ.txt")
    let sourceFolder = root.appending(path: "資料", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sourceFolder.appending(path: "内側", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: sourceFolder.appending(path: "空", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try Data("本文".utf8).write(to: sourceFile)
    try Data("報告".utf8).write(to: sourceFolder.appending(path: "内側/報告.txt"))
    let progress = ProgressCollector()
    let service = ArchiveService(codecs: [.sevenZip: SevenZipArchiveCodec()])

    let archiveURL = try await service.createArchive(
      from: [sourceFile, sourceFolder],
      in: root,
      name: "資料.7z",
      format: .sevenZip,
      progress: { progress.append($0) })

    let decoder = try Decoder(
      stream: try InStream(path: Path(archiveURL.path)),
      fileType: .sevenZ)
    #expect(try decoder.open())
    let itemPaths = try (0..<decoder.count()).map { index in
      try decoder.item(at: index).path().description
    }
    #expect(itemPaths.contains("メモ.txt"))
    #expect(itemPaths.contains("資料/内側/報告.txt"))
    #expect(!itemPaths.contains("資料/空"))
    #expect(!itemPaths.contains("資料/空/"))
    let decodedDirectory = root.appending(path: "decoded", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: decodedDirectory,
      withIntermediateDirectories: true)
    #expect(try decoder.extract(to: Path(decodedDirectory.path)))
    #expect(try Data(contentsOf: decodedDirectory.appending(path: "メモ.txt")) == Data("本文".utf8))
    #expect(
      try Data(contentsOf: decodedDirectory.appending(path: "資料/内側/報告.txt"))
        == Data("報告".utf8))
    #expect(
      !FileManager.default.fileExists(
        atPath: decodedDirectory.appending(path: "資料/空", directoryHint: .isDirectory).path))
    let serviceDecodedDirectory = root.appending(
      path: "service-decoded", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: serviceDecodedDirectory,
      withIntermediateDirectories: true)
    _ = try await service.extractArchive(
      at: archiveURL,
      in: serviceDecodedDirectory,
      destination: .currentDirectory)
    #expect(
      try Data(contentsOf: serviceDecodedDirectory.appending(path: "資料/内側/報告.txt"))
        == Data("報告".utf8))
    assertMonotonicCompletedProgress(progress.values)
  }

  @Test("処理中にキャンセルされた7z圧縮は生成物を残さない")
  func cancelsSevenZipCreationWithoutLeavingPartialOutput() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source.txt")
    let destination = root.appending(path: "cancelled.7z")
    try pseudoRandomData(byteCount: 4 * 1_024 * 1_024).write(to: source)
    let cancellationProgress = Progress()
    let reportedProgress = ProgressCollector()
    let codec = SevenZipArchiveCodec()

    #expect(throws: CancellationError.self) {
      try codec.createArchive(
        from: [source],
        to: destination,
        cancellationProgress: cancellationProgress,
        progress: { value in
          reportedProgress.append(value)
          if value.completedBytes > 0 {
            cancellationProgress.cancel()
          }
        })
    }

    #expect(reportedProgress.values.contains { $0.completedBytes > 0 })
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test("7zを安全検証後に展開し内容と進捗を返す")
  func extractsSevenZipArchiveAfterSafetyValidation() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceRoot = root.appending(path: "source", directoryHint: .isDirectory)
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sourceRoot.appending(path: "nested", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let source = sourceRoot.appending(path: "nested/report.txt")
    try Data("7z本文".utf8).write(to: source)
    let archiveURL = root.appending(path: "sample.7z")
    try makeSevenZipArchive(entries: [(source, "nested/report.txt")], at: archiveURL)
    let progress = ProgressCollector()

    _ = try await ArchiveService().extractArchive(
      at: archiveURL,
      in: destination,
      destination: .currentDirectory,
      progress: { progress.append($0) })

    #expect(
      try Data(contentsOf: destination.appending(path: "nested/report.txt"))
        == Data("7z本文".utf8))
    assertMonotonicCompletedProgress(progress.values)
  }

  @Test("7zの危険な相対パスを展開前に拒否する")
  func rejectsSevenZipPathTraversalBeforeExtraction() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source.txt")
    let archiveURL = root.appending(path: "unsafe.7z")
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try Data("source".utf8).write(to: source)
    try makeSevenZipArchive(entries: [(source, "../outside.txt")], at: archiveURL)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    do {
      _ = try await ArchiveService().extractArchive(
        at: archiveURL,
        in: destination,
        destination: .currentDirectory)
      Issue.record("危険な相対パスを含む7zの展開が成功しました")
    } catch let error as ArchiveServiceError {
      guard case .unsafeEntryPath(let path, let format) = error else {
        Issue.record("想定外のArchiveServiceErrorです: \(error)")
        return
      }
      #expect(path == "../outside.txt")
      #expect(format == .sevenZip)
    }

    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "outside.txt").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
  }

  @Test("7zの異常な圧縮率を展開前に拒否する")
  func rejectsSevenZipSuspiciousCompressionRatio() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "bomb.txt")
    let archiveURL = root.appending(path: "bomb.7z")
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try Data(repeating: 0x41, count: 256 * 1_024).write(to: source)
    try makeSevenZipArchive(entries: [(source, "bomb.txt")], at: archiveURL)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let limits = ArchiveSafetyLimits(
      maximumEntryCount: 10,
      maximumUncompressedBytes: 1_024 * 1_024,
      maximumCompressionRatio: 2)

    do {
      _ = try await ArchiveService(limits: limits).extractArchive(
        at: archiveURL,
        in: destination,
        destination: .currentDirectory)
      Issue.record("異常な圧縮率の7z展開が成功しました")
    } catch let error as ArchiveServiceError {
      guard case .suspiciousCompressionRatio(_, let format) = error else {
        Issue.record("想定外のArchiveServiceErrorです: \(error)")
        return
      }
      #expect(format == .sevenZip)
    }

    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
  }

  @Test("7zの項目数上限超過を展開前に拒否する")
  func rejectsSevenZipEntryCountLimit() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appending(path: "first.txt")
    let second = root.appending(path: "second.txt")
    let archiveURL = root.appending(path: "too-many.7z")
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    try makeSevenZipArchive(
      entries: [(first, "first.txt"), (second, "second.txt")],
      at: archiveURL)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let limits = ArchiveSafetyLimits(
      maximumEntryCount: 1,
      maximumUncompressedBytes: 1_024,
      maximumCompressionRatio: 100)

    do {
      _ = try await ArchiveService(limits: limits).extractArchive(
        at: archiveURL,
        in: destination,
        destination: .currentDirectory)
      Issue.record("項目数上限を超える7z展開が成功しました")
    } catch let error as ArchiveServiceError {
      guard case .tooManyEntries(let format) = error else {
        Issue.record("想定外のArchiveServiceErrorです: \(error)")
        return
      }
      #expect(format == .sevenZip)
    }

    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
  }

  @Test("展開後ツリーのシンボリックリンク検出は呼び出し元の出力を削除しない")
  func preservesSevenZipOutputWhenPostflightFindsSymbolicLink() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appending(path: "output", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try Data("regular".utf8).write(to: output.appending(path: "regular.txt"))
    try FileManager.default.createSymbolicLink(
      at: output.appending(path: "shortcut"),
      withDestinationURL: root.appending(path: "outside.txt"))

    do {
      try SevenZipPostExtractionSafety.validateNoSymbolicLinks(in: output)
      Issue.record("シンボリックリンクを含む出力が検証を通過しました")
    } catch let error as ArchiveServiceError {
      guard case .symbolicLinkEntry(let path, let format) = error else {
        Issue.record("想定外のArchiveServiceErrorです: \(error)")
        return
      }
      #expect(path == "shortcut")
      #expect(format == .sevenZip)
    }

    #expect(FileManager.default.fileExists(atPath: output.path))
    #expect(FileManager.default.fileExists(atPath: output.appending(path: "regular.txt").path))
  }

  @Test("7z展開前に項目の親を実ディレクトリとして作成する")
  func createsActualParentDirectoriesBeforeSevenZipExtraction() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appending(path: "output", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let nestedOutput = try ArchiveEntrySafety.outputURL(
      for: "link/nested/file.txt",
      in: output,
      format: .sevenZip)

    try ArchivePreExtractionSafety.prepareDirectories(
      for: [nestedOutput],
      in: output,
      format: .sevenZip)

    let linkValues = try output.appending(path: "link").resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    let nestedValues = try output.appending(path: "link/nested").resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    #expect(linkValues.isDirectory == true)
    #expect(linkValues.isSymbolicLink == false)
    #expect(nestedValues.isDirectory == true)
    #expect(nestedValues.isSymbolicLink == false)
  }

  @Test("PLzmaSDKが7z内シンボリックリンクを通常ファイルとして書き出す挙動を固定する")
  func plzmaSDKMaterializesSevenZipSymbolicLinkAsRegularFile() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appending(path: "target.txt")
    let symbolicLink = root.appending(path: "shortcut")
    let archiveURL = root.appending(path: "symbolic-link.7z")
    let output = root.appending(path: "sdk-output", directoryHint: .isDirectory)
    try Data("target".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: target)
    try makeSevenZipArchive(entries: [(symbolicLink, "shortcut")], at: archiveURL)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    let decoder = try Decoder(
      stream: try InStream(path: Path(archiveURL.path)),
      fileType: .sevenZ)
    #expect(try decoder.open())
    #expect(try decoder.extract(to: Path(output.path)))

    let extracted = output.appending(path: "shortcut")
    let values = try extracted.resourceValues(forKeys: [.isSymbolicLinkKey])
    #expect(values.isSymbolicLink == false)
    #expect(try Data(contentsOf: extracted) == Data("target".utf8))
  }

  @Test("7z展開のキャンセル時にcodecは呼び出し元の出力を削除しない")
  func cancelledSevenZipExtractionPreservesCallerOutput() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "large.bin")
    let archiveURL = root.appending(path: "large.7z")
    let output = root.appending(path: "output", directoryHint: .isDirectory)
    // SDKのLZMA2展開は4MiBごとに進捗を通知するため、後続1MiBを残して途中で止める。
    try pseudoRandomData(byteCount: 5 * 1_024 * 1_024).write(to: source)
    try makeSevenZipArchive(entries: [(source, "large.bin")], at: archiveURL)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let sentinel = output.appending(path: "caller-owned.txt")
    try Data("keep".utf8).write(to: sentinel)
    let cancellationProgress = Progress()
    let reportedProgress = ProgressCollector()

    #expect(throws: CancellationError.self) {
      try SevenZipArchiveCodec().extractArchive(
        at: archiveURL,
        to: output,
        limits: .default,
        cancellationProgress: cancellationProgress,
        progress: { value in
          reportedProgress.append(value)
          if value.completedBytes > 0 && value.completedBytes < value.totalBytes {
            cancellationProgress.cancel()
          }
        })
    }

    #expect(
      reportedProgress.values.contains {
        $0.completedBytes > 0 && $0.completedBytes < $0.totalBytes
      })
    #expect(FileManager.default.fileExists(atPath: output.path))
    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
  }

  @Test("同じ親を持つ項目のZIP保存先はその親になる")
  func findsSharedParentForSiblingItems() throws {
    let parents = [
      URL(fileURLWithPath: "/Users/test/Downloads/point", isDirectory: true),
      URL(fileURLWithPath: "/Users/test/Downloads/point", isDirectory: true),
    ]

    let destination = ArchiveDestinationDirectory.deepestCommonAncestor(of: parents)

    #expect(destination?.path == "/Users/test/Downloads/point")
  }

  @Test("異なる階層の項目は最深共通親へ保存する")
  func findsDeepestCommonParentAcrossLevels() throws {
    let parents = [
      URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true),
      URL(fileURLWithPath: "/Users/test/Downloads/point", isDirectory: true),
    ]

    let destination = ArchiveDestinationDirectory.deepestCommonAncestor(of: parents)

    #expect(destination?.path == "/Users/test/Downloads")
  }

  @Test("ファイルとフォルダの選択は各項目の親から保存先を決める")
  func findsCommonParentForFileAndFolderSelection() throws {
    let fileURL = URL(fileURLWithPath: "/Users/test/Downloads/report.txt")
    let folderURL = URL(fileURLWithPath: "/Users/test/Downloads/point", isDirectory: true)

    let destination = ArchiveDestinationDirectory.deepestCommonAncestor(
      of: [fileURL, folderURL].map { $0.deletingLastPathComponent() })

    #expect(destination?.path == "/Users/test/Downloads")
  }

  @Test("通常パスはシンボリックリンク解決を行わず文字列だけで共通親を求める")
  func usesStandardizedPathWithoutResolvingSymbolicLinks() throws {
    let parents = [
      URL(fileURLWithPath: "/Users/test/Downloads/point/../point", isDirectory: true),
      URL(fileURLWithPath: "/Users/test/Downloads/point", isDirectory: true),
    ]

    let destination = ArchiveDestinationDirectory.deepestCommonAncestor(of: parents)

    #expect(destination?.path == "/Users/test/Downloads/point")
  }

  @Test("異なるボリュームの項目を共通のVolumesディレクトリへ保存しない")
  func rejectsParentsAcrossVolumeBoundaries() throws {
    let parents = [
      URL(fileURLWithPath: "/Volumes/First/Documents", isDirectory: true),
      URL(fileURLWithPath: "/Volumes/Second/Documents", isDirectory: true),
    ]

    #expect(ArchiveDestinationDirectory.deepestCommonAncestor(of: parents) == nil)
  }

  @Test("希望するZIP名が未使用ならそのまま採用する")
  func keepsAvailableArchiveName() {
    let name = ArchiveAvailableName.resolving(preferredName: "Archive.zip") { _ in false }

    #expect(name == "Archive.zip")
  }

  @Test("連続する連番ZIP名を飛ばして最初の未使用名を採用する")
  func skipsConsecutiveConflictingArchiveNames() {
    let existingNames = Set(["Archive.zip", "Archive2.zip", "Archive3.zip"])

    let name = ArchiveAvailableName.resolving(preferredName: "Archive.zip") {
      existingNames.contains($0)
    }

    #expect(name == "Archive4.zip")
  }

  @Test("単一項目由来の名前でもZIP拡張子を末尾に維持する")
  func preservesArchiveExtensionWhenAddingSequence() {
    let existingNames = Set(["report.txt.zip"])

    let name = ArchiveAvailableName.resolving(preferredName: "report.txt.zip") {
      existingNames.contains($0)
    }

    #expect(name == "report.txt2.zip")
  }

  @Test("Unicode名のファイルとフォルダをZIPへ圧縮して展開する")
  func compressesAndExtractsUnicodeItems() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "資料", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: source.appending(path: "内側", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try Data("こんにちは".utf8).write(to: source.appending(path: "内側/報告.txt"))
    let service = ArchiveService()

    let archive = try await service.createArchive(
      from: [source],
      in: root,
      name: "資料.zip")
    let output = try await service.extractArchive(
      at: archive,
      in: root.appending(path: "展開先", directoryHint: .isDirectory),
      destination: .folderNamedAfterArchive)

    // outputは「展開先/資料」自体を指すため、直下は圧縮元ディレクトリの中身になる。
    #expect(FileManager.default.fileExists(atPath: output.appending(path: "内側/報告.txt").path))
  }

  @Test("アーカイブ名と異なる内側フォルダ名は保持したまま展開する")
  func preservesInnerFolderNameWhenItDiffersFromArchiveName() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // 他ツール製ZIP(例: photos-2024.zipの中身がPhotos 2024 Backup/)を模して、
    // 圧縮元ディレクトリ名とアーカイブ名を意図的に一致させない。
    let source = root.appending(path: "Photos 2024 Backup", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("写真".utf8).write(to: source.appending(path: "photo.txt"))
    let service = ArchiveService()

    let archive = try await service.createArchive(
      from: [source],
      in: root,
      name: "photos-2024.zip")
    let output = try await service.extractArchive(
      at: archive,
      in: root.appending(path: "展開先", directoryHint: .isDirectory),
      destination: .folderNamedAfterArchive)

    // アーカイブ名(photos-2024)と内側フォルダ名(Photos 2024 Backup)が異なるため
    // unwrapされず、展開先/photos-2024/Photos 2024 Backup/... の構造が保たれる。
    #expect(
      FileManager.default.fileExists(
        atPath: output.appending(path: "Photos 2024 Backup/photo.txt").path))
  }

  @Test("ZIP64のUTF-8ファイル名を展開する")
  func extractsZIP64ArchiveWithUnicodeFileName() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "zip64.zip")
    let destination = root.appending(path: "展開先", directoryHint: .isDirectory)
    try makeZIP64Archive(named: "資料.txt").write(to: archiveURL)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let service = ArchiveService()

    _ = try await service.extractArchive(
      at: archiveURL,
      in: destination,
      destination: .currentDirectory)

    #expect(FileManager.default.fileExists(atPath: destination.appending(path: "資料.txt").path))
  }

  @Test("ZIP64のUTF-8ファイル名をアーカイブProviderで一覧する")
  func listsZIP64ArchiveWithUnicodeFileName() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "zip64.zip")
    try makeZIP64Archive(named: "資料.txt").write(to: archiveURL)
    let provider = try ArchiveFileProvider(archiveURL: archiveURL)

    let items = try await provider.contents(of: provider.rootLocation)

    #expect(items.map(\.name) == ["資料.txt"])
    #expect(items.first?.size == 0)
  }

  @Test("UTF-8フラグなしZIPのUTF-8ファイル名を展開する")
  func extractsZIPWithoutUTF8FlagUsingUTF8FileName() async throws {
    // macOSのFinder(アーカイブユーティリティ)はUTF-8名を格納しながら
    // general purpose bit flagのEFSビット(bit 11)を立てないZIPを作る。
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "finder.zip")
    let destination = root.appending(path: "展開先", directoryHint: .isDirectory)
    try makeZIPArchiveWithoutUTF8Flag(named: "スクリーンショット.png").write(to: archiveURL)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let service = ArchiveService()

    _ = try await service.extractArchive(
      at: archiveURL,
      in: destination,
      destination: .currentDirectory)

    #expect(
      FileManager.default.fileExists(
        atPath: destination.appending(path: "スクリーンショット.png").path))
  }

  @Test("UTF-8フラグなしZIPのUTF-8ファイル名をアーカイブProviderで一覧する")
  func listsZIPWithoutUTF8FlagUsingUTF8FileName() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "finder.zip")
    try makeZIPArchiveWithoutUTF8Flag(named: "スクリーンショット.png").write(to: archiveURL)
    let provider = try ArchiveFileProvider(archiveURL: archiveURL)

    let items = try await provider.contents(of: provider.rootLocation)

    #expect(items.map(\.name) == ["スクリーンショット.png"])
  }

  @Test("UTF-8フラグなしZIPの日本語名エントリをQuick Look用に展開できる")
  func previewsEntryWithoutUTF8FlagUsingUTF8FileName() async throws {
    // indexが保存するarchivePathはresolvedPath(UTF-8優先)だが、Archiveの
    // subscriptはフラグ依存のpathで照合するため、previewURLがindex構築時と
    // 同じ名前を再度探し当てられるかを検証する(archiveChangedへ誤って
    // 落ちないことの確認)。
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "finder.zip")
    try makeZIPArchiveWithoutUTF8Flag(named: "スクリーンショット.png").write(to: archiveURL)
    let provider = try ArchiveFileProvider(archiveURL: archiveURL)
    let item = try #require(try await provider.contents(of: provider.rootLocation).first)

    let previewURL = try await provider.previewURL(for: item)

    #expect(try Data(contentsOf: previewURL).isEmpty)
  }

  @Test("Shift-JIS名のZIPをCP932として解釈して一覧する")
  func listsZIPWithShiftJISFileName() async throws {
    // 日本語Windowsのエクスプローラーで圧縮したZIPはCP932名でEFSビットを立てない。
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "windows.zip")
    // 「資料.txt」のCP932バイト列。UTF-8としてもEUC-JPとしても不正。
    try makeZIPArchiveWithoutUTF8Flag(
      nameBytes: Data([0x8E, 0x91, 0x97, 0xBF, 0x2E, 0x74, 0x78, 0x74])
    ).write(to: archiveURL)
    let provider = try ArchiveFileProvider(archiveURL: archiveURL)

    let items = try await provider.contents(of: provider.rootLocation)

    #expect(items.map(\.name) == ["資料.txt"])
  }

  @Test("EUC-JP名のZIPは半角カナ誤解釈を避けてEUC-JPとして一覧する")
  func listsZIPWithEUCJPFileName() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "eucjp.zip")
    // 「資料.txt」のEUC-JPバイト列。CP932としても半角カナ混じりで
    // デコードできてしまうため、半角カナの少ない解釈を選ぶ判定を検証する。
    try makeZIPArchiveWithoutUTF8Flag(
      nameBytes: Data([0xBB, 0xF1, 0xCE, 0xC1, 0x2E, 0x74, 0x78, 0x74])
    ).write(to: archiveURL)
    let provider = try ArchiveFileProvider(archiveURL: archiveURL)

    let items = try await provider.contents(of: provider.rootLocation)

    #expect(items.map(\.name) == ["資料.txt"])
  }

  @Test("半角カナのみのCP932名のZIPは半角カナ優先でCP932として一覧する")
  func listsZIPWithCP932HalfWidthKatakanaFileName() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "halfwidth.zip")
    // 「ｶﾀｶﾅ.txt」のCP932バイト列(半角カナのみ)。EUC-JPとしても往復一致する
    // 対称ケースで、EUC-JP側は半角カナを含まない別の漢字にデコードされる
    // ため、半角カナ最少スコアリングだけでは誤ってEUC-JPを採用してしまう。
    try makeZIPArchiveWithoutUTF8Flag(
      nameBytes: Data([0xB6, 0xC0, 0xB6, 0xC5, 0x2E, 0x74, 0x78, 0x74])
    ).write(to: archiveURL)
    let provider = try ArchiveFileProvider(archiveURL: archiveURL)

    let items = try await provider.contents(of: provider.rootLocation)

    #expect(items.map(\.name) == ["ｶﾀｶﾅ.txt"])
  }

  @Test("EUC-JPの読点名のZIPは半角句読点への誤読を避けてEUC-JPとして一覧する")
  func listsZIPWithEUCJPReadingPointFileName() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "eucjp-touten.zip")
    // 「、.txt」のEUC-JPバイト列。CP932として誤読すると半角句読点(U+FF61-FF65)
    // を含むASCII+半角カナのみの文字列(「｡｢.txt」)にデコードできてしまい
    // 往復検証も通過する対称ケースで、半角カナ最少スコアリングの短絡則が
    // 句読点を区別しないと誤ってCP932を採用してしまう。
    try makeZIPArchiveWithoutUTF8Flag(
      nameBytes: Data([0xA1, 0xA2, 0x2E, 0x74, 0x78, 0x74])
    ).write(to: archiveURL)
    let provider = try ArchiveFileProvider(archiveURL: archiveURL)

    let items = try await provider.contents(of: provider.rootLocation)

    #expect(items.map(\.name) == ["、.txt"])
  }

  @Test("EUC-JPの中黒名のZIPは半角句読点への誤読を避けてEUC-JPとして一覧する")
  func listsZIPWithEUCJPMiddleDotFileName() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "eucjp-nakaguro.zip")
    // 「・.txt」のEUC-JPバイト列。CP932として誤読すると半角句読点(U+FF61-FF65)
    // を含むASCII+半角カナのみの文字列(「｡ｦ.txt」)にデコードできてしまい
    // 往復検証も通過する対称ケースで、半角カナ最少スコアリングの短絡則が
    // 句読点を区別しないと誤ってCP932を採用してしまう。
    try makeZIPArchiveWithoutUTF8Flag(
      nameBytes: Data([0xA1, 0xA6, 0x2E, 0x74, 0x78, 0x74])
    ).write(to: archiveURL)
    let provider = try ArchiveFileProvider(archiveURL: archiveURL)

    let items = try await provider.contents(of: provider.rootLocation)

    #expect(items.map(\.name) == ["・.txt"])
  }

  @Test("EUC-JPの複数エントリZIPは非曖昧な名前をアンカーに曖昧な名前も正しく一覧する")
  func listsZIPWithEUCJPArchiveUsingUnambiguousEntryAsAnchor() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "eucjp-multi.zip")
    // 「山田.txt」はCP932としても半角カナのみにデコードできてしまい単体では
    // 曖昧(短絡則がCP932を誤採用する)だが、「田中.txt」はCP932としては
    // 「中」のトレイルバイト0xE6が0xDFを超え往復検証を通らないためEUC-JPと
    // 確定できる。実ZIPは同一アーカイブ内の全エントリが同じエンコーディング
    // で名付けられるため、この非曖昧なエントリをアンカーにアーカイブ全体を
    // EUC-JPと判定すれば、単体では曖昧な「山田.txt」も正しく解決できるべき。
    try makeZIPArchiveWithoutUTF8Flag(
      entryNameBytes: [
        Data([0xBB, 0xB3, 0xC5, 0xC4, 0x2E, 0x74, 0x78, 0x74]),
        Data([0xC5, 0xC4, 0xC3, 0xE6, 0x2E, 0x74, 0x78, 0x74]),
      ]
    ).write(to: archiveURL)
    let provider = try ArchiveFileProvider(archiveURL: archiveURL)

    let items = try await provider.contents(of: provider.rootLocation)

    #expect(items.map(\.name) == ["山田.txt", "田中.txt"])
  }

  @Test("Shift-JIS名のZIPをデコード済みの名前で展開する")
  func extractsZIPWithShiftJISFileName() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "windows.zip")
    let destination = root.appending(path: "展開先", directoryHint: .isDirectory)
    try makeZIPArchiveWithoutUTF8Flag(
      nameBytes: Data([0x8E, 0x91, 0x97, 0xBF, 0x2E, 0x74, 0x78, 0x74])
    ).write(to: archiveURL)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let service = ArchiveService()

    _ = try await service.extractArchive(
      at: archiveURL,
      in: destination,
      destination: .currentDirectory)

    #expect(FileManager.default.fileExists(atPath: destination.appending(path: "資料.txt").path))
  }

  @Test("UTF-8として不正な名前のZIPは従来どおりCP437で解釈する")
  func fallsBackToCodepage437ForInvalidUTF8FileName() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "legacy.zip")
    // 0xE9はCP437で「Θ」。単独ではUTF-8として不正なバイト列。
    try makeZIPArchiveWithoutUTF8Flag(nameBytes: Data([0x72, 0xE9, 0x2E, 0x74, 0x78, 0x74]))
      .write(to: archiveURL)
    let provider = try ArchiveFileProvider(archiveURL: archiveURL)

    let items = try await provider.contents(of: provider.rootLocation)

    #expect(items.map(\.name) == ["rΘ.txt"])
  }

  @Test("複数項目のZIP圧縮と現在フォルダへの展開")
  func compressesMultipleItemsAndExtractsToCurrentDirectory() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appending(path: "first.txt")
    let second = root.appending(path: "second", directoryHint: .isDirectory)
    try Data("first".utf8).write(to: first)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try Data("second".utf8).write(to: second.appending(path: "child.txt"))
    let service = ArchiveService()

    let archive = try await service.createArchive(
      from: [first, second],
      in: root,
      name: "items.zip")
    let destination = root.appending(path: "展開先", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    _ = try await service.extractArchive(
      at: archive,
      in: destination,
      destination: .currentDirectory)

    #expect(
      FileManager.default.fileExists(atPath: destination.appending(path: "first.txt").path))
    #expect(
      FileManager.default.fileExists(atPath: destination.appending(path: "second/child.txt").path))
  }

  @Test("大きな1ファイルのZIP処理中にも進捗を通知する")
  func reportsIncrementalProgressForSingleLargeFile() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "large.bin")
    // ZIPFoundationの既定バッファ16KiBを8回分通し、圧縮・展開の途中進捗を検出する。
    try pseudoRandomData(byteCount: 128 * 1_024).write(to: source)
    let compressionProgress = ProgressCollector()
    let service = ArchiveService()

    let archive = try await service.createArchive(
      from: [source],
      in: root,
      name: "large.zip",
      progress: { compressionProgress.append($0) })

    let extractionProgress = ProgressCollector()
    let destination = root.appending(path: "展開先", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    _ = try await service.extractArchive(
      at: archive,
      in: destination,
      destination: .currentDirectory,
      progress: { extractionProgress.append($0) })

    assertIncludesIntermediateProgress(compressionProgress.values)
    assertIncludesIntermediateProgress(extractionProgress.values)
  }

  @Test("既存のZIPを置き換えず連番名で新しいZIPを作成する")
  func createsNumberedArchiveWithoutReplacingExistingArchive() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "report.txt")
    let destination = root.appending(path: "report.zip")
    try Data("source".utf8).write(to: source)
    try Data("existing".utf8).write(to: destination)
    let service = ArchiveService()

    let archive = try await service.createArchive(from: [source], in: root, name: "report.zip")

    #expect(try Data(contentsOf: destination) == Data("existing".utf8))
    #expect(archive.lastPathComponent == "report2.zip")
    #expect(FileManager.default.fileExists(atPath: archive.path))
  }

  @Test("過剰な圧縮率のZIPは展開前に拒否する")
  func rejectsArchiveBombBeforeExtraction() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "large.txt")
    let archiveURL = root.appending(path: "large.zip")
    try Data(repeating: 0x41, count: 128 * 1_024).write(to: source)
    let archive = try Archive(url: archiveURL, accessMode: .create)
    try archive.addEntry(with: "large.txt", fileURL: source, compressionMethod: .deflate)
    let service = ArchiveService(
      limits: .init(
        maximumEntryCount: 10,
        maximumUncompressedBytes: 1_024 * 1_024,
        maximumCompressionRatio: 2))
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    await #expect(throws: ArchiveServiceError.self) {
      try await service.extractArchive(
        at: archiveURL,
        in: destination,
        destination: .folderNamedAfterArchive)
    }

    #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "large").path))
  }

  @Test("Zip Slipを展開前に拒否する")
  func rejectsZipSlipBeforeExtraction() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source.txt")
    let archiveURL = root.appending(path: "unsafe.zip")
    try Data("source".utf8).write(to: source)
    let archive = try Archive(url: archiveURL, accessMode: .create)
    try archive.addEntry(with: "../outside.txt", fileURL: source, compressionMethod: .deflate)
    let service = ArchiveService()
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    await #expect(throws: ArchiveServiceError.self) {
      try await service.extractArchive(
        at: archiveURL,
        in: destination,
        destination: .currentDirectory)
    }

    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "outside.txt").path))
  }

  @Test("シンボリックリンクを含むZIPを展開前に拒否する")
  func rejectsSymbolicLinkBeforeExtraction() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source.txt")
    let symbolicLink = root.appending(path: "shortcut")
    let archiveURL = root.appending(path: "unsafe-link.zip")
    try Data("source".utf8).write(to: source)
    try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: source)
    let archive = try Archive(url: archiveURL, accessMode: .create)
    try archive.addEntry(with: "shortcut", fileURL: symbolicLink, compressionMethod: .none)
    let service = ArchiveService()
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    await #expect(throws: ArchiveServiceError.self) {
      try await service.extractArchive(
        at: archiveURL,
        in: destination,
        destination: .currentDirectory)
    }

    #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "shortcut").path))
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private enum TarFixtureEntryType: Equatable {
    case regular
    case directory
    case symbolicLink
    case hardLink
    case fifo
    case blockDevice
    case characterDevice
    case contiguousFile
    case unknown

    var typeFlag: UInt8 {
      switch self {
      case .regular: Character("0").asciiValue!
      case .directory: Character("5").asciiValue!
      case .symbolicLink: Character("2").asciiValue!
      case .hardLink: Character("1").asciiValue!
      case .fifo: Character("6").asciiValue!
      case .blockDevice: Character("4").asciiValue!
      case .characterDevice: Character("3").asciiValue!
      case .contiguousFile: Character("7").asciiValue!
      case .unknown: Character("9").asciiValue!
      }
    }
  }

  private func makeGzipBomb(uncompressedByteCount: Int) throws -> Data {
    var stream = z_stream()
    guard
      deflateInit2_(
        &stream,
        Z_BEST_SPEED,
        Z_DEFLATED,
        15 + 16,
        8,
        Z_DEFAULT_STRATEGY,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)) == Z_OK
    else {
      throw ArchiveServiceError.operationFailed(.gzip)
    }
    defer { deflateEnd(&stream) }

    let inputChunkSize = 1 * 1_024 * 1_024
    let input = [UInt8](repeating: 0, count: inputChunkSize)
    var outputBuffer = [UInt8](repeating: 0, count: 64 * 1_024)
    var archive = Data()
    var remaining = uncompressedByteCount
    while remaining > 0 {
      let byteCount = min(remaining, inputChunkSize)
      try input.withUnsafeBytes { rawInput in
        stream.next_in = UnsafeMutablePointer<Bytef>(
          mutating: rawInput.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = UInt32(byteCount)
        while stream.avail_in > 0 {
          let status = outputBuffer.withUnsafeMutableBytes { rawOutput -> Int32 in
            stream.next_out = rawOutput.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = UInt32(rawOutput.count)
            let status = deflate(&stream, Z_NO_FLUSH)
            archive.append(
              rawOutput.bindMemory(to: UInt8.self).baseAddress!,
              count: rawOutput.count - Int(stream.avail_out))
            return status
          }
          guard status == Z_OK else { throw ArchiveServiceError.operationFailed(.gzip) }
        }
      }
      remaining -= byteCount
    }

    var status = Int32(Z_OK)
    repeat {
      status = outputBuffer.withUnsafeMutableBytes { rawOutput -> Int32 in
        stream.next_out = rawOutput.bindMemory(to: Bytef.self).baseAddress
        stream.avail_out = UInt32(rawOutput.count)
        let status = deflate(&stream, Z_FINISH)
        archive.append(
          rawOutput.bindMemory(to: UInt8.self).baseAddress!,
          count: rawOutput.count - Int(stream.avail_out))
        return status
      }
      guard status == Z_OK || status == Z_STREAM_END else {
        throw ArchiveServiceError.operationFailed(.gzip)
      }
    } while status != Z_STREAM_END
    return archive
  }

  private func makeTarArchive(
    entries: [(path: String, type: TarFixtureEntryType, data: Data)]
  ) -> Data {
    var archive = Data()
    for entry in entries {
      var header = Data(repeating: 0, count: 512)
      writeTarField(entry.path, at: 0, length: 100, into: &header)
      writeTarField("0000644\0", at: 100, length: 8, into: &header)
      writeTarField("0000000\0", at: 108, length: 8, into: &header)
      writeTarField("0000000\0", at: 116, length: 8, into: &header)
      writeTarField(
        tarOctal(entry.data.count, digitCount: 11) + "\0",
        at: 124,
        length: 12,
        into: &header)
      writeTarField("00000000000\0", at: 136, length: 12, into: &header)
      header.replaceSubrange(148..<156, with: repeatElement(UInt8(ascii: " "), count: 8))
      header[156] = entry.type.typeFlag
      if entry.type == .symbolicLink {
        writeTarField("target", at: 157, length: 100, into: &header)
      }
      writeTarField("ustar\0", at: 257, length: 6, into: &header)
      writeTarField("00", at: 263, length: 2, into: &header)
      let checksum = header.reduce(0) { $0 + Int($1) }
      writeTarField(
        tarOctal(checksum, digitCount: 6) + "\0 ",
        at: 148,
        length: 8,
        into: &header)
      archive.append(header)
      archive.append(entry.data)
      let padding = (512 - entry.data.count % 512) % 512
      archive.append(Data(repeating: 0, count: padding))
    }
    archive.append(Data(repeating: 0, count: 1_024))
    return archive
  }

  private func writeTarField(
    _ value: String,
    at offset: Int,
    length: Int,
    into data: inout Data
  ) {
    let bytes = Array(value.utf8.prefix(length))
    data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
  }

  private func tarOctal(_ value: Int, digitCount: Int) -> String {
    let digits = String(value, radix: 8)
    return String(repeating: "0", count: max(digitCount - digits.count, 0)) + digits
  }

  private static let tarXzFixtureBase64 =
    "/Td6WFoAAAD/EtlBAgAhAQAAAAA3J5fW4Af/AEddADkZSme5Qwnw2wLpZ2GKRnj0Rvt6Gi0BNYZQo9Sbd82YYS5NDvdrAQxuNcpB+N851mNLyWPdZqbL3B9OC+h2sXUBuUrjs8YAAAAAAVuAEAAAAOTL40SoAAr8AgAAAAAAWVo="

  private static let singleFileXzFixtureBase64 =
    "/Td6WFoAAATm1rRGAgAhARYAAAB0L+WjAQANSGVsbG8sIFdvcmxkIQoAAADYaZJh4xDmawABJg4IG+AEH7bzfQEAAAAABFla"

  // Unrar.swift 0.5.4のMITライセンス対象テストフィクスチャ。
  private static let rar5FixtureBase64 = """
    UmFyIRoHAQAzkrXlCgEFBgAFAQGAgAD3EqflHwICqAAGqACkgwIWO/FfV7UGeoAAAQlSRUFETUUubWQjIFVucmFyCgpB
    IGRlc2NyaXB0aW9uIG9mIHRoaXMgcGFja2FnZS4KHXdWUQMFBAA=
    """

  // libarchiveのBSD-2-Clauseライセンス対象テストフィクスチャ。
  private static let rarLinkFixtureBase64 = """
    UmFyIRoHAM+QcwAADQAAAAAAAACEUnQgkDIAFAAAABQAAAADQqLIvrd22j4UMAgApIEAAHRlc3QudHh0gAi3dto+t3baPnRl
    c3QgdGV4dCBkb2N1bWVudA0KnS90IJAyAAgAAAAIAAAAA3tEybbRTNg+FDAIAP+hAAB0ZXN0bGlua8AI0UzYPlBf2j50ZXN0
    LnR4dM3gdCCQOgAUAAAAFAAAAANCosi+Y3faPhQwEACkgQAAdGVzdGRpclx0ZXN0LnR4dMDMY3faPmN32j50ZXN0IHRleHQg
    ZG9jdW1lbnQNCqHIdOCQMQAAAAAAAAAAAAMAAAAAY3faPhQwBwDtQQAAdGVzdGRpcsDMY3faPmR32j7m53TgkDYAAAAAAAAA
    AAADAAAAAJ2r1T4UMAwA7UEAAHRlc3RlbXB0eWRpcoDMnavVPsVd2j7EPXsAQAcA
    """

  private static let encryptedRARFixtureBase64 = """
    UmFyIRoHAM+QcwAADQAAAAAAAACyk3QklDMA0AAAAPEAAAADTWfP/T1aJVIdMwkApIEAAFJFQURNRS5tZCNSdPn+ChEgAMCnS5A3
    CVgExghBm5/fTRiNWowLiDv2h9l4AHpDMn/Ek/HBrhorL5w2iWOjBavjxTwPkagH0v8z+3DFupLdzHBGICogk/KBnoBhhLPJBSyt
    gv7XrcidGFTwF86K8wn2bdtICopHzQe+E/0hAPzmGj/M50E7adSUoFictwygS+d5fsBJW6AOsYCIJJemFC03UiK8ryD5cg0XqQHh
    3DAdxikQL/WqGPhSqS4w+ZGV0zWg9CZf0UeqGOsPDKCffSkckKj3GEtQeKAHaP/4HQJipxWsggh0JJQ1AJACAAAmBAAAA/x9JE89
    WiVSHTMLAKSBAABMSUNFTlNFLnR4dCNSdPn+ChEgAMCM5AZAu/D+um9yqe/qdZBg0Ua1JT0d1aFgtA1VNVtnhZ5PriXwPIfzLo+q
    S2wx/LVu7jxzEjvCIk5U+fOMefJhIsQJ5E2r3hfRQGPZ4Pwa8+ZKm659oIosxjFM9qEblTST95JQx4yOH5+ncegPgFmizr050pzy
    BMuWvq5JDsfptbNgy5bsufcb3MXALz/5Aj26+qIgIQUByTcPrrcGPH0wEfE0JNier/LWBndCCKMR2gE5cg1BwHImGifbkDhxziRK
    r3N+fGbl8ZNoIaF68iVl9DlkzT45GrGmMaV/5a1B3uBBzlNEwdh36GuOzeosEMzS934esDxd+6WsBgk/N98y3g3KLYbiD/8TiF0W
    FM0NMnRf9sBIowrKa+8hcxIIJRVd1nOOCHJxTsq/AUQVQqkdgLpDRMX0vw0UKvBHAw6xe6EODM9I3ccnJ7K/sLtYJJNpBp4ffxKe
    2tD1H8DtIo4Epdg/j1sVEGZA/Y6IjMxRbVbc+RFfRWr5FsnwpVDryqO2kiskTRjB7QFodAOUkGscJb4ZVtj1b/M9qPI4BVYBwSwl
    yOtzm77RIaA6oFoHkpThJjE4333aieafqbZISsQbCtQuAnlxi76gyy+IDHOfRriYDPwFiFrpgsaGhJxtA7jJBPEYZi5vv9Lc1eP8
    YfrHBz4LLVOOCc5QfYUIt7lqWz6E3W+5InrIkutxfcJ5dbGxkVHPEhVCRtphDh4u97+Cv1O+iOqF3JuL7iShGxJViHgHbd5H5/lm
    PvzbWkoGAtwqqQM/hKkxFBwgq34foecXSUn+/rMDRhul3Nd/jB7a4lQb8Zp/uZpZJC6cD+LI8EzfXJifrdEaVmgUfkfbLGEbSWjN
    TnUxY7RQXFXymz1pFsQ9ewBABwA=
    """

  private func pseudoRandomData(byteCount: Int) -> Data {
    var state: UInt64 = 0xC0FFEE
    var bytes = [UInt8](repeating: 0, count: byteCount)
    for index in bytes.indices {
      state = 6_364_136_223_846_793_005 &* state &+ 1
      bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
    }
    return Data(bytes)
  }

  private func assertIncludesIntermediateProgress(_ progressValues: [ArchiveProgress]) {
    let final = progressValues.last
    #expect(final?.completedBytes == final?.totalBytes)
    #expect(progressValues.contains { $0.completedBytes > 0 && $0.completedBytes < $0.totalBytes })
  }

  private func assertMonotonicCompletedProgress(_ progressValues: [ArchiveProgress]) {
    // 最終進捗まで届くことは固定するが、Debugテストではweak delegateがRelease最適化で
    // 早期解放される差を検出できない。実装側のwithExtendedLifetimeがその寿命を保証する。
    #expect(!progressValues.isEmpty)
    #expect(
      zip(progressValues, progressValues.dropFirst()).allSatisfy {
        $0.completedBytes <= $1.completedBytes
      })
    let final = progressValues.last
    #expect(final?.completedBytes == final?.totalBytes)
  }

  private func makeSevenZipArchive(
    entries: [(sourceURL: URL, archivePath: String)],
    at archiveURL: URL
  ) throws {
    try ArchiveTestFixtures.makeSevenZipArchive(entries: entries, at: archiveURL)
  }

  private func makeZIPArchiveWithoutUTF8Flag(named name: String) -> Data {
    makeZIPArchiveWithoutUTF8Flag(nameBytes: Data(name.utf8))
  }

  /// EFSビット(bit 11)を立てずに名前バイト列をそのまま格納した、
  /// 空データ1エントリのZIPを生成する(Finder製ZIPのヘッダ構成を再現)。
  private func makeZIPArchiveWithoutUTF8Flag(nameBytes: Data) -> Data {
    makeZIPArchiveWithoutUTF8Flag(entryNameBytes: [nameBytes])
  }

  /// EFSビット(bit 11)を立てずに名前バイト列をそのまま格納した、各エントリ空データの
  /// ZIPを生成する(Finder製ZIPのヘッダ構成を再現)。複数エントリの場合、全ローカル
  /// ヘッダーを先に並べたあとにセントラルディレクトリをまとめて並べる標準的なZIP構造
  /// とし、各セントラルディレクトリレコードのオフセットは対応するローカルヘッダーの
  /// 実際の位置を指す(実ZIPが同一アーカイブ内の全エントリを同じエンコーディングで
  /// 名付ける実態を再現し、非曖昧なエントリをアンカーにした判定を検証できるようにする)。
  private func makeZIPArchiveWithoutUTF8Flag(entryNameBytes: [Data]) -> Data {
    var localSection = Data()
    var localOffsets: [UInt32] = []
    for nameBytes in entryNameBytes {
      localOffsets.append(UInt32(localSection.count))
      append(UInt32(0x0403_4B50), to: &localSection)
      append(UInt16(20), to: &localSection)
      append(UInt16(0), to: &localSection)
      append(UInt16(0), to: &localSection)
      append(UInt16(0), to: &localSection)
      append(UInt16(0), to: &localSection)
      append(UInt32(0), to: &localSection)
      append(UInt32(0), to: &localSection)
      append(UInt32(0), to: &localSection)
      append(UInt16(nameBytes.count), to: &localSection)
      append(UInt16(0), to: &localSection)
      localSection.append(nameBytes)
    }

    var central = Data()
    for (index, nameBytes) in entryNameBytes.enumerated() {
      append(UInt32(0x0201_4B50), to: &central)
      append(UInt16(20), to: &central)
      append(UInt16(20), to: &central)
      append(UInt16(0), to: &central)
      append(UInt16(0), to: &central)
      append(UInt16(0), to: &central)
      append(UInt16(0), to: &central)
      append(UInt32(0), to: &central)
      append(UInt32(0), to: &central)
      append(UInt32(0), to: &central)
      append(UInt16(nameBytes.count), to: &central)
      append(UInt16(0), to: &central)
      append(UInt16(0), to: &central)
      append(UInt16(0), to: &central)
      append(UInt16(0), to: &central)
      append(UInt32(0), to: &central)
      append(localOffsets[index], to: &central)
      central.append(nameBytes)
    }

    let centralOffset = UInt32(localSection.count)
    var data = localSection
    data.append(central)
    append(UInt32(0x0605_4B50), to: &data)
    append(UInt16(0), to: &data)
    append(UInt16(0), to: &data)
    append(UInt16(entryNameBytes.count), to: &data)
    append(UInt16(entryNameBytes.count), to: &data)
    append(UInt32(central.count), to: &data)
    append(centralOffset, to: &data)
    append(UInt16(0), to: &data)
    return data
  }

  private func makeZIP64Archive(named name: String) -> Data {
    // 通常フィールドにも実値(0)を書いているため、ZIPFoundationがZIP64拡張フィールド側の
    // 値を採用する経路(effectiveCompressedSize等がextra側>0を選ぶ分岐)はこのヘルパーの
    // 検証対象外(常に0で通常フィールドへフォールバックする経路のみを通る)。
    let nameData = Data(name.utf8)
    let localExtra = zip64Extra(uncompressedSize: 0, compressedSize: 0)
    var local = Data()
    // 裸の16進リテラルはappend<T: FixedWidthInteger>の型推論でInt(8バイト)に
    // 解決されてしまい、意図した4バイトシグネチャの倍の長さで書き込まれ全体の
    // バイナリ構造が壊れるため、シグネチャは必ずUInt32を明示する。
    append(UInt32(0x0403_4B50), to: &local)
    append(UInt16(45), to: &local)
    append(UInt16(0x0800), to: &local)
    append(UInt16(0), to: &local)
    append(UInt16(0), to: &local)
    append(UInt16(0), to: &local)
    append(UInt32(0), to: &local)
    // ZIPFoundationのeffectiveCompressedSize/effectiveUncompressedSize/
    // effectiveRelativeOffsetOfLocalHeaderは、ZIP64拡張フィールドの値が0の場合
    // 「未設定」とみなして通常フィールドへフォールバックする(値>0のときのみ拡張側を
    // 採用する実装のため)。このテストは実サイズ0・オフセット0の単一エントリなので、
    // 通常フィールドを0xFFFFFFFFのままにするとフォールバック時に巨大な誤値になる。
    // 通常フィールドにも実際の値(0)を書いておけば、どちらが採用されても正しく動作する。
    append(UInt32(0), to: &local)
    append(UInt32(0), to: &local)
    append(UInt16(nameData.count), to: &local)
    append(UInt16(localExtra.count), to: &local)
    local.append(nameData)
    local.append(localExtra)

    let centralOffset = UInt64(local.count)
    let centralExtra = zip64Extra(uncompressedSize: 0, compressedSize: 0, offset: 0)
    var central = Data()
    append(UInt32(0x0201_4B50), to: &central)
    append(UInt16(45), to: &central)
    append(UInt16(45), to: &central)
    append(UInt16(0x0800), to: &central)
    append(UInt16(0), to: &central)
    append(UInt16(0), to: &central)
    append(UInt16(0), to: &central)
    append(UInt32(0), to: &central)
    append(UInt32(0), to: &central)
    append(UInt32(0), to: &central)
    append(UInt16(nameData.count), to: &central)
    append(UInt16(centralExtra.count), to: &central)
    append(UInt16(0), to: &central)
    append(UInt16(0), to: &central)
    append(UInt16(0), to: &central)
    append(UInt32(0), to: &central)
    append(UInt32(0), to: &central)
    central.append(nameData)
    central.append(centralExtra)

    var data = local
    data.append(central)
    let zip64EndOffset = UInt64(data.count)
    append(UInt32(0x0606_4B50), to: &data)
    append(UInt64(44), to: &data)
    append(UInt16(45), to: &data)
    append(UInt16(45), to: &data)
    append(UInt32(0), to: &data)
    append(UInt32(0), to: &data)
    append(UInt64(1), to: &data)
    append(UInt64(1), to: &data)
    append(UInt64(central.count), to: &data)
    append(centralOffset, to: &data)
    append(UInt32(0x0706_4B50), to: &data)
    append(UInt32(0), to: &data)
    append(zip64EndOffset, to: &data)
    append(UInt32(1), to: &data)
    append(UInt32(0x0605_4B50), to: &data)
    append(UInt16.max, to: &data)
    append(UInt16.max, to: &data)
    append(UInt16.max, to: &data)
    append(UInt16.max, to: &data)
    append(UInt32.max, to: &data)
    append(UInt32.max, to: &data)
    append(UInt16(0), to: &data)
    return data
  }

  private func zip64Extra(
    uncompressedSize: UInt64,
    compressedSize: UInt64,
    offset: UInt64? = nil
  ) -> Data {
    var data = Data()
    append(UInt16(0x0001), to: &data)
    append(UInt16(offset == nil ? 16 : 24), to: &data)
    append(uncompressedSize, to: &data)
    append(compressedSize, to: &data)
    if let offset {
      append(offset, to: &data)
    }
    return data
  }

  private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndianValue = value.littleEndian
    withUnsafeBytes(of: &littleEndianValue) { data.append(contentsOf: $0) }
  }
}

private final class RecordingArchiveCodec: ArchiveCodec, @unchecked Sendable {
  private let lock = NSLock()
  private var storedCreateCallCount = 0
  private var storedExtractCallCount = 0

  var createCallCount: Int {
    lock.withLock { storedCreateCallCount }
  }

  var extractCallCount: Int {
    lock.withLock { storedExtractCallCount }
  }

  func createArchive(
    from sourceURLs: [URL],
    to destinationURL: URL,
    cancellationProgress: Progress,
    progress: @escaping @Sendable (ArchiveProgress) -> Void
  ) throws {
    lock.withLock { storedCreateCallCount += 1 }
    try Data().write(to: destinationURL)
  }

  func extractArchive(
    at archiveURL: URL,
    to destinationURL: URL,
    limits: ArchiveSafetyLimits,
    cancellationProgress: Progress,
    progress: @escaping @Sendable (ArchiveProgress) -> Void
  ) throws {
    lock.withLock { storedExtractCallCount += 1 }
    try Data().write(to: destinationURL.appending(path: "decoded.txt"))
  }
}

private struct FailingExtractionArchiveCodec: ArchiveCodec {
  func createArchive(
    from sourceURLs: [URL],
    to destinationURL: URL,
    cancellationProgress: Progress,
    progress: @escaping @Sendable (ArchiveProgress) -> Void
  ) throws {
    try Data().write(to: destinationURL)
  }

  func extractArchive(
    at archiveURL: URL,
    to destinationURL: URL,
    limits: ArchiveSafetyLimits,
    cancellationProgress: Progress,
    progress: @escaping @Sendable (ArchiveProgress) -> Void
  ) throws {
    try Data("partial".utf8).write(to: destinationURL.appending(path: "partial.txt"))
    throw ArchiveServiceError.operationFailed(.sevenZip)
  }
}

private final class ProgressCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValues: [ArchiveProgress] = []

  var values: [ArchiveProgress] {
    lock.lock()
    defer { lock.unlock() }
    return storedValues
  }

  func append(_ progress: ArchiveProgress) {
    lock.lock()
    storedValues.append(progress)
    lock.unlock()
  }
}

private final class StreamingDecompressionProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var storedMaximumAllocatedBytes = 0
  private var storedMaximumProducedBytes: UInt64 = 0

  var maximumAllocatedBytes: Int {
    lock.withLock { storedMaximumAllocatedBytes }
  }

  var maximumProducedBytes: UInt64 {
    lock.withLock { storedMaximumProducedBytes }
  }

  func recordAllocatedBytes(_ value: Int) {
    lock.withLock {
      storedMaximumAllocatedBytes = max(storedMaximumAllocatedBytes, value)
    }
  }

  func recordProducedBytes(_ value: UInt64) {
    lock.withLock {
      storedMaximumProducedBytes = max(storedMaximumProducedBytes, value)
    }
  }
}
