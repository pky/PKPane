import AppKit
import Darwin
import Foundation

enum FinderTagResourceWriter {
  private static let attributeName = "com.apple.metadata:_kMDItemUserTags"

  static func setTagNames(_ tagNames: [String], at url: URL) throws {
    let normalizedNames = FinderTagEditing.normalizedNames(tagNames)
    let existingTags = try existingTagEntries(at: url)
    let standardNames = NSWorkspace.shared.fileLabels
    let entries = normalizedNames.map { name in
      if let existing = existingTags[name] { return existing }
      let color =
        standardNames.firstIndex(of: name).flatMap { (0...7).contains($0) ? $0 : nil } ?? 0
      return name + "\n" + String(color)
    }
    let data = try PropertyListSerialization.data(
      fromPropertyList: entries, format: .binary, options: 0)
    // FoundationのtagNames setterは既存色を0に変えることがあるため、生の色番号を保持する。
    let result = data.withUnsafeBytes {
      setxattr(url.path, attributeName, $0.baseAddress, $0.count, 0, 0)
    }
    guard result == 0 else { throw posixError() }
  }

  private static func existingTagEntries(at url: URL) throws -> [String: String] {
    guard let data = try readAttribute(at: url) else { return [:] }
    let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
    guard let entries = propertyList as? [String] else { throw corruptMetadataError() }
    var result: [String: String] = [:]
    for entry in entries {
      let components = entry.split(separator: "\n", omittingEmptySubsequences: false)
      guard components.count == 1 || components.count == 2,
        let name = FinderTagEditing.normalizedNames([entry]).first
      else { throw corruptMetadataError() }
      if components.count == 2 {
        guard let color = Int(components[1]), (0...7).contains(color) else {
          throw corruptMetadataError()
        }
      }
      // 既存タグは色だけでなく保存済みの名前表現もそのまま引き継ぐ。
      if result[name] == nil { result[name] = entry }
    }
    return result
  }

  private static func readAttribute(at url: URL) throws -> Data? {
    // サイズ照会後に別プロセスが属性を拡張した場合だけ、読み取りをやり直す。
    for _ in 0..<3 {
      let size = getxattr(url.path, attributeName, nil, 0, 0, 0)
      if size < 0 {
        if errno == ENOATTR { return nil }
        throw posixError()
      }
      var data = Data(count: size)
      let count = data.withUnsafeMutableBytes {
        getxattr(url.path, attributeName, $0.baseAddress, $0.count, 0, 0)
      }
      if count >= 0 {
        guard count <= data.count else { continue }
        return Data(data.prefix(count))
      }
      if errno == ENOATTR { return nil }
      if errno == ERANGE { continue }
      throw posixError()
    }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ERANGE))
  }

  private static func corruptMetadataError() -> NSError {
    NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadCorruptFile.rawValue)
  }

  private static func posixError() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
}
