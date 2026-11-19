import Darwin
import Foundation

/// AppleDoubleはACLも格納できるためUNPACKを使わず、許可した拡張属性だけ復元する。
/// 形式の出典: apple-oss-distributions/copyfile のapple_double_header/attr_header。
enum ZipAppleDoubleMetadata {
  static let maximumBytes = 16 * 1024 * 1024
  private static let allowed = Set([
    "com.apple.ResourceFork", "com.apple.FinderInfo",
    "com.apple.metadata:_kMDItemUserTags", "com.apple.TextEncoding",
  ])

  struct Decoded {
    var attributes: [String: Data]
    var fullySupported: Bool
  }

  static func decode(_ data: Data) -> Decoded? {
    guard data.count >= 26, data.count <= maximumBytes,
      number(data, 0, 4) == 0x0005_1607, number(data, 4, 4) == 0x0002_0000
    else { return nil }
    let count = number(data, 24, 2)
    guard count > 0, count <= 16, 26 + count * 12 <= data.count else { return nil }
    var result = Decoded(attributes: [:], fullySupported: true)
    var ranges: [Range<Int>] = []
    var ids = Set<Int>()
    for index in 0..<count {
      let position = 26 + index * 12
      let id = number(data, position, 4)
      let start = number(data, position + 4, 4)
      let length = number(data, position + 8, 4)
      guard ids.insert(id).inserted, start >= 26 + count * 12,
        start <= data.count, length <= data.count - start,
        !ranges.contains(where: { $0.overlaps(start..<(start + length)) })
      else { return nil }
      ranges.append(start..<(start + length))
      switch id {
      case 2:
        if length > 0 {
          result.attributes["com.apple.ResourceFork"] = data.subdata(in: start..<(start + length))
        }
      case 9:
        guard length >= 32 else { return nil }
        let info = data.subdata(in: start..<(start + 32))
        if info.contains(where: { $0 != 0 }) { result.attributes["com.apple.FinderInfo"] = info }
        if length > 32 {
          guard decodeAttributes(data, start: start + 34, end: start + length, result: &result)
          else { return nil }
        }
      default:
        result.fullySupported = false
      }
    }
    return result
  }

  private static func decodeAttributes(_ data: Data, start: Int, end: Int, result: inout Decoded)
    -> Bool
  {
    guard start + 36 <= end, number(data, start, 4) == 0x4154_5452 else { return false }
    let total = number(data, start + 8, 4)
    let dataStart = number(data, start + 12, 4)
    let dataLength = number(data, start + 16, 4)
    let count = number(data, start + 34, 2)
    guard total <= end, dataStart >= start + 36, dataStart <= end,
      dataLength <= end - dataStart, total >= dataStart + dataLength, count <= 1024
    else { return false }
    var position = start + 36
    var names = Set<String>()
    var ranges: [Range<Int>] = []
    for _ in 0..<count {
      guard position + 11 <= dataStart else { return false }
      let offset = number(data, position, 4)
      let length = number(data, position + 4, 4)
      let nameLength = number(data, position + 10, 1)
      guard nameLength > 1, nameLength <= 128, position + 11 + nameLength <= dataStart,
        data[position + 10 + nameLength] == 0,
        offset >= dataStart, offset <= dataStart + dataLength,
        length <= dataStart + dataLength - offset,
        !ranges.contains(where: { $0.overlaps(offset..<(offset + length)) }),
        let name = String(
          data: data.subdata(in: (position + 11)..<(position + 10 + nameLength)), encoding: .utf8),
        !name.utf8.contains(0), names.insert(name).inserted
      else { return false }
      ranges.append(offset..<(offset + length))
      if name == "com.apple.provenance" {
        // 他のMacの由来情報を移植しない。本体の既存属性には触れない。
      } else if allowed.contains(name), result.attributes[name] == nil {
        result.attributes[name] = data.subdata(in: offset..<(offset + length))
      } else {
        result.fullySupported = false
      }
      position += (11 + nameLength + 3) & ~3
    }
    return position <= dataStart
  }

  private static func number(_ data: Data, _ offset: Int, _ bytes: Int) -> Int {
    data[offset..<(offset + bytes)].reduce(0) { ($0 << 8) | Int($1) }
  }

