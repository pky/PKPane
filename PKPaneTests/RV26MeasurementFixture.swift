import Foundation

/// 実測をテスト専用一時領域へ保存し、標準出力がない実行でも前後値を確認できるようにする。
func writeRV26Measurement(name: String, values: [String: Any]) throws {
  let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
  guard !name.isEmpty, name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
    throw CocoaError(.fileWriteInvalidFileName)
  }
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("pkpane-rv26-measurements", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  var record = values
  record["operatingSystem"] = ProcessInfo.processInfo.operatingSystemVersionString
  record["measurementEnabled"] = ProcessInfo.processInfo.environment["PKPANE_RV26_MEASUREMENTS"]
  record["verificationEntry"] = "scripts/check_all.sh --only-testing"
  record["signingScope"] = "Debug単体検証用ad-hoc設定。配布署名の実機検証ではない"
  #if arch(arm64)
    record["architecture"] = "arm64"
  #else
    record["architecture"] = "other"
  #endif
  let data = try JSONSerialization.data(
    withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
  let output = directory.appendingPathComponent("\(name)-\(UUID().uuidString).json")
  try data.write(to: output, options: .atomic)
}
