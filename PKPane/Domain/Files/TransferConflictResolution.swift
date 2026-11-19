import Foundation

enum TransferConflictResolution: Sendable {
  case replace
  case skip
  case keepBoth
  case cancel
}

typealias TransferDestinationReservationReporter =
  @Sendable (FileLocation, TransferItemOptions) async throws -> Void

/// 取消や一時停止でも、未完成の予約先を確認する案内を失わない。
protocol TransferRecoveryDescribing: Error {
  var recoveryDescription: String { get }
}

struct TransferRecoveryError: LocalizedError, TransferRecoveryDescribing, Sendable,
  ReconnectFutileError
{
  let underlyingDescription: String
  let recoveryDescription: String

  var errorDescription: String? {
    [underlyingDescription, recoveryDescription].joined(separator: "\n")
  }
}

/// 転送元の名前・場所を変えず、項目ごとの宛先と置換許可を保存する。
struct TransferItemOptions: Codable, Hashable, Sendable {
  var destinationName: String?
  var replacingExisting = false
  /// FTPでサーバーが予約した実名。再試行では現存する予約名を勝手に増やさない。
  var destinationNameWasReserved = false
  /// 明示した名前やUndoの元名は、予約実名が変わっても要求として保持する。
  var requiredDestinationName: String?

  init(
    destinationName: String? = nil, replacingExisting: Bool = false,
    destinationNameWasReserved: Bool = false, requiredDestinationName: String? = nil
  ) {
    self.destinationName = destinationName
    self.replacingExisting = replacingExisting
    self.destinationNameWasReserved = destinationNameWasReserved
    self.requiredDestinationName = requiredDestinationName
  }

  private enum CodingKeys: String, CodingKey {
    case destinationName, replacingExisting, destinationNameWasReserved, requiredDestinationName
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    destinationName = try values.decodeIfPresent(String.self, forKey: .destinationName)
    replacingExisting = try values.decodeIfPresent(Bool.self, forKey: .replacingExisting) ?? false
    destinationNameWasReserved =
      try values.decodeIfPresent(Bool.self, forKey: .destinationNameWasReserved) ?? false
    if values.contains(.requiredDestinationName) {
      requiredDestinationName = try values.decodeIfPresent(
        String.self, forKey: .requiredDestinationName)
    } else {
      // 新機能以前の明示名は、サーバー任せに解釈し直さない。
      requiredDestinationName = destinationNameWasReserved ? nil : destinationName
    }
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encodeIfPresent(destinationName, forKey: .destinationName)
    try values.encode(replacingExisting, forKey: .replacingExisting)
    try values.encode(destinationNameWasReserved, forKey: .destinationNameWasReserved)
    // nilも保存し、旧データの欠落キーと新しいKeepBothのserver任せを区別する。
    try values.encode(requiredDestinationName, forKey: .requiredDestinationName)
  }

  static func availableName(for name: String, isDirectory: Bool, occupiedNames: Set<String>)
    -> String
  {
    let value = name as NSString
    let extensionName = isDirectory ? "" : value.pathExtension
    let stem = extensionName.isEmpty ? name : value.deletingPathExtension
    var number = 1
    while true {
      let suffix = number == 1 ? "のコピー" : "のコピー\(number)"
      let candidate = stem + suffix + (extensionName.isEmpty ? "" : "." + extensionName)
      if !occupiedNames.contains(candidate) { return candidate }
      number += 1
    }
  }
}
