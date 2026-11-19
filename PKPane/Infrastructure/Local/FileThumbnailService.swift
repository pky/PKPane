import AppKit
import QuickLookThumbnailing

/// QuickLookThumbnailing によるサムネイル生成と小さなメモリキャッシュ。
/// キャッシュキーは URL+更新日時(内容が変われば作り直す)。
@MainActor
final class FileThumbnailService {
  static let shared = FileThumbnailService()

  private let cache = NSCache<NSString, NSImage>()

  init() {
    cache.countLimit = 64
  }

  /// キーにsizeを含めるのは、同じURLでもアイコン表示のサイズ切替・情報を見るダイアログの
  /// サムネイル・ホバープレビューなど要求サイズの異なる複数の呼び出し元が同じキャッシュを
  /// 共有しているため(size抜きのキーだと先勝ちの解像度が別サイズの表示へ誤って流用される)。
  private func cacheKey(for url: URL, modifiedAt: Date?, size: CGSize) -> NSString {
    "\(url.path)|\(modifiedAt?.timeIntervalSince1970 ?? 0)|\(size.width)x\(size.height)"
      as NSString
  }

  func cachedThumbnail(for url: URL, modifiedAt: Date?, size: CGSize) -> NSImage? {
    cache.object(forKey: cacheKey(for: url, modifiedAt: modifiedAt, size: size))
  }

  func removeAll() {
    cache.removeAllObjects()
  }

  func thumbnail(for url: URL, modifiedAt: Date?, size: CGSize) async -> NSImage? {
    let key = cacheKey(for: url, modifiedAt: modifiedAt, size: size)
    if let cached = cache.object(forKey: key) {
      return cached
    }
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    let request = QLThumbnailGenerator.Request(
      fileAt: url, size: size, scale: scale, representationTypes: .all)
    guard
      let representation = try? await QLThumbnailGenerator.shared
        .generateBestRepresentation(for: request)
    else {
      return nil
    }
    let image = representation.nsImage
    cache.setObject(image, forKey: key)
    return image
  }
}
