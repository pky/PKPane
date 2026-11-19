import Foundation
import ZIPFoundation

struct ArchiveProgress: Equatable, Sendable {
  let completedBytes: Int64
  let totalBytes: Int64

  var percentage: Int {
    guard totalBytes > 0 else { return 100 }
    let fraction = Double(completedBytes) / Double(totalBytes)
    return min(max(Int((fraction * 100).rounded(.down)), 0), 100)
  }
}

enum ArchiveFormat: String, CaseIterable, Codable, Hashable, Sendable {
  case zip
  case sevenZip
  case tar
  case tarGzip
  case tarBzip2
  case tarXz
  case gzip
  case bzip2
  case xz
  case rar

  static let creationFormats: [ArchiveFormat] = [.zip, .sevenZip]

  var supportsCreation: Bool {
    Self.creationFormats.contains(self)
  }

  var fileExtension: String {
    switch self {
    case .zip: "zip"
    case .sevenZip: "7z"
    case .tar: "tar"
    case .tarGzip: "tar.gz"
    case .tarBzip2: "tar.bz2"
    case .tarXz: "tar.xz"
    case .gzip: "gz"
    case .bzip2: "bz2"
    case .xz: "xz"
    case .rar: "rar"
    }
  }

  var displayName: String {
    switch self {
    case .zip: "ZIP"
    case .sevenZip: "7z"
    case .tar: "TAR"
    case .tarGzip: "TAR.GZ"
    case .tarBzip2: "TAR.BZ2"
    case .tarXz: "TAR.XZ"
    case .gzip: "GZIP"
    case .bzip2: "BZIP2"
    case .xz: "XZ"
    case .rar: "RAR"
    }
  }

  var alternate: ArchiveFormat {
    switch self {
    case .zip: .sevenZip
    case .sevenZip: .zip
    case .tar, .tarGzip, .tarBzip2, .tarXz, .gzip, .bzip2, .xz, .rar: .zip
    }
  }

  var creationMenuTitle: String {
    String(localized: "選択項目を\(displayName)に圧縮")
  }

  init?(url: URL) {
    let lowercasedName = url.lastPathComponent.lowercased()
    if lowercasedName.hasSuffix(".tar.gz") {
      self = .tarGzip
      return
    }
    if lowercasedName.hasSuffix(".tar.bz2") {
      self = .tarBzip2
      return
    }
    if lowercasedName.hasSuffix(".tar.xz") {
      self = .tarXz
      return
    }

    switch url.pathExtension.lowercased() {
    case ArchiveFormat.zip.fileExtension:
      self = .zip
    case ArchiveFormat.sevenZip.fileExtension:
      self = .sevenZip
    case ArchiveFormat.tar.fileExtension:
      self = .tar
    case "tgz":
      self = .tarGzip
    case "tbz":
      self = .tarBzip2
    case "txz":
      self = .tarXz
    case ArchiveFormat.gzip.fileExtension:
      self = .gzip
    case ArchiveFormat.bzip2.fileExtension:
      self = .bzip2
    case ArchiveFormat.xz.fileExtension:
      self = .xz
    case ArchiveFormat.rar.fileExtension:
      self = .rar
    default:
      return nil
    }
  }

  func baseName(for url: URL) -> String {
    let name = url.lastPathComponent
    let lowercasedName = name.lowercased()
    let suffixes: [String]
    switch self {
    case .tarGzip: suffixes = [".tar.gz", ".tgz"]
    case .tarBzip2: suffixes = [".tar.bz2", ".tbz"]
    case .tarXz: suffixes = [".tar.xz", ".txz"]
    default: suffixes = [".\(fileExtension)"]
    }
    guard let suffix = suffixes.first(where: lowercasedName.hasSuffix) else {
      return url.deletingPathExtension().lastPathComponent
    }
    return String(name.dropLast(suffix.count))
  }
}

enum ArchiveExtractionDestination: Sendable {
  case currentDirectory
  case folderNamedAfterArchive
}

/// 選択項目の親ディレクトリ群からZIPの保存先を決める純粋計算。
/// ファイルシステムへ問い合わせず、標準化したパス文字列だけを比較する。
enum ArchiveDestinationDirectory {
  static func deepestCommonAncestor(of parentURLs: [URL]) -> URL? {
    guard !parentURLs.isEmpty, parentURLs.allSatisfy(\.isFileURL) else { return nil }
    let componentLists = parentURLs.map { $0.standardizedFileURL.pathComponents }
    guard let firstComponents = componentLists.first else { return nil }

    // /Volumes/Aと/Volumes/Bのような別ボリュームを、書き込み先として不適切な
    // /Volumesまで共通化しない。起動ボリュームと/Volumes配下の組み合わせも同様に拒否する。
    let volumeRoots = componentLists.map(volumeRootComponents)
    guard volumeRoots.dropFirst().allSatisfy({ $0 == volumeRoots.first }) else { return nil }

    var commonComponentCount = firstComponents.count
    for components in componentLists.dropFirst() {
      commonComponentCount = min(
        commonComponentCount,
        zip(firstComponents, components).prefix { $0 == $1 }.count)
    }
    guard commonComponentCount > 0 else { return nil }
    let commonPath = NSString.path(
      withComponents: Array(firstComponents.prefix(commonComponentCount)))
    return URL(fileURLWithPath: commonPath, isDirectory: true).standardizedFileURL
  }

