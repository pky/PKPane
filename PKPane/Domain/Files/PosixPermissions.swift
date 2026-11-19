import Foundation

enum PosixPermissions {
  struct Option: Identifiable, Equatable, Sendable {
    let label: String
    let bit: Int

    var id: Int { bit }
  }

  struct Row: Identifiable, Equatable, Sendable {
    let label: String
    let options: [Option]

    var id: String { label }
  }

  static let permissionMask = 0o777

  static let rows = [
    Row(
      label: "所有者",
      options: [
        Option(label: "読み込み", bit: 0o400),
        Option(label: "書き込み", bit: 0o200),
        Option(label: "実行", bit: 0o100),
      ]),
    Row(
      label: "グループ",
      options: [
        Option(label: "読み込み", bit: 0o040),
        Option(label: "書き込み", bit: 0o020),
        Option(label: "実行", bit: 0o010),
      ]),
    Row(
      label: "その他",
      options: [
        Option(label: "読み込み", bit: 0o004),
        Option(label: "書き込み", bit: 0o002),
        Option(label: "実行", bit: 0o001),
      ]),
  ]

  static func normalizedMode(_ mode: Int) -> Int {
    mode & permissionMask
  }

  static func octalString(for mode: Int) -> String {
    String(format: "%03o", normalizedMode(mode))
  }

  static func mode(fromOctalString value: String) -> Int? {
    guard value.count == 3,
      value.allSatisfy({ ("0"..."7").contains($0) })
    else { return nil }
    return Int(value, radix: 8)
  }

  static func isValidPartialOctalInput(_ value: String) -> Bool {
    value.count <= 3 && value.allSatisfy { ("0"..."7").contains($0) }
  }

  static func symbolicString(for mode: Int) -> String {
    let normalized = normalizedMode(mode)
    let symbols = ["r", "w", "x", "r", "w", "x", "r", "w", "x"]
    let bits = rows.flatMap(\.options).map(\.bit)
    return zip(symbols, bits).map { symbol, bit in
      normalized & bit == bit ? symbol : "-"
    }.joined()
  }

  static func setting(_ bit: Int, enabled: Bool, in mode: Int) -> Int {
    let normalized = normalizedMode(mode)
    return enabled ? normalized | bit : normalized & ~bit
  }
}
