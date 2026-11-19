import Foundation
import Testing

@testable import PKPane

@MainActor
struct DirectoryMonitorTests {
  @Test("存在するフォルダの監視を開始して停止できる")
  func startsAndStopsMonitoringDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let monitor = DirectoryMonitor(url: root) {}

    try monitor.start()
    monitor.stop()
  }
}
