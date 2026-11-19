import Foundation
import PLzmaSDK
import SWCompression

enum ArchiveTestFixtureError: Error {
  case failedToOpenSevenZipEncoder
  case failedToCompressSevenZipArchive
  case invalidBase64Data
}

enum ArchiveTestFixtures {
  static func makeEmptyTarGzipArchive(at archiveURL: URL) throws {
    try GzipArchive.archive(data: Data(repeating: 0, count: 1_024)).write(to: archiveURL)
  }

  static func makeSevenZipArchive(
    entries: [(sourceURL: URL, archivePath: String)],
    at archiveURL: URL,
    solid: Bool = false
  ) throws {
    let encoder = try Encoder(
      stream: try OutStream(path: Path(archiveURL.path)),
      fileType: .sevenZ,
      method: .LZMA2)
    if !solid {
      try encoder.setShouldCreateSolidArchive(false)
    }
    for entry in entries {
      try encoder.add(
        path: Path(entry.sourceURL.path),
        mode: .default,
        archivePath: Path(entry.archivePath))
    }
    guard try encoder.open() else {
      throw ArchiveTestFixtureError.failedToOpenSevenZipEncoder
    }
    guard try encoder.compress() else {
      throw ArchiveTestFixtureError.failedToCompressSevenZipArchive
    }
  }

  static func makeTarArchive(entries: [(path: String, data: Data)]) -> Data {
    TarContainer.create(
      from: entries.map { entry in
        TarEntry(
          info: TarEntryInfo(name: entry.path, type: .regular),
          data: entry.data)
      })
  }

  static func gzip(_ data: Data) throws -> Data {
    try GzipArchive.archive(data: data)
  }

  static func bzip2(_ data: Data) -> Data {
    BZip2.compress(data: data)
  }

  static var windowsBackslashRAR4Data: Data {
    get throws {
      guard
        let data = Data(
          base64Encoded: windowsBackslashRAR4FixtureBase64,
          options: .ignoreUnknownCharacters)
      else {
        throw ArchiveTestFixtureError.invalidBase64Data
      }
      return data
    }
  }

  static var rar5Data: Data {
    get throws {
      guard
        let data = Data(
          base64Encoded: rar5FixtureBase64,
          options: .ignoreUnknownCharacters)
      else {
        throw ArchiveTestFixtureError.invalidBase64Data
      }
      return data
    }
  }

  static var tarXzData: Data {
    get throws {
      guard let data = Data(base64Encoded: tarXzFixtureBase64) else {
        throw ArchiveTestFixtureError.invalidBase64Data
      }
      return data
    }
  }

  // Windows式のバックスラッシュを階層区切りとして格納したRAR4 fixture。
  static let windowsBackslashRAR4FixtureBase64 = """
    UmFyIRoHAM+QcwAADQAAAAAAAABFgnQgglgADwAAAA8AAAAD5xuEuJCaI1IdMDgApIEAAOOCouODvOOCq+OCpOODllzjgrXj
    g7Pjg5Xjgprjg6sudHh0ADBVovyrpEXWXLXzVNWa6y4AdHh044GT44KT44Gr44Gh44Gv8v50IIJwAA8AAAAPAAAAA+cbhLiQ
    miNSHTBQAKSBAADjgqLjg7zjgqvjgqTjg5Zc44OV44Kp44Or44K/44KZXOOCteODs+ODleOCmuODqy50eHQAMFWi/KukRdZc
    1alU67+ZXFW189WaQOsudHgAdOOBk+OCk+OBq+OBoeOBr5UndOCSUQAAAAAAAAAAAAMAAAAAlJojUhQwLwDtQQAA44Ki44O844
    Kr44Kk44OWXOODleOCqeODq+OCv+OCmQAwVaL8q6RF1lzVqVTrv5kAwNnrdOCSOgAAAAAAAAAAAAMAAAAAFZsjUhQwGADtQQAA
    44Ki44O844Kr44Kk44OWADBVovyrpEDWAMDEPXsAQAcA
    """

  // Unrar.swift 0.5.4のMITライセンス対象テストフィクスチャ。
  static let rar5FixtureBase64 = """
    UmFyIRoHAQAzkrXlCgEFBgAFAQGAgAD3EqflHwICqAAGqACkgwIWO/FfV7UGeoAAAQlSRUFETUUubWQjIFVucmFyCgpB
    IGRlc2NyaXB0aW9uIG9mIHRoaXMgcGFja2FnZS4KHXdWUQMFBAA=
    """

  static let tarXzFixtureBase64 =
    "/Td6WFoAAAD/EtlBAgAhAQAAAAA3J5fW4Af/AEddADkZSme5Qwnw2wLpZ2GKRnj0Rvt6Gi0BNYZQo9Sbd82YYS5NDvdrAQxuNcpB+N851mNLyWPdZqbL3B9OC+h2sXUBuUrjs8YAAAAAAVuAEAAAAOTL40SoAAr8AgAAAAAAWVo="
}
