import AppKit
import Darwin
import Foundation
import Testing

@testable import PKPane

@MainActor
struct FinderTagResourceWriterTests {
  @Test("標準色名の追加は実Finderタグへ正しい色番号を保存する")
  func writesStandardColorNumbers() throws {
    try withTemporaryFile { url in
      let labels = NSWorkspace.shared.fileLabels
      let red = try #require(labels.indices.contains(6) ? labels[6] : nil)
      try #require(!red.isEmpty)

      try FinderTagResourceWriter.setTagNames([red], at: url)

      #expect(try rawTagNames(at: url) == [red + "\n6"])
    }
  }

  @Test("別色の追加と解除でも既存の独自タグ名と色番号を保持する")
  func preservesCustomColorsWhenAddingAndRemovingStandardColor() throws {
    try withTemporaryFile { url in
      let labels = NSWorkspace.shared.fileLabels
      let red = try #require(labels.indices.contains(6) ? labels[6] : nil)
      try #require(!red.isEmpty)
      let custom = "独自の青タグ"
      try writeRawTags([custom + "\n4"], at: url)

      try FinderTagResourceWriter.setTagNames([custom, red], at: url)
      #expect(try rawTagNames(at: url) == [custom + "\n4", red + "\n6"])

      try FinderTagResourceWriter.setTagNames([custom], at: url)
      #expect(try rawTagNames(at: url) == [custom + "\n4"])
    }
  }

  @Test("全タグの解除は実Finderタグを空にする")
  func removesAllTags() throws {
    try withTemporaryFile { url in
      try writeRawTags(["独自の青タグ\n4"], at: url)

      try FinderTagResourceWriter.setTagNames([], at: url)

      #expect(try rawTagNames(at: url).isEmpty)
    }
  }

  @Test("不正な既存Finderタグを空扱いせず上書きを拒否する")
  func refusesMalformedExistingAttribute() throws {
    try withTemporaryFile { url in
      let invalid = Data("不正なplist".utf8)
      try writeAttribute(invalid, at: url)
      var refused = false
      do {
        try FinderTagResourceWriter.setTagNames(["追加"], at: url)
      } catch {
        refused = true
      }
      #expect(refused)
      #expect(try readAttribute(at: url) == invalid)
    }
  }

  @Test("配列以外の既存plistも上書きを拒否する")
  func refusesWrongPropertyListType() throws {
    try withTemporaryFile { url in
      let invalid = try PropertyListSerialization.data(
        fromPropertyList: ["既存": 4], format: .binary, options: 0)
      try writeAttribute(invalid, at: url)
      var refused = false
      do {
        try FinderTagResourceWriter.setTagNames(["追加"], at: url)
      } catch {
        refused = true
      }
      #expect(refused)
      #expect(try readAttribute(at: url) == invalid)
    }
  }

  private let attributeName = "com.apple.metadata:_kMDItemUserTags"

  private func withTemporaryFile(_ work: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("tags.txt")
    try Data().write(to: url)
    try work(url)
  }

  private func rawTagNames(at url: URL) throws -> [String] {
    let data = try readAttribute(at: url)
    let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try #require(propertyList as? [String])
  }

  private func writeRawTags(_ names: [String], at url: URL) throws {
    try writeAttribute(
      PropertyListSerialization.data(fromPropertyList: names, format: .binary, options: 0), at: url)
  }

  private func readAttribute(at url: URL) throws -> Data {
    let size = getxattr(url.path, attributeName, nil, 0, 0, 0)
    guard size >= 0 else { throw posixError() }
    var data = Data(count: size)
    let count = data.withUnsafeMutableBytes {
      getxattr(url.path, attributeName, $0.baseAddress, $0.count, 0, 0)
    }
    guard count >= 0 else { throw posixError() }
    return Data(data.prefix(count))
  }

  private func writeAttribute(_ data: Data, at url: URL) throws {
    let result = data.withUnsafeBytes {
      setxattr(url.path, attributeName, $0.baseAddress, $0.count, 0, 0)
    }
    guard result == 0 else { throw posixError() }
  }

  private func posixError() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
}
