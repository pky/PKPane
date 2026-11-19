import Foundation

enum FTPDirectoryListingSource: Equatable, Sendable {
  case mlsd
  case legacyList
}

struct FTPDirectoryEntry: Equatable, Sendable {
  let name: String
  let isDirectory: Bool
  let isSymbolicLink: Bool
  let size: Int64?
  let modifiedAt: Date?
  let posixPermissions: Int?
  let source: FTPDirectoryListingSource
}

enum FTPDirectoryListingParserError: LocalizedError, Equatable {
  case unsupportedTextEncoding
  case malformedMLSDEntry(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedTextEncoding:
      "FTPサーバーの一覧がUTF-8ではないため、安全にファイル名を解釈できません。"
    case .malformedMLSDEntry:
      "FTPサーバーのMLSD応答に不正な項目があります。"
    }
  }
}

enum FTPDirectoryListingParser {
  static func parseMLSD(_ data: Data) throws -> [FTPDirectoryEntry] {
    guard let text = String(data: data, encoding: .utf8) else {
      throw FTPDirectoryListingParserError.unsupportedTextEncoding
    }
    return try lines(in: text).compactMap(parseMLSDLine)
  }

  static func parseLegacyLIST(_ data: Data, now: Date = Date()) throws -> [FTPDirectoryEntry] {
    guard let text = String(data: data, encoding: .utf8) else {
      throw FTPDirectoryListingParserError.unsupportedTextEncoding
    }
    return lines(in: text).compactMap { parseUnixLISTLine($0, now: now) }
  }

  private static func parseMLSDLine(_ rawLine: String) throws -> FTPDirectoryEntry? {
    let line = rawLine.trimmingCharacters(in: .newlines)
    guard !line.isEmpty else { return nil }
    guard let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
      throw FTPDirectoryListingParserError.malformedMLSDEntry(line)
    }
    let factsText = line[..<separator]
    let name = line[separator...].drop(while: { $0 == " " || $0 == "\t" })

    var facts: [String: String] = [:]
    for fact in factsText.split(separator: ";") {
      guard let equal = fact.firstIndex(of: "=") else { continue }
      facts[String(fact[..<equal]).lowercased()] = String(fact[fact.index(after: equal)...])
    }
    guard let rawType = facts["type"]?.lowercased() else {
      throw FTPDirectoryListingParserError.malformedMLSDEntry(line)
    }
    if rawType == "cdir" || rawType == "pdir" { return nil }
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
      !name.utf8.contains(0)
    else {
      throw FTPDirectoryListingParserError.malformedMLSDEntry(line)
    }

    let isSymbolicLink = rawType.contains("slink")
    let isDirectory = rawType == "dir"
    let permissions = facts["unix.mode"].flatMap { Int($0, radix: 8) }.map {
      PosixPermissions.normalizedMode($0)
    }
    return FTPDirectoryEntry(
      name: String(name),
      isDirectory: isDirectory,
      isSymbolicLink: isSymbolicLink,
      size: facts["size"].flatMap(Int64.init),
      modifiedAt: facts["modify"].flatMap(parseMLSDDate),
      posixPermissions: permissions,
      source: .mlsd)
  }

  private static func parseUnixLISTLine(_ line: String, now: Date) -> FTPDirectoryEntry? {
    let fields = line.split(
      maxSplits: 8,
      omittingEmptySubsequences: true,
      whereSeparator: { $0 == " " || $0 == "\t" })
    guard fields.count == 9, fields[0].count >= 10 else { return nil }
    let mode = fields[0]
    let type = mode.first
    guard type == "-" || type == "d" || type == "l" else { return nil }
    guard let size = Int64(fields[4]) else { return nil }
    var name = String(fields[8])
    if type == "l", let arrow = name.range(of: " -> ") {
      name = String(name[..<arrow.lowerBound])
    }
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
      !name.utf8.contains(0)
    else { return nil }

    return FTPDirectoryEntry(
      name: name,
      isDirectory: type == "d",
      isSymbolicLink: type == "l",
      size: size,
      modifiedAt: parseLISTDate(
        month: String(fields[5]),
        day: String(fields[6]),
        yearOrTime: String(fields[7]),
        now: now),
      posixPermissions: parsePermissions(String(mode.prefix(10))),
      source: .legacyList)
  }

  private static func parseMLSDDate(_ value: String) -> Date? {
    let base = value.split(separator: ".", maxSplits: 1).first.map(String.init) ?? value
    guard base.count == 14 else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMddHHmmss"
    return formatter.date(from: base)
  }

  private static func parseLISTDate(
    month: String,
    day: String,
    yearOrTime: String,
    now: Date
  ) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone.current
    if yearOrTime.contains(":") {
      let year = Calendar.current.component(.year, from: now)
      formatter.dateFormat = "MMM d yyyy HH:mm"
      guard var date = formatter.date(from: "\(month) \(day) \(year) \(yearOrTime)") else {
        return nil
      }
      // LISTの時刻表記は通常直近6か月です。未来へ大きく飛ぶ場合は前年として扱います。
      if date.timeIntervalSince(now) > 24 * 60 * 60 {
        date = Calendar.current.date(byAdding: .year, value: -1, to: date) ?? date
      }
      return date
    }
    formatter.dateFormat = "MMM d yyyy"
    return formatter.date(from: "\(month) \(day) \(yearOrTime)")
  }

  private static func parsePermissions(_ mode: String) -> Int? {
    guard mode.count == 10 else { return nil }
    let permissionCharacters = Array(mode.dropFirst())
    var value = 0
    for group in 0..<3 {
      var digit = 0
      if permissionCharacters[group * 3] == "r" { digit += 4 }
      if permissionCharacters[group * 3 + 1] == "w" { digit += 2 }
      let execute = permissionCharacters[group * 3 + 2]
      if execute == "x" || execute == "s" || execute == "t" { digit += 1 }
      value = value * 8 + digit
    }
    return value
  }

  private static func lines(in text: String) -> [String] {
    text.components(separatedBy: .newlines).filter { !$0.isEmpty }
  }
}
