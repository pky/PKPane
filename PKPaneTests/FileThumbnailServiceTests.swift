import AppKit
import Testing

@testable import PKPane

@MainActor
struct FileThumbnailServiceTests {
  @Test("PNGファイルのサムネイルを生成しキャッシュする")
  func generatesAndCachesThumbnail() async throws {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "thumb-test-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
      NSColor.red.setFill()
      rect.fill()
      return true
    }
    let tiff = try #require(image.tiffRepresentation)
    let png = try #require(
      NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    try png.write(to: url)

    let service = FileThumbnailService()
    let modifiedAt = Date(timeIntervalSince1970: 1000)
    let size = CGSize(width: 64, height: 64)
    let first = await service.thumbnail(for: url, modifiedAt: modifiedAt, size: size)
    #expect(first != nil)
    #expect(service.cachedThumbnail(for: url, modifiedAt: modifiedAt, size: size) != nil)

    service.removeAll()

    #expect(service.cachedThumbnail(for: url, modifiedAt: modifiedAt, size: size) == nil)
  }

  @Test("同じファイルでも要求サイズが異なればキャッシュが別エントリになる")
  func cachesThumbnailSeparatelyPerRequestedSize() async throws {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "thumb-size-test-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
      NSColor.blue.setFill()
      rect.fill()
      return true
    }
    let tiff = try #require(image.tiffRepresentation)
    let png = try #require(
      NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    try png.write(to: url)

    let service = FileThumbnailService()
    let modifiedAt = Date(timeIntervalSince1970: 2000)
    let requestedSize = CGSize(width: 48, height: 48)
    let otherSize = CGSize(width: 128, height: 128)
    _ = await service.thumbnail(for: url, modifiedAt: modifiedAt, size: requestedSize)

    #expect(service.cachedThumbnail(for: url, modifiedAt: modifiedAt, size: requestedSize) != nil)
    #expect(service.cachedThumbnail(for: url, modifiedAt: modifiedAt, size: otherSize) == nil)
  }
}
