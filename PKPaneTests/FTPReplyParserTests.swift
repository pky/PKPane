import Testing

@testable import PKPane

struct FTPReplyParserTests {
  @Test("単一行応答を解析する")
  func parsesSingleLine() throws {
    var parser = FTPReplyParser()

    let reply = try parser.append(line: "220 Service ready\r")

    #expect(reply == FTPReply(code: 220, lines: ["Service ready"]))
  }

  @Test("RFC形式の複数行応答を終端コードまでまとめる")
  func parsesMultilineReply() throws {
    var parser = FTPReplyParser()

    #expect(try parser.append(line: "211-Features") == nil)
    #expect(try parser.append(line: " UTF8") == nil)
    #expect(try parser.append(line: " MLST type*;size*;") == nil)
    let reply = try parser.append(line: "211 End")

    #expect(reply?.code == 211)
    #expect(reply?.lines == ["Features", " UTF8", " MLST type*;size*;", "End"])
  }

  @Test("コードのない応答と改行注入を拒否する")
  func rejectsMalformedReply() {
    var parser = FTPReplyParser()
    #expect(throws: FTPReplyParserError.invalidReply) {
      try parser.append(line: "hello")
    }
    #expect(throws: FTPReplyParserError.invalidReply) {
      try parser.append(line: "220 ok\r\n331 password")
    }
  }
}