  private static func volumeRootComponents(_ components: [String]) -> [String] {
    if components.count >= 3, components[0] == "/", components[1] == "Volumes" {
      return Array(components.prefix(3))
    }
    return components.first.map { [$0] } ?? []
  }
}

/// ZIP作成時の希望名が既に使われている場合に、拡張子を維持した連番名を決める純粋計算。
enum ArchiveAvailableName {
  static func resolving(
    preferredName: String,
    exists: (String) -> Bool
  ) -> String {
    guard exists(preferredName) else { return preferredName }
    let name = preferredName as NSString
    let pathExtension = name.pathExtension
    let baseName = name.deletingPathExtension
    var sequence = 2
    while true {
      let candidate =
        pathExtension.isEmpty
        ? "\(baseName)\(sequence)"
        : "\(baseName)\(sequence).\(pathExtension)"
      if !exists(candidate) { return candidate }
      sequence += 1
    }
  }
}

struct ArchiveSafetyLimits: Equatable, Sendable {
  let maximumEntryCount: Int
  let maximumUncompressedBytes: UInt64
  let maximumCompressionRatio: UInt64

  static let `default` = Self(
    maximumEntryCount: 10_000,
    maximumUncompressedBytes: 10 * 1_024 * 1_024 * 1_024,
    maximumCompressionRatio: 100)
}

struct ArchiveSafetyEntry: Sendable {
  let path: String
  let uncompressedSize: UInt64
  let compressedSize: UInt64
  let isSymbolicLink: Bool
}

enum ArchiveCompressionAccounting: Equatable {
  case perEntry
  case aggregate
}

/// ZIPの展開と仮想ブラウズで共有するEntry検証。
/// 列挙側と実データ展開側が別々の判定を持って乖離しないよう、パス・種別・
/// サイズ・圧縮率の判定をここへ集約する。
enum ArchiveEntrySafety {
  static func validate(entries: [Entry], limits: ArchiveSafetyLimits) throws {
    let resolver = ZipArchivePathResolver(entries: entries)
    try validate(
      entries: entries.map { ArchiveSafetyEntry($0, path: resolver.path(for: $0)) },
      limits: limits,
      format: .zip)
  }

  static func validate(
    entries: [ArchiveSafetyEntry],
    limits: ArchiveSafetyLimits,
    compressionAccounting: ArchiveCompressionAccounting = .perEntry,
    format: ArchiveFormat = .zip
  ) throws {
    guard entries.count <= limits.maximumEntryCount else {
      throw ArchiveServiceError.tooManyEntries(format)
    }
    var totalBytes: UInt64 = 0
    var totalCompressedBytes: UInt64 = 0
    for entry in entries {
      try validateMetadata(entry: entry, limits: limits, format: format)
      if compressionAccounting == .perEntry {
        try validateCompressionRatio(entry: entry, limits: limits, format: format)
      }
      let (newTotalBytes, overflow) = totalBytes.addingReportingOverflow(entry.uncompressedSize)
      guard !overflow, newTotalBytes <= limits.maximumUncompressedBytes else {
        throw ArchiveServiceError.tooLarge(format)
      }
      totalBytes = newTotalBytes
      let (newTotalCompressedBytes, compressedOverflow) =
        totalCompressedBytes.addingReportingOverflow(entry.compressedSize)
      guard !compressedOverflow else {
        throw ArchiveServiceError.tooLarge(format)
      }
      totalCompressedBytes = newTotalCompressedBytes
    }
    if compressionAccounting == .aggregate, totalBytes > 0 {
      try validateAggregateCompressionRatio(
        totalBytes: totalBytes,
        totalCompressedBytes: totalCompressedBytes,
        path: entries.first?.path ?? "",
        limits: limits,
        format: format)
    }
  }

  static func validateAggregateCompressionRatio(
    entries: [ArchiveSafetyEntry],
    limits: ArchiveSafetyLimits,
    format: ArchiveFormat
  ) throws {
    var totalBytes: UInt64 = 0
    var totalCompressedBytes: UInt64 = 0
    for entry in entries {
      let (newTotalBytes, overflow) = totalBytes.addingReportingOverflow(entry.uncompressedSize)
      guard !overflow, newTotalBytes <= limits.maximumUncompressedBytes else {
        throw ArchiveServiceError.tooLarge(format)
      }
      totalBytes = newTotalBytes
      let (newTotalCompressedBytes, compressedOverflow) =
        totalCompressedBytes.addingReportingOverflow(entry.compressedSize)
      guard !compressedOverflow else {
        throw ArchiveServiceError.tooLarge(format)
      }
      totalCompressedBytes = newTotalCompressedBytes
    }
    guard totalBytes > 0 else { return }
    try validateAggregateCompressionRatio(
      totalBytes: totalBytes,
      totalCompressedBytes: totalCompressedBytes,
      path: entries.first?.path ?? "",
      limits: limits,
      format: format)
  }

