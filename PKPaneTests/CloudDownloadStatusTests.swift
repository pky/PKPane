import Foundation
import Testing

@testable import PKPane

struct CloudDownloadStatusTests {
  @Test("状態キーがない一般File Providerを取得済みへ丸めない")
  func unknownProviderMetadataStaysUnknown() {
    #expect(
      CloudDownloadStatus.observed(
        isUbiquitous: false, downloadingStatus: nil, isDownloading: nil,
        hasDownloadingError: false, isInCloudFolder: true) == .unknown)
    #expect(
      CloudDownloadStatus.observed(
        isUbiquitous: nil, downloadingStatus: nil, isDownloading: nil,
        hasDownloadingError: false, isInCloudFolder: true) == .unknown)
    #expect(
      CloudDownloadStatus.observed(
        isUbiquitous: false, downloadingStatus: nil, isDownloading: nil,
        hasDownloadingError: false, isInCloudFolder: false) == nil)
  }

  @Test("OSから観測した取得中・失敗・回復を区別し、進捗を推測しない")
  func classifiesObservedStates() {
    #expect(
      CloudDownloadStatus.observed(
        isUbiquitous: true, downloadingStatus: .notDownloaded, isDownloading: true,
        hasDownloadingError: true, isInCloudFolder: true) == .downloading)
    #expect(
      CloudDownloadStatus.observed(
        isUbiquitous: true, downloadingStatus: .notDownloaded, isDownloading: false,
        hasDownloadingError: true, isInCloudFolder: true) == .failed)
    #expect(
      CloudDownloadStatus.observed(
        isUbiquitous: true, downloadingStatus: .current, isDownloading: false,
        hasDownloadingError: false, isInCloudFolder: true) == .current)
    #expect(CloudDownloadStatus(.downloaded) == .downloaded)
    #expect(CloudDownloadStatus(.current) == .current)
    #expect(CloudDownloadStatus(.notDownloaded) == .notDownloaded)
  }

  @Test("取得済みは警告を表示せず、他状態には共通ラベルと説明がある")
  func usesSharedIndicatorMeaning() {
    for status in [CloudDownloadStatus.notDownloaded, .downloading, .failed, .unknown] {
      #expect(status.indicatorLabel != nil)
      #expect(status.indicatorSystemImage != nil)
      #expect(status.indicatorIdentifier != nil)
      #expect(!status.helpText.isEmpty)
    }
    for status in [CloudDownloadStatus.current, .downloaded] {
      #expect(status.indicatorLabel == nil)
      #expect(status.indicatorSystemImage == nil)
      #expect(status.indicatorIdentifier == nil)
    }
  }
}
