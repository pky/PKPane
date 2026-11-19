import Foundation

struct FTPReply: Equatable, Sendable {
  let code: Int
  let lines: [String]

  var message: String {
    lines.joined(separator: "\n")
  }

  var category: Int { code / 100 }
  var isPositivePreliminary: Bool { category == 1 }
  var isPositiveCompletion: Bool { category == 2 }
  var isPositiveIntermediate: Bool { category == 3 }
}

enum FTPReplyParserError: LocalizedError, Equatable {
  case invalidReply
  case mismatchedMultilineReply
  case replyTooLarge

  var errorDescription: String? {
    switch self {
    case .invalidReply:
      "FTPサーバーから不正な応答を受信しました。"
    case .mismatchedMultilineReply:
      "FTPサーバーから不正な複数行応答を受信しました。"
    case .replyTooLarge:
      "FTPサーバーの応答が許容サイズを超えました。"
    }
  }
}

struct FTPReplyParser: Sendable {
  private static let maximumLineCount = 1_024
  private var multilineCode: Int?
  private var collectedLines: [String] = []

  mutating func append(line rawLine: String) throws -> FTPReply? {
    let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
    guard !line.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }) else {
      throw FTPReplyParserError.invalidReply
    }
    guard collectedLines.count < Self.maximumLineCount else {
      throw FTPReplyParserError.replyTooLarge
    }

    if let multilineCode {
      if line.hasPrefix(String(format: "%03d-", multilineCode)), collectedLines.isEmpty {
        throw FTPReplyParserError.mismatchedMultilineReply
      }
      if line.hasPrefix(String(format: "%03d ", multilineCode)) {
        collectedLines.append(String(line.dropFirst(4)))
        let reply = FTPReply(code: multilineCode, lines: collectedLines)
        self.multilineCode = nil
        collectedLines.removeAll(keepingCapacity: true)
        return reply
      }
      collectedLines.append(line)
      return nil
    }

    guard line.count >= 3,
      let code = Int(line.prefix(3)),
      (100...599).contains(code)
    else {
      throw FTPReplyParserError.invalidReply
    }
    if line.count == 3 {
      return FTPReply(code: code, lines: [""])
    }
    let separatorIndex = line.index(line.startIndex, offsetBy: 3)
    switch line[separatorIndex] {
    case " ":
      return FTPReply(code: code, lines: [String(line.dropFirst(4))])
    case "-":
      multilineCode = code
      collectedLines = [String(line.dropFirst(4))]
      return nil
    default:
      throw FTPReplyParserError.invalidReply
    }
  }
}