  static func validate(
    entry: ArchiveSafetyEntry,
    limits: ArchiveSafetyLimits,
    format: ArchiveFormat = .zip
  ) throws {
    try validateMetadata(entry: entry, limits: limits, format: format)
    try validateCompressionRatio(entry: entry, limits: limits, format: format)
  }

  static func validateMetadata(
    entry: ArchiveSafetyEntry,
    limits: ArchiveSafetyLimits,
    format: ArchiveFormat
  ) throws {
    _ = try validatedPathComponents(entry.path, format: format)
    guard !entry.isSymbolicLink else {
      throw ArchiveServiceError.symbolicLinkEntry(entry.path, format)
    }
    guard entry.uncompressedSize <= limits.maximumUncompressedBytes else {
      throw ArchiveServiceError.tooLarge(format)
    }
  }

  private static func validateCompressionRatio(
    entry: ArchiveSafetyEntry,
    limits: ArchiveSafetyLimits,
    format: ArchiveFormat
  ) throws {
    guard entry.uncompressedSize > 0 else { return }
    guard entry.compressedSize > 0 else {
      throw ArchiveServiceError.suspiciousCompressionRatio(entry.path, format)
    }
    let (maximumExpandedSize, overflow) = entry.compressedSize.multipliedReportingOverflow(
      by: limits.maximumCompressionRatio)
    guard overflow || entry.uncompressedSize <= maximumExpandedSize else {
      throw ArchiveServiceError.suspiciousCompressionRatio(entry.path, format)
    }
  }

  private static func validateAggregateCompressionRatio(
    totalBytes: UInt64,
    totalCompressedBytes: UInt64,
    path: String,
    limits: ArchiveSafetyLimits,
    format: ArchiveFormat
  ) throws {
    guard totalCompressedBytes > 0 else {
      throw ArchiveServiceError.suspiciousCompressionRatio(path, format)
    }
    let (maximumExpandedSize, overflow) = totalCompressedBytes.multipliedReportingOverflow(
      by: limits.maximumCompressionRatio)
    guard overflow || totalBytes <= maximumExpandedSize else {
      throw ArchiveServiceError.suspiciousCompressionRatio(path, format)
    }
  }

  static func outputURL(
    for path: String,
    in root: URL,
    format: ArchiveFormat = .zip
  ) throws -> URL {
    _ = try validatedPathComponents(path, format: format)
    let output = root.appending(path: path).standardizedFileURL
    let rootPath = root.standardizedFileURL.path + "/"
    guard output.path.hasPrefix(rootPath) else {
      throw ArchiveServiceError.unsafeEntryPath(path, format)
    }
    return output
  }

  static func validatedPathComponents(
    _ path: String,
    format: ArchiveFormat = .zip
  ) throws -> [String] {
    guard !path.hasPrefix("/"), !path.contains("\\") else {
      throw ArchiveServiceError.unsafeEntryPath(path, format)
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !components.isEmpty,
      components.allSatisfy({ $0 != "." && $0 != ".." }),
      !isWindowsDriveAbsolute(components[0])
    else {
      throw ArchiveServiceError.unsafeEntryPath(path, format)
    }
    return components
  }

  private static func isWindowsDriveAbsolute(_ firstComponent: String) -> Bool {
    guard firstComponent.count == 2 else { return false }
    let characters = Array(firstComponent.utf8)
    let letter = characters[0]
    return characters[1] == 58
      && ((65...90).contains(letter) || (97...122).contains(letter))
  }
}

extension ArchiveSafetyEntry {
  init(_ entry: Entry, path: String) {
    self.init(
      path: path,
      uncompressedSize: entry.uncompressedSize,
      compressedSize: entry.compressedSize,
      isSymbolicLink: entry.type == .symlink)
  }
}

/// macOSのFinder(アーカイブユーティリティ)はUTF-8名、日本語Windowsの
/// エクスプローラーはCP932名を格納しながら、どちらもEFSビット(general purpose
/// bit flagのbit 11)を立てないため、フラグ依存の`Entry.path`はCP437既定へ落ちて
/// 日本語などの名前が化ける。エントリ単体のバイト列だけではCP932/EUC-JPの
/// どちらでも往復検証を通る名前(例:「山田」)が存在し判別できないことがあるが、
/// 実ZIPは同一アーカイブ内の全エントリを同じエンコーディングで名付けるため、
/// アーカイブ全体を通してエンコーディングを1つに決めれば、非UTF-8名のうち
/// 一方のエンコーディングでしか往復検証を通らない非曖昧なエントリをアンカーに
/// 曖昧なエントリも正しく解決できる。
struct ZipArchivePathResolver {
  /// nilはUTF-8以外の名前をフラグ依存デコード(CP437既定)へ委ねることを意味する。
  private let fallbackEncoding: String.Encoding?

