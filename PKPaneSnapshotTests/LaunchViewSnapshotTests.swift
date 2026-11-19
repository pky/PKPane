import AppKit
import SnapshotTesting
import SwiftUI
import Testing

@testable import PKPane

@Suite("起動画面VRT", .serialized)
@MainActor
struct LaunchViewSnapshotTests {
  @Test("ライトモード")
  func lightAppearance() throws {
    let view = LaunchEmptyStateView(content: .initial, chooseFolder: {})
      .environment(\.colorScheme, .light)
      .frame(width: 560, height: 360)
    let renderer = ImageRenderer(content: view)
    renderer.proposedSize = ProposedViewSize(width: 560, height: 360)
    renderer.scale = 1
    let image = try #require(renderer.nsImage)

    assertSnapshot(of: image, as: .image)
  }
}
