import Foundation
import Testing

@testable import PKPane

struct FTPDirectoryListingParserTests {
  @Test("MLSDの型、サイズ、UTC更新日時、POSIX権限を解析する")
  func parsesMLSD() throws {
    let data = Data(
      """
      type=cdir;modify=20260916090000; .
      type=pdir;modify=20260916090000; ..
      type=dir;modify=20260916090102;unix.mode=0755; フォルダ
      type=file;size=123;modify=20260916090203.456;unix.mode=0644; report final.txt
      type=OS.unix=slink;size=8;unix.mode=0777; shortcut
      """.utf8)

    let entries = try FTPDirectoryListingParser.parseMLSD(data)

    #expect(entries.count == 3)
    #expect(entries[0].name == "フォルダ")
    #expect(entries[0].isDirectory)
    #expect(entries[0].posixPermissions == 0o755)
    #expect(entries[1].name == "report final.txt")
    #expect(entries[1].size == 123)
    #expect(entries[1].modifiedAt != nil)
    #expect(entries[2].isSymbolicLink)
    #expect(entries.allSatisfy { $0.source == .mlsd })
  }

  @Test("Unix LISTを制限付きフォールバックとして解析する")
  func parsesUnixLIST() throws {
    let data = Data(
      """
      drwxr-xr-x 2 owner group 4096 Sep 15 2025 Folder Name
      -rw-r--r-- 1 owner group 42 Sep 16 12:34 file name.txt
      lrwxrwxrwx 1 owner group 8 Sep 16 12:34 shortcut -> target
      """.utf8)

    let entries = try FTPDirectoryListingParser.parseLegacyLIST(data)

    #expect(entries.count == 3)
    #expect(entries[0].name == "Folder Name")
    #expect(entries[0].isDirectory)
    #expect(entries[0].posixPermissions == 0o755)
    #expect(entries[1].name == "file name.txt")
    #expect(entries[1].size == 42)
    #expect(entries[2].name == "shortcut")
    #expect(entries[2].isSymbolicLink)
    #expect(entries.allSatisfy { $0.source == .legacyList })
  }

  @Test("UTF-8でない一覧を曖昧な名前として受理しない")
  func rejectsUnsupportedEncoding() {
    let invalidUTF8 = Data([0xFF, 0xFE, 0x0A])

    #expect(throws: FTPDirectoryListingParserError.unsupportedTextEncoding) {
      try FTPDirectoryListingParser.parseMLSD(invalidUTF8)
    }
    #expect(throws: FTPDirectoryListingParserError.unsupportedTextEncoding) {
      try FTPDirectoryListingParser.parseLegacyLIST(invalidUTF8)
    }
  }

  @Test("MLSDの不正な名前を拒否する")
  func rejectsUnsafeMLSDName() {
    let data = Data("type=file;size=1; ../escape\r\n".utf8)

    #expect(
      throws: FTPDirectoryListingParserError.malformedMLSDEntry("type=file;size=1; ../escape")
    ) {
      try FTPDirectoryListingParser.parseMLSD(data)
    }
  }
}