  init<Entries: Sequence>(entries: Entries) where Entries.Element == Entry {
    // ISO Latin-1は0x00〜0xFFの全バイト値を1文字ずつ可逆に表せるため、
    // フラグ依存デコードで失われがちな元のバイト列を復元する手段として使う。
    // path(using:)はデコード失敗時にZIPFoundation内部で空文字列を返す実装
    // (String(pathData:encoding:)が`?? ""`でフォールバックする)ため、
    // 空文字列を「UTF-8として不正だった」の判定に使っている。
    let nonUTF8OriginalBytes = entries.compactMap { entry -> Data? in
      guard entry.path(using: .utf8).isEmpty else { return nil }
      return entry.path(using: .isoLatin1).data(using: .isoLatin1)
    }
    guard !nonUTF8OriginalBytes.isEmpty else {
      fallbackEncoding = nil
      return
    }

    // 全ての非UTF-8名がこのエンコーディングで往復検証(デコード→再エンコード→
    // 元バイト列一致)を通る場合のみ、そのエンコーディングをアーカイブ全体の
    // 候補として採用する。1件でも失敗すればそのエンコーディングは不採用。
    func decodedNames(using encoding: String.Encoding) -> [String]? {
      var names: [String] = []
      names.reserveCapacity(nonUTF8OriginalBytes.count)
      for originalBytes in nonUTF8OriginalBytes {
        let decoded = String(data: originalBytes, encoding: encoding) ?? ""
        guard !decoded.isEmpty, decoded.data(using: encoding) == originalBytes else { return nil }
        names.append(decoded)
      }
      return names
    }

    let shiftJISNames = decodedNames(using: .shiftJIS)
    // 半角カナ文字(U+FF66-FF9F)のみで構成されたCP932名(レガシーDOS/Windows
    // 由来の定型)は、EUC-JPとしても対称的に往復検証を通過してしまうことが
    // ある(例:「ｶﾀｶﾅ」はEUC-JPでは「鏡凝」にデコードされ、これも元のバイト列
    // へ再エンコードできてしまう)。半角カナ最少スコアリングだけでは後者を
    // 誤って選んでしまうため、アーカイブ内の全非UTF-8名がCP932で半角カナ文字
    // のみに解釈できる場合はスコア比較せずCP932を優先する。半角句読点
    // (U+FF61-FF65: ｡｢｣､･)はこの短絡から除外する。EUC-JPの読点「、」や
    // 中黒「・」をCP932として誤読すると半角句読点混じりのASCII文字列に
    // デコードでき往復検証も通る対称ケースがあり、句読点を区別しないと
    // 本来EUC-JPであるべき名前まで誤ってCP932採用してしまうため。
    if let shiftJISNames, shiftJISNames.allSatisfy(Self.isHalfWidthKatakanaOnly) {
      fallbackEncoding = .shiftJIS
      return
    }

    // なお、CP932誤読が半角カナ文字のみになる任意のEUC-JP名(ギリシャ文字・
    // キリル文字・トレイルバイトが0xDF以下の漢字などを含む名前)は、
    // アーカイブ内の全エントリがそうした曖昧な名前だけの場合は原理的に
    // 判別不能なままこの短絡則でCP932側に解釈される。非曖昧なエントリが
    // 1つでもあれば(例:「田中」はCP932の往復検証を通らずshiftJISNamesが
    // nilになる)アンカーとして正しくEUC-JPへ解決される。CP932アーカイブが
    // EUC-JPアーカイブより圧倒的に多い基底確率に基づく設計判断として、
    // 全エントリ曖昧な場合のCP932優先は既知の制限で受容する。NEC選定IBM
    // 拡張文字とIBM拡張文字の重複領域(例: 0xFA5Cの「纊」)は再エンコード時に
    // 別コードポイントへ写像され往復検証を通らないため、従来どおりCP437
    // フォールバックへ落ちる。
    let japaneseEUCNames = decodedNames(using: .japaneseEUC)
    let candidates: [(encoding: String.Encoding, names: [String])] = [
      shiftJISNames.map { (.shiftJIS, $0) },
      japaneseEUCNames.map { (.japaneseEUC, $0) },
    ].compactMap { $0 }
    fallbackEncoding =
      candidates.min {
        Self.totalHalfWidthKatakanaCount($0.names) < Self.totalHalfWidthKatakanaCount($1.names)
      }?.encoding
  }

  func path(for entry: Entry) -> String {
    let utf8Path = entry.path(using: .utf8)
    if !utf8Path.isEmpty { return utf8Path }
    if let fallbackEncoding {
      let decoded = entry.path(using: fallbackEncoding)
      if !decoded.isEmpty { return decoded }
    }
    return entry.path
  }

  private static func totalHalfWidthKatakanaCount(_ names: [String]) -> Int {
    names.reduce(0) { $0 + halfWidthKatakanaCount($1) }
  }

  private static func halfWidthKatakanaCount(_ text: String) -> Int {
    text.unicodeScalars.filter { (0xFF61...0xFF9F).contains($0.value) }.count
  }

