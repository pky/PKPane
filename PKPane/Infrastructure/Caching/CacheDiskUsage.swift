import Foundation

enum CacheDiskUsage {
  static func totalBytes(in directories: [URL]) async -> UInt64 {
    await Task.detached(priority: .utility) {
      directories.reduce(into: UInt64(0)) { total, directory in
        let directoryBytes = bytes(in: directory)
        let (sum, overflow) = total.addingReportingOverflow(directoryBytes)
        total = overflow ? .max : sum
      }
    }.value
  }

  private static func bytes(in directory: URL) -> UInt64 {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: keys,
        options: [],
        errorHandler: { _, _ in true })
    else {
      return 0
    }
    var total: UInt64 = 0
    for case let fileURL as URL in enumerator {
      guard
        let values = try? fileURL.resourceValues(forKeys: Set(keys)),
        values.isRegularFile == true,
        let fileSize = values.fileSize,
        fileSize >= 0
      else {
        continue
      }
      let (sum, overflow) = total.addingReportingOverflow(UInt64(fileSize))
      total = overflow ? .max : sum
    }
    return total
  }
}
