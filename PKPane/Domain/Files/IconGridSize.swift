import Foundation

/// アイコン表示(.icon)のアイコンサイズ4段階。rawValueはFileIconProviderへ要求する
/// 解決サイズ(pt)であり、グリッドに描画するアイコンframeの一辺の長さでもある
/// (要求解像度=描画点数で揃える。旧実装は描画32ptに対し解決64ptを要求しており、
/// QLThumbnailGeneratorのscale引数と二重にオーバーフェッチしていた)。
/// 中(64pt)は旧実装が常に要求していた解決サイズと同じ値を引き継ぐ。
enum IconGridSize: Int, Codable, CaseIterable, Comparable, Identifiable, Sendable {
  case small = 48
  case medium = 64
  case large = 96
  case extraLarge = 128

  var id: Int { rawValue }

  static func < (lhs: IconGridSize, rhs: IconGridSize) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  /// FileIconProvider.resolvedIcon(size:)への要求サイズ、およびグリッドセル内で
  /// アイコンを描画するframeの一辺(pt)。
  var iconPointSize: CGFloat { CGFloat(rawValue) }

  /// LazyVGridのGridItem(.adaptive)へ渡す1セルの幅の下限・上限。
  var gridColumnRange: ClosedRange<CGFloat> {
    switch self {
    case .small: 105...142
    case .medium: 140...190
    case .large: 210...285
    case .extraLarge: 280...380
    }
  }

  /// 1セルの最小高さ(アイコン+2行ラベル+パディングを収める値)。
  var cellMinHeight: CGFloat {
    switch self {
    case .small: 90
    case .medium: 120
    case .large: 180
    case .extraLarge: 240
    }
  }

  /// リスト/カラム表示の行アイコン描画サイズ(pt)。.mediumは従来の固定値16ptを引き継ぐ。
  var listIconPointSize: CGFloat {
    switch self {
    case .small: 14
    case .medium: 16
    case .large: 24
    case .extraLarge: 32
    }
  }

  /// リスト/カラム表示の行高(pt)。.mediumは従来の固定値22ptを引き継ぐ。
  var listRowHeight: CGFloat {
    switch self {
    case .small: 20
    case .medium: 22
    case .large: 30
    case .extraLarge: 40
    }
  }

  /// FileIconProviderへ要求する解決サイズ(px相当)。描画ptの2倍にする。
  var listResolvedIconSize: NSSize {
    NSSize(width: listIconPointSize * 2, height: listIconPointSize * 2)
  }

  var displayName: String {
    switch self {
    case .small: String(localized: "小")
    case .medium: String(localized: "中")
    case .large: String(localized: "大")
    case .extraLarge: String(localized: "特大")
    }
  }

  /// ⌘+相当の1段階拡大。既に最大段階なら変化しない(端で飽和する)。
  func larger() -> IconGridSize {
    let cases = Self.allCases
    guard let index = cases.firstIndex(of: self), index + 1 < cases.count else { return self }
    return cases[index + 1]
  }

  /// ⌘-相当の1段階縮小。既に最小段階なら変化しない(端で飽和する)。
  func smaller() -> IconGridSize {
    let cases = Self.allCases
    guard let index = cases.firstIndex(of: self), index > 0 else { return self }
    return cases[index - 1]
  }
}