  private static func isHalfWidthKatakanaOnly(_ text: String) -> Bool {
    text.unicodeScalars.allSatisfy { $0.value <= 0x7F || (0xFF66...0xFF9F).contains($0.value) }
  }
}

enum ArchiveUnsupportedEntryType: String, Sendable {
  case hardLink
  case fifo
  case blockDevice
  case characterDevice
  case socket
  case contiguousFile
  case unknown

  var displayName: String {
    switch self {
    case .hardLink: "ハードリンク"
    case .fifo: "FIFO"
    case .blockDevice: "ブロックデバイス"
    case .characterDevice: "キャラクターデバイス"
    case .socket: "ソケット"
    case .contiguousFile: "連続ファイル"
    case .unknown: "不明な種別の項目"
    }
  }
}

enum ArchiveServiceError: LocalizedError {
  case noItems
  case destinationExists(String)
  case unsafeEntryPath(String, ArchiveFormat)
  case symbolicLinkEntry(String, ArchiveFormat)
  case unsupportedArchiveEntry(String, ArchiveUnsupportedEntryType, ArchiveFormat)
  case duplicateEntryPath(String, ArchiveFormat)
  case tooManyEntries(ArchiveFormat)
  case tooLarge(ArchiveFormat)
  case suspiciousCompressionRatio(String, ArchiveFormat)
  case encryptedArchive(ArchiveFormat)
  case multiVolumeArchive(ArchiveFormat)
  case unsupportedItem(String)
  case unsupportedFormat(String)
  case operationFailed(ArchiveFormat)

  var errorDescription: String? {
    switch self {
    case .noItems:
      "圧縮する項目を選択してください。"
    case .destinationExists(let name):
      "「\(name)」は既に存在します。"
    case .unsafeEntryPath(let path, let format):
      "\(format.displayName)内の危険なパス「\(path)」は展開できません。"
    case .symbolicLinkEntry(let path, let format):
      "シンボリックリンクを含む\(format.displayName)「\(path)」は展開できません。"
    case .unsupportedArchiveEntry(let path, let type, let format):
      "\(type.displayName)を含む\(format.displayName)「\(path)」は展開できません。"
    case .duplicateEntryPath(let path, let format):
      "\(format.displayName)内で「\(path)」が重複しています。"
    case .tooManyEntries(let format):
      "\(format.displayName)内の項目数が上限を超えています。"
    case .tooLarge(let format):
      "\(format.displayName)の展開後サイズが上限を超えています。"
    case .suspiciousCompressionRatio(let path, let format):
      "\(format.displayName)内の「\(path)」の圧縮率が安全上限を超えています。"
    case .encryptedArchive(let format):
      "パスワードで保護された\(format.displayName)は展開できません。"
    case .multiVolumeArchive(let format):
      "分割された\(format.displayName)は展開できません。"
    case .unsupportedItem(let name):
      "「\(name)」は圧縮できない項目です。"
    case .unsupportedFormat(let fileExtension):
      "「\(fileExtension)」は対応していないアーカイブ形式です。"
    case .operationFailed(let format):
      "\(format.displayName)の処理に失敗しました。"
    }
  }
}

protocol ArchiveCodec: Sendable {
  func createArchive(
    from sourceURLs: [URL],
    to destinationURL: URL,
    cancellationProgress: Progress,
    progress: @escaping @Sendable (ArchiveProgress) -> Void
  ) throws

  /// destinationURLは呼び出し元が所有する。部分出力が生じてもcodecから削除せず、
  /// 成否に応じた清掃は一時領域を用意した呼び出し元が行う。
  func extractArchive(
    at archiveURL: URL,
    to destinationURL: URL,
    limits: ArchiveSafetyLimits,
    cancellationProgress: Progress,
    progress: @escaping @Sendable (ArchiveProgress) -> Void
  ) throws
}

struct ZIPArchiveCodec: ArchiveCodec {
  func createArchive(
    from sourceURLs: [URL],
    to destinationURL: URL,
    cancellationProgress: Progress,
    progress: @escaping @Sendable (ArchiveProgress) -> Void
  ) throws {
    guard !sourceURLs.isEmpty else { throw ArchiveServiceError.noItems }
    let entries = try ArchiveSourceEntries.collect(from: sourceURLs)
    guard Set(entries.map(\.path)).count == entries.count else {
      throw ArchiveServiceError.duplicateEntryPath("同名の項目", .zip)
    }
    let totalBytes = entries.reduce(Int64.zero) { $0 + $1.size }
    let archive = try Archive(url: destinationURL, accessMode: .create)
    let reporter = ArchiveProgressReporter(totalBytes: totalBytes, handler: progress)
    for entry in entries {
      try Task.checkCancellation()
      try withEntryProgress(
        size: entry.size,
        cancellationProgress: cancellationProgress,
        reporter: reporter
      ) { entryProgress in
        try archive.addEntry(
          with: entry.path,
          fileURL: entry.url,
          compressionMethod: entry.isDirectory ? .none : .deflate,
          progress: entryProgress)
      }
    }
    reporter.finish()
  }