  static func restore(in root: URL, cancellationProgress: Progress) throws {
    let metadataRoot = root.appending(path: "__MACOSX")
    var status = stat()
    // 側車用ルート自体がシンボリックリンクの場合も列挙しない。
    guard lstat(metadataRoot.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { return }
    var pending = ["__MACOSX"]
    var paths: [String] = []
    while let directoryPath = pending.popLast() {
      try Task.checkCancellation()
      if cancellationProgress.isCancelled { throw CancellationError() }
      let directoryURL = root.appending(path: directoryPath)
      for url in try FileSystemDirectoryEntries.children(of: directoryURL) {
        try Task.checkCancellation()
        if cancellationProgress.isCancelled { throw CancellationError() }
        var entryStatus = stat()
        guard lstat(url.path, &entryStatus) == 0 else { continue }
        let path = directoryPath + "/" + url.lastPathComponent
        switch entryStatus.st_mode & S_IFMT {
        case S_IFDIR: pending.append(path)
        case S_IFREG: paths.append(path)
        default: continue
        }
      }
    }
    try restore(in: root, paths: paths, cancellationProgress: cancellationProgress)
  }

  static func restore(in root: URL, paths: [String], cancellationProgress: Progress) throws {
    let manager = FileManager.default
    for path in paths where path.hasPrefix("__MACOSX/") {
      try Task.checkCancellation()
      if cancellationProgress.isCancelled { throw CancellationError() }
      let components = path.split(separator: "/").map(String.init)
      guard let name = components.last, name.hasPrefix("._"), name.count > 2 else { continue }
      let targetComponents = Array(components.dropFirst().dropLast()) + [String(name.dropFirst(2))]
      guard safePath(root: root, components: components),
        safePath(root: root, components: targetComponents)
      else { continue }
      let sidecar = root.appending(path: path)
      let values = try sidecar.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      guard values.isRegularFile == true, let size = values.fileSize, size <= maximumBytes,
        let decoded = decode(try Data(contentsOf: sidecar))
      else { continue }
      let target = root.appending(path: targetComponents.joined(separator: "/"))
      let descriptor = open(target.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
      guard descriptor >= 0 else { continue }
      defer { close(descriptor) }
      var status = stat()
      guard fstat(descriptor, &status) == 0,
        status.st_mode & S_IFMT == S_IFREG || status.st_mode & S_IFMT == S_IFDIR
      else { continue }
      var restored = true
      for (name, value) in decoded.attributes {
        try Task.checkCancellation()
        if cancellationProgress.isCancelled { throw CancellationError() }
        let succeeded = value.withUnsafeBytes { buffer in
          fsetxattr(descriptor, name, buffer.baseAddress, buffer.count, 0, XATTR_CREATE) == 0
        }
        if !succeeded { restored = false }
      }
      guard restored, decoded.fullySupported else { continue }
      try manager.removeItem(at: sidecar)
      // 消費した側車の空ディレクトリだけ除去し、任意のユーザーデータは残す。
      var parent = sidecar.deletingLastPathComponent()
      while parent.path != root.path {
        // Foundationとrmdirにも側車の特別扱いがあるため、生の全項目で空を確認する。
        guard try FileSystemDirectoryEntries.children(of: parent).isEmpty,
          rmdir(parent.path) == 0
        else { break }
        parent.deleteLastPathComponent()
      }
    }
  }

  private static func safePath(root: URL, components: [String]) -> Bool {
    var current = root
    for component in components {
      guard component != ".", component != "..", !component.isEmpty else { return false }
      current.append(path: component)
      var status = stat()
      guard lstat(current.path, &status) == 0, status.st_mode & S_IFMT != S_IFLNK else {
        return false
      }
    }
    return true
  }
}

/// Foundationが特別除外する._名も含め、操作対象を欠落させず直下だけを列挙する。
enum FileSystemDirectoryEntries {
  static func children(of directoryURL: URL) throws -> [URL] {
    let descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard let directory = fdopendir(descriptor) else {
      let failure = errno
      close(descriptor)
      throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
    }
    defer { closedir(directory) }
    var urls: [URL] = []
    while true {
      try Task.checkCancellation()
      errno = 0
      guard let entry = readdir(directory) else {
        guard errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return urls
      }
      let nameLength = Int(entry.pointee.d_namlen) + 1
      let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: nameLength) {
          String(validatingCString: $0)
        }
      }
      guard let name else { throw CocoaError(.fileReadInapplicableStringEncoding) }
      guard name != ".", name != ".." else { continue }
      urls.append(directoryURL.appending(path: name))
    }
  }
}
