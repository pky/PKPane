import Testing

@testable import PKPane

// #expect失敗時のSwift Testing再帰リフレクション(FileBrowserSessionで約35秒、
// 2026-08-28テスト崩壊の増幅器)を遮断する。詳細表示より速度を優先し型名のみ返す。
extension FileBrowserSession: CustomTestStringConvertible {
  public nonisolated var testDescription: String { "FileBrowserSession" }
}

extension FileWorkspaceModel: CustomTestStringConvertible {
  public nonisolated var testDescription: String { "FileWorkspaceModel" }
}

extension TransferQueue: CustomTestStringConvertible {
  public nonisolated var testDescription: String { "TransferQueue" }
}

extension AppMenuModel: CustomTestStringConvertible {
  public nonisolated var testDescription: String { "AppMenuModel" }
}

extension NASConnectionListModel: CustomTestStringConvertible {
  public nonisolated var testDescription: String { "NASConnectionListModel" }
}

extension SFTPConnectionListModel: CustomTestStringConvertible {
  public nonisolated var testDescription: String { "SFTPConnectionListModel" }
}

extension FolderComparisonModel: CustomTestStringConvertible {
  public nonisolated var testDescription: String { "FolderComparisonModel" }
}

extension FileInfoContentModel: CustomTestStringConvertible {
  public nonisolated var testDescription: String { "FileInfoContentModel" }
}

extension FileBrowserColumnState: CustomTestStringConvertible {
  public var testDescription: String { "FileBrowserColumnState(columns: \(columns.count))" }
}