  func extractArchive(
    at archiveURL: URL,
    to destinationURL: URL,
    limits: ArchiveSafetyLimits,
    cancellationProgress: Progress,
    progress: @escaping @Sendable (ArchiveProgress) -> Void
  ) throws {
    let archive = try Archive(url: archiveURL, accessMode: .read)
    let entries = Array(archive)
    let resolver = ZipArchivePathResolver(entries: entries)
    try ArchiveEntrySafety.validate(
      entries: entries.map { ArchiveSafetyEntry($0, path: resolver.path(for: $0)) },
      limits: limits)
    let totalBytes = entries.reduce(Int64.zero) { partialResult, entry in
      partialResult + Int64(clamping: entry.uncompressedSize)
    }
    let reporter = ArchiveProgressReporter(totalBytes: totalBytes, handler: progress)
    for entry in entries {
      try Task.checkCancellation()
      let outputURL = try ArchiveEntrySafety.outputURL(
        for: resolver.path(for: entry), in: destinationURL)
      try withEntryProgress(
        size: Int64(clamping: entry.uncompressedSize),
        cancellationProgress: cancellationProgress,
        reporter: reporter
      ) { entryProgress in
        _ = try archive.extract(
          entry,
          to: outputURL,
          allowUncontainedSymlinks: false,
          progress: entryProgress)
      }
    }
    reporter.finish()
  }

  private func withEntryProgress(
    size: Int64,
    cancellationProgress: Progress,
    reporter: ArchiveProgressReporter,
    operation: (Progress) throws -> Void
  ) throws {
    let unitCount = max(size, 1)
    let entryProgress = Progress(totalUnitCount: unitCount)
    cancellationProgress.addChild(entryProgress, withPendingUnitCount: unitCount)
    reporter.beginEntry(size: size)
    let observation = entryProgress.observe(\.completedUnitCount) { progress, _ in
      reporter.report(entryCompletedBytes: progress.completedUnitCount)
    }
    defer { observation.invalidate() }
    try operation(entryProgress)
    reporter.completeEntry()
  }

}

enum ArchiveSourceEntries {
  static func collect(from sourceURLs: [URL]) throws -> [ArchiveSourceEntry] {
    try sourceURLs.flatMap(entriesForArchive)
  }

  private static func entriesForArchive(_ sourceURL: URL) throws -> [ArchiveSourceEntry] {
    let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isSymbolicLink != true else {
      throw ArchiveServiceError.unsupportedItem(sourceURL.lastPathComponent)
    }
    guard values.isDirectory == true else {
      return [try .init(url: sourceURL, path: sourceURL.lastPathComponent)]
    }
    var entries = [try ArchiveSourceEntry(url: sourceURL, path: sourceURL.lastPathComponent)]
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
    let enumerator = FileManager.default.enumerator(
      at: sourceURL,
      includingPropertiesForKeys: Array(keys),
      options: [])
    guard let enumerator
    else {
      throw ArchiveServiceError.unsupportedItem(sourceURL.lastPathComponent)
    }
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: keys)
      guard values.isSymbolicLink != true else {
        throw ArchiveServiceError.unsupportedItem(url.lastPathComponent)
      }
      // FileManager.enumerator(at:)が返すURLは/var→/private/varのようなfirmlinkを
      // 解決した実パスになる一方、sourceURLは未解決パスのままのことがあり、
      // 文字数ベースで突き合わせると相対パスが壊れる。enumeratorのlevel(sourceURL
      // 直下からの深さ)分だけpathComponentsの末尾を取れば解決差異の影響を受けない。
      let relativeComponents = url.pathComponents.suffix(enumerator.level)
      let relativePath = ([sourceURL.lastPathComponent] + relativeComponents).joined(separator: "/")
      entries.append(try ArchiveSourceEntry(url: url, path: relativePath))
    }
    return entries
  }
}

final class ArchiveProgressReporter: @unchecked Sendable {
  private let lock = NSLock()
  private let totalBytes: Int64
  private let handler: @Sendable (ArchiveProgress) -> Void
  private var completedBeforeEntry: Int64 = 0
  private var currentEntrySize: Int64 = 0
  private var lastReportedBytes: Int64 = -1
  private var lastReportedPercentage = -1

  init(totalBytes: Int64, handler: @escaping @Sendable (ArchiveProgress) -> Void) {
    self.totalBytes = totalBytes
    self.handler = handler
  }

  func beginEntry(size: Int64) {
    lock.lock()
    currentEntrySize = max(size, 0)
    let update = makeUpdateLocked(completedBytes: completedBeforeEntry)
    lock.unlock()
    send(update)
  }

  func report(entryCompletedBytes: Int64) {
    lock.lock()
    let current = min(max(entryCompletedBytes, 0), currentEntrySize)
    let update = makeUpdateLocked(completedBytes: completedBeforeEntry + current)
    lock.unlock()
    send(update)
  }

  func completeEntry() {
    lock.lock()
    completedBeforeEntry += currentEntrySize
    let update = makeUpdateLocked(completedBytes: completedBeforeEntry)
    lock.unlock()
    send(update)
  }

  func finish() {
    lock.lock()
    let update = makeUpdateLocked(completedBytes: totalBytes)
    lock.unlock()
    send(update)
  }

