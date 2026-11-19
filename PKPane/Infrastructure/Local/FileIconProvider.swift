import AppKit
import UniformTypeIdentifiers

/// Finder相当の実アイコン提供。同期API(拡張子・種別ベース、ファイルI/Oなし)と
/// 非同期API(アプリの実アイコン・画像等のミニサムネイル、ディスクI/Oあり)の2層構成。
/// 同期APIは列挙ホットパス(NSTableView/LazyVGridのセル構築)に置ける速さを保証し、
/// 非同期APIの結果が揃い次第、呼び出し元がセルを差し替える形を前提にする。
@MainActor
final class FileIconProvider {
  static let shared = FileIconProvider()

  /// 拡張子(小文字)→アイコンのキャッシュ。@MainActor内のみで読み書きするためDictionaryでよい。
  private var extensionIconCache: [String: NSImage] = [:]
  /// アプリ実アイコン・サムネイルのキャッシュ。キーはURL+更新日時(内容が変われば作り直す)。
  private let resolvedIconCache = NSCache<NSString, NSImage>()
  /// resolvedIconが解決不能(nil)だったキーの既知失敗キャッシュ。これが無いと、実物を
  /// 持たないファイル(単純なテキストファイル等)を表示するたびに毎回resolvedIconが
  /// 再試行され続けてしまう。キーにmodifiedAtを含むため、ファイル更新時は別キーとなり
  /// 自然に再評価される。
  private let failedResolutionCache = NSCache<NSString, NSNumber>()

  private lazy var folderIcon: NSImage = NSWorkspace.shared.icon(for: .folder)
  private lazy var genericDocumentIcon: NSImage = NSWorkspace.shared.icon(for: .data)
  private lazy var symbolicLinkIcon: NSImage =
    NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? genericDocumentIcon
  private lazy var aliasFileIcon: NSImage =
    NSImage(systemSymbolName: "arrow.turn.down.right", accessibilityDescription: nil)
    ?? genericDocumentIcon

  init() {
    resolvedIconCache.countLimit = 256
    failedResolutionCache.countLimit = 256
  }

  /// 即時返却用の拡張子・種別ベースアイコン。ファイルI/Oを一切行わない
  /// (NSWorkspace.icon(for: UTType)はUTIカタログ参照のみ)ため、列挙ホットパスで安全に呼べる。
  /// シンボリックリンク・エイリアスは実体の種別に関わらず従来通りのリンク系SF Symbolを返す。
  func icon(for item: FileItem) -> NSImage {
    if item.isAliasFile { return aliasFileIcon }
    if item.isSymbolicLink { return symbolicLinkIcon }
    if item.isDirectory, !isApplicationExtension(item.url.pathExtension) {
      return folderIcon
    }
    let ext = item.url.pathExtension.lowercased()
    guard !ext.isEmpty else { return genericDocumentIcon }
    if let cached = extensionIconCache[ext] {
      return cached
    }
    let icon: NSImage
    if let utType = UTType(filenameExtension: ext) {
      icon = NSWorkspace.shared.icon(for: utType)
    } else {
      icon = genericDocumentIcon
    }
    extensionIconCache[ext] = icon
    return icon
  }

  /// resolvedIconのキャッシュ済み結果を同期取得する。ヒットすればTaskを起こさず即時反映できる。
  /// キャッシュキーはsizeを含むため、同じ項目でも要求サイズが異なれば別エントリになる
  /// (アイコン表示のサイズ切替で異なる解像度の画像が混在して返らないようにするため)。
  func cachedResolvedIcon(for item: FileItem, size: CGSize) -> NSImage? {
    guard item.url.isFileURL else { return nil }
    return resolvedIconCache.object(forKey: resolvedCacheKey(for: item, size: size))
  }

  /// 前回resolvedIconを試みて解決不能(nil)だったことが判明済みかどうかを同期判定する。
  /// trueの場合、呼び出し元はresolvedIconのTaskを発行すべきでない(重い処理の再試行を防ぐ)。
  func isKnownUnresolvable(for item: FileItem, size: CGSize) -> Bool {
    guard item.url.isFileURL else { return false }
    return failedResolutionCache.object(forKey: resolvedCacheKey(for: item, size: size)) != nil
  }

  func removeAll() {
    extensionIconCache.removeAll()
    resolvedIconCache.removeAllObjects()
    failedResolutionCache.removeAllObjects()
  }

  /// 実物のアイコン・サムネイルを解決する。ローカルfile URLのみ対象(SFTP等のリモートは
  /// ダウンロードが必要になるため対象外、拡張子アイコンのままでよい)。シンボリックリンク・
  /// エイリアスはicon(for:)のリンク系SF Symbol表示を維持するため対象外(常にnil)。
  func resolvedIcon(for item: FileItem, size: CGSize) async -> NSImage? {
    guard item.url.isFileURL, !Task.isCancelled else { return nil }
    let key = resolvedCacheKey(for: item, size: size)
    if let cached = resolvedIconCache.object(forKey: key) {
      return cached
    }
    if failedResolutionCache.object(forKey: key) != nil {
      return nil
    }
    let resolved: NSImage?
    if item.isSymbolicLink || item.isAliasFile {
      resolved = nil
    } else if isApplicationBundle(item) {
      // NSWorkspace.icon(forFile:)はディスクI/Oを伴いうるが、AppKitの想定通りMainActorから呼ぶ。
      // 呼び出し頻度は非同期解決経路のみに限定し、同期の icon(for:) からは呼ばない。
      resolved = NSWorkspace.shared.icon(forFile: item.url.path)
    } else if isThumbnailable(item) {
      resolved = await FileThumbnailService.shared.thumbnail(
        for: item.url, modifiedAt: item.modifiedAt, size: size)
    } else {
      resolved = nil
    }
    // Quick Lookの取消はnilで戻る。取消を恒久的な解決失敗として記録すると、再表示時にも
    // サムネイルを再試行できなくなるため、キャッシュ更新前に終了する。
    guard !Task.isCancelled else { return nil }
    if let resolved {
      resolvedIconCache.setObject(resolved, forKey: key)
    } else {
      failedResolutionCache.setObject(1, forKey: key)
    }
    return resolved
  }

  private func resolvedCacheKey(for item: FileItem, size: CGSize) -> NSString {
    "\(item.url.path)|\(item.modifiedAt?.timeIntervalSince1970 ?? 0)|\(size.width)x\(size.height)"
      as NSString
  }

  private func isApplicationExtension(_ pathExtension: String) -> Bool {
    isApplicationBundle(pathExtension: pathExtension)
  }

  private func isApplicationBundle(_ item: FileItem) -> Bool {
    isApplicationBundle(pathExtension: item.url.pathExtension)
  }

  private func isApplicationBundle(pathExtension: String) -> Bool {
    let ext = pathExtension.lowercased()
    guard !ext.isEmpty else { return false }
    if ext == "app" { return true }
    guard let utType = UTType(filenameExtension: ext) else { return false }
    return utType.conforms(to: .application)
  }

  private func isThumbnailable(_ item: FileItem) -> Bool {
    let ext = item.url.pathExtension.lowercased()
    guard !ext.isEmpty, let utType = UTType(filenameExtension: ext) else { return false }
    return utType.conforms(to: .image) || utType.conforms(to: .pdf) || utType.conforms(to: .movie)
  }
}