  private func makeUpdateLocked(completedBytes: Int64) -> ArchiveProgress? {
    let clamped = min(max(completedBytes, 0), totalBytes)
    let update = ArchiveProgress(completedBytes: clamped, totalBytes: totalBytes)
    guard
      update.percentage > lastReportedPercentage
        || (clamped == totalBytes && clamped > lastReportedBytes)
    else {
      return nil
    }
    lastReportedBytes = clamped
    lastReportedPercentage = update.percentage
    return update
  }

  private func send(_ update: ArchiveProgress?) {
    guard let update else { return }
    handler(update)
  }
}

actor ArchiveService {
  typealias ProgressHandler = @Sendable (ArchiveProgress) -> Void

  private let codecs: [ArchiveFormat: any ArchiveCodec]
  private let limits: ArchiveSafetyLimits

  init(limits: ArchiveSafetyLimits = .default) {
    codecs = [
      .zip: ZIPArchiveCodec(),
      .sevenZip: SevenZipArchiveCodec(),
      .tar: TarArchiveCodec(format: .tar),
      .tarGzip: TarArchiveCodec(format: .tarGzip),
      .tarBzip2: TarArchiveCodec(format: .tarBzip2),
      .tarXz: TarArchiveCodec(format: .tarXz),
      .gzip: SingleFileCompressionCodec(format: .gzip),
      .bzip2: SingleFileCompressionCodec(format: .bzip2),
      .xz: SingleFileCompressionCodec(format: .xz),
      .rar: RARArchiveCodec(),
    ]
    self.limits = limits
  }

  init(codec: any ArchiveCodec, limits: ArchiveSafetyLimits = .default) {
    codecs = [.zip: codec]
    self.limits = limits
  }

  init(
    codecs: [ArchiveFormat: any ArchiveCodec],
    limits: ArchiveSafetyLimits = .default
  ) {
    self.codecs = codecs
    self.limits = limits
  }

  func createArchive(
    from sourceURLs: [URL],
    in directoryURL: URL,
    name: String,
    format: ArchiveFormat = .zip,
    progress: @escaping ProgressHandler = { _ in }
  ) async throws -> URL {
    guard format.supportsCreation else {
      throw ArchiveServiceError.unsupportedFormat(format.fileExtension)
    }
    let codec = try codec(for: format)
    let fileManager = FileManager.default
    let availableName = ArchiveAvailableName.resolving(preferredName: name) { candidate in
      fileManager.fileExists(atPath: directoryURL.appending(path: candidate).path)
    }
    let destinationURL = directoryURL.appending(path: availableName).standardizedFileURL
    let temporaryURL = directoryURL.appending(
      path: ".\(availableName).pkpane-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    let cancellationProgress = Progress()
    try await withTaskCancellationHandler {
      try codec.createArchive(
        from: sourceURLs,
        to: temporaryURL,
        cancellationProgress: cancellationProgress,
        progress: progress)
    } onCancel: {
      cancellationProgress.cancel()
    }
    try Task.checkCancellation()
    try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    return destinationURL
  }

  func extractArchive(
    at archiveURL: URL,
    in directoryURL: URL,
    destination: ArchiveExtractionDestination,
    organizingForDefaultOpen: Bool = false,
    restoresZIPMetadata: Bool = true,
    maximumUncompressedBytes: UInt64? = nil,
    progress: @escaping ProgressHandler = { _ in }
  ) async throws -> URL {
    guard let format = ArchiveFormat(url: archiveURL) else {
      throw ArchiveServiceError.unsupportedFormat(archiveURL.pathExtension.lowercased())
    }
    let codec = try codec(for: format)
    let extractionLimits = ArchiveSafetyLimits(
      maximumEntryCount: limits.maximumEntryCount,
      maximumUncompressedBytes: min(
        limits.maximumUncompressedBytes,
        maximumUncompressedBytes ?? limits.maximumUncompressedBytes),
      maximumCompressionRatio: limits.maximumCompressionRatio)
    let fileManager = FileManager.default
    let temporaryURL = directoryURL.appending(
      path: ".pkpane-extract-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
    // 展開先の所有と失敗時の清掃はcodecではなく呼び出し元で一元管理する。
    defer { try? fileManager.removeItem(at: temporaryURL) }
    let cancellationProgress = Progress()
    try await withTaskCancellationHandler {
      try codec.extractArchive(
        at: archiveURL,
        to: temporaryURL,
        limits: extractionLimits,
        cancellationProgress: cancellationProgress,
        progress: progress)
    } onCancel: {
      cancellationProgress.cancel()
    }
    try Task.checkCancellation()
    if format == .zip, restoresZIPMetadata {
      try ZipAppleDoubleMetadata.restore(
        in: temporaryURL, cancellationProgress: cancellationProgress)
    }

    if organizingForDefaultOpen {
      return try placeExtractionForDefaultOpen(
        from: temporaryURL, archiveURL: archiveURL, in: directoryURL, format: format)
    }

    switch destination {
    case .folderNamedAfterArchive:
      let name = format.baseName(for: archiveURL)
      let outputURL = directoryURL.appending(path: name, directoryHint: .isDirectory)
      guard !fileManager.fileExists(atPath: outputURL.path) else {
        throw ArchiveServiceError.destinationExists(name)
      }
      // 単一ディレクトリの圧縮はエントリにそのディレクトリ自身も含むため、
      // 展開結果は一時ディレクトリ直下に単一ディレクトリとして現れる。
      // そのままmoveすると「アーカイブ名/アーカイブ名/…」の二重ネストになるため、内側を採用する。
      // ただし内側のディレクトリ名がアーカイブ名と異なる場合(他ツール製ZIPで
      // photos-2024.zipの中身が"Photos 2024 Backup/"など)はunwrapするとその
      // フォルダ名が消えてしまうため、名前が一致するときだけ内側を採用する。
      let sourceURL: URL
      if let nestedDirectory = try singleNestedDirectory(in: temporaryURL),
        nestedDirectory.lastPathComponent == name
      {
        sourceURL = nestedDirectory
      } else {
        sourceURL = temporaryURL
      }
      try fileManager.moveItem(at: sourceURL, to: outputURL)
      return outputURL
    case .currentDirectory:
      let extractedItems = try FileSystemDirectoryEntries.children(of: temporaryURL)
      let moves = extractedItems.map { item in
        let destinationName =
          format.isSingleFileCompression
          ? ArchiveAvailableName.resolving(preferredName: item.lastPathComponent) { candidate in
            fileManager.fileExists(atPath: directoryURL.appending(path: candidate).path)
          }
          : item.lastPathComponent
        return (source: item, destination: directoryURL.appending(path: destinationName))
      }
      if !format.isSingleFileCompression {
        for move in moves {
          guard !fileManager.fileExists(atPath: move.destination.path) else {
            throw ArchiveServiceError.destinationExists(move.source.lastPathComponent)
          }
        }
      }
      for move in moves {
        try Task.checkCancellation()
        try fileManager.moveItem(at: move.source, to: move.destination)
      }
      return directoryURL
    }
  }

  /// 通常の「開く」では単一項目をそのまま、複数項目はZIP名のフォルダにまとめる。
  /// 既存項目は連番で避け、確認後に競合が生じてもmoveItemの上書き拒否で保護する。
  private func placeExtractionForDefaultOpen(
    from temporaryURL: URL,
    archiveURL: URL,
    in directoryURL: URL,
    format: ArchiveFormat
  ) throws -> URL {
    let fileManager = FileManager.default
    let items = try FileSystemDirectoryEntries.children(of: temporaryURL)
    let sourceURL: URL
    let preferredName: String
    let isDirectory: Bool
    if items.count == 1, let item = items.first {
      sourceURL = item
      preferredName = item.lastPathComponent
      isDirectory = try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    } else {
      sourceURL = temporaryURL
      preferredName = format.baseName(for: archiveURL)
      isDirectory = true
    }
    let name = preferredName as NSString
    let pathExtension = isDirectory ? "" : name.pathExtension
    let baseName = pathExtension.isEmpty ? preferredName : name.deletingPathExtension
    var candidate = preferredName
    var sequence = 2
    while fileManager.fileExists(atPath: directoryURL.appending(path: candidate).path) {
      candidate =
        pathExtension.isEmpty
        ? "\(baseName) \(sequence)" : "\(baseName) \(sequence).\(pathExtension)"
      sequence += 1
    }
    try Task.checkCancellation()
    let outputURL = directoryURL.appending(path: candidate)
    try fileManager.moveItem(at: sourceURL, to: outputURL)
    return outputURL
  }

  /// directoryURL直下の内容が単一ディレクトリのみであれば、そのディレクトリのURLを返す。
  private func singleNestedDirectory(in directoryURL: URL) throws -> URL? {
    let contents = try FileSystemDirectoryEntries.children(of: directoryURL)
    guard contents.count == 1, let onlyItem = contents.first else { return nil }
    let values = try onlyItem.resourceValues(forKeys: [.isDirectoryKey])
    return values.isDirectory == true ? onlyItem : nil
  }

  private func codec(for format: ArchiveFormat) throws -> any ArchiveCodec {
    guard let codec = codecs[format] else {
      throw ArchiveServiceError.unsupportedFormat(format.fileExtension)
    }
    return codec
  }
}

extension ArchiveFormat {
  var isBrowsable: Bool {
    switch self {
    case .zip, .sevenZip, .tar, .tarGzip, .tarBzip2, .tarXz, .gzip, .bzip2, .xz, .rar:
      true
    }
  }

  var isSingleFileCompression: Bool {
    switch self {
    case .gzip, .bzip2, .xz: true
    case .zip, .sevenZip, .tar, .tarGzip, .tarBzip2, .tarXz, .rar: false
    }
  }
}

struct ArchiveSourceEntry {
  let url: URL
  let path: String
  let isDirectory: Bool
  let size: Int64

  init(url: URL, path: String) throws {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
    self.url = url
    self.path = path
    isDirectory = values.isDirectory == true
    size = isDirectory ? 0 : Int64(values.fileSize ?? 0)
  }
}
