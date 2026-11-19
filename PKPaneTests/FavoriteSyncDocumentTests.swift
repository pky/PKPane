import Foundation
import Testing

@testable import PKPane

struct FavoriteSyncDocumentTests {
  @Test("ローカル・NAS・SFTPのポータブル表現をJSONで往復する")
  func codecRoundTripsMixedFavorites() throws {
    let date = Date(timeIntervalSince1970: 1_000)
    let favorites = [
      PortableFavorite(provider: .local, path: "/Users/test/Documents", displayName: "書類"),
      PortableFavorite(
        provider: .smb,
        connectionIdentifier: "smb://nas.local/share",
        path: "/projects",
        displayName: "NAS projects"),
      PortableFavorite(
        provider: .sftp,
        connectionIdentifier: "sftp://tester@example.com:22",
        path: "/srv/projects",
        displayName: "SFTP projects"),
    ]
    let document = FavoriteSyncMerger.initialDocument(favorites: favorites, at: date).document

    let decoded = try FavoriteSyncCodec.decode(FavoriteSyncCodec.encode(document))

    #expect(decoded == document)
  }

  @Test("別端末で追加した項目を和集合で取り込む")
  func mergesAddedFavoritesAsUnion() {
    let base = Date(timeIntervalSince1970: 1_000)
    let local = FavoriteSyncMerger.initialDocument(
      favorites: [favorite("/local")], at: base
    ).document
    let remote = FavoriteSyncMerger.initialDocument(
      favorites: [favorite("/remote")], at: base.addingTimeInterval(1)
    ).document

    let merged = FavoriteSyncMerger.merge(local, remote)

    #expect(Set(merged.items.map(\.favorite.path)) == ["/local", "/remote"])
  }

  @Test("新しい削除トゥームストーンを古い項目より優先して復活を防ぐ")
  func tombstonePreventsDeletedFavoriteFromReturning() {
    let addedAt = Date(timeIntervalSince1970: 1_000)
    let deletedAt = addedAt.addingTimeInterval(10)
    let staleRemote = FavoriteSyncMerger.initialDocument(
      favorites: [favorite("/deleted")], at: addedAt
    ).document
    let localDeletion = FavoriteSyncMerger.applyingLocalFavorites(
      [], to: staleRemote, at: deletedAt
    ).document

    let firstMerge = FavoriteSyncMerger.merge(localDeletion, staleRemote)
    let secondMerge = FavoriteSyncMerger.merge(firstMerge, staleRemote)

    #expect(firstMerge.items.isEmpty)
    #expect(secondMerge.items.isEmpty)
    #expect(secondMerge.tombstones.first?.deletedAt == deletedAt)
  }

  @Test("削除後に明示的に再追加した新しい項目は復元する")
  func newerReadditionWinsOverTombstone() {
    let addedAt = Date(timeIntervalSince1970: 1_000)
    let original = FavoriteSyncMerger.initialDocument(
      favorites: [favorite("/restored")], at: addedAt
    ).document
    let deletion = FavoriteSyncMerger.applyingLocalFavorites(
      [], to: original, at: addedAt.addingTimeInterval(10)
    ).document
    let readdition = FavoriteSyncMerger.applyingLocalFavorites(
      [favorite("/restored")], to: deletion, at: addedAt.addingTimeInterval(20)
    ).document

    let merged = FavoriteSyncMerger.merge(deletion, readdition)

    #expect(merged.items.map(\.favorite.path) == ["/restored"])
  }

  @Test("並び順は更新時刻が新しい端末を優先する")
  func newerOrderWins() {
    let base = Date(timeIntervalSince1970: 1_000)
    let first = favorite("/first")
    let second = favorite("/second")
    let original = FavoriteSyncMerger.initialDocument(
      favorites: [first, second], at: base
    ).document
    let reordered = FavoriteSyncMerger.applyingLocalFavorites(
      [second, first], to: original, at: base.addingTimeInterval(10)
    ).document

    let merged = FavoriteSyncMerger.merge(original, reordered)

    #expect(merged.items.map(\.favorite.path) == ["/second", "/first"])
  }

  @Test("トゥームストーンとお気に入りを上限までに制限する")
  func boundsFavoritesAndTombstones() {
    let base = Date(timeIntervalSince1970: 1_000)
    let favorites = (0..<(FavoriteSyncMerger.favoriteLimit + 25)).map {
      favorite("/item-\($0)")
    }
    let initial = FavoriteSyncMerger.initialDocument(favorites: favorites, at: base)
    #expect(initial.document.items.count == FavoriteSyncMerger.favoriteLimit)
    #expect(initial.droppedFavoriteCount == 25)

    let oldTombstones = (0..<(FavoriteSyncMerger.tombstoneLimit - 1)).map { index in
      FavoriteSyncTombstone(
        key: favorite("/deleted-\(index)").key,
        deletedAt: base.addingTimeInterval(Double(index)))
    }
    let deletionDate = base.addingTimeInterval(Double(FavoriteSyncMerger.tombstoneLimit))
    let beforeDeletion = FavoriteSyncDocument(
      items: Array(initial.document.items.prefix(2)), tombstones: oldTombstones,
      orderModifiedAt: base)
    let document = FavoriteSyncMerger.applyingLocalFavorites(
      [], to: beforeDeletion, at: deletionDate
    ).document

    #expect(document.items.isEmpty)
    #expect(document.tombstones.count == FavoriteSyncMerger.tombstoneLimit)
    #expect(!document.tombstones.contains { $0.key == oldTombstones[0].key })
    for item in beforeDeletion.items {
      #expect(
        document.tombstones.contains {
          $0.key == item.favorite.key && $0.deletedAt == deletionDate
        })
    }
  }

  @Test("上限から溢れた削除は長期オフライン端末との再統合で復活しうる")
  func prunedTombstoneAllowsStaleOfflineFavoriteToReturn() {
    let base = Date(timeIntervalSince1970: 1_000)
    let staleFavorite = favorite("/stale-offline")
    let staleOfflineDocument = FavoriteSyncMerger.initialDocument(
      favorites: [staleFavorite], at: base
    ).document
    let deletion = FavoriteSyncMerger.applyingLocalFavorites(
      [], to: staleOfflineDocument, at: base.addingTimeInterval(1)
    ).document
    let laterTombstones = (0..<(FavoriteSyncMerger.tombstoneLimit - 1)).map { index in
      FavoriteSyncTombstone(
        key: favorite("/later-deletion-\(index)").key,
        deletedAt: base.addingTimeInterval(Double(index + 2)))
    }
    let boundaryDocument = FavoriteSyncDocument(
      items: [], tombstones: deletion.tombstones + laterTombstones,
      orderModifiedAt: deletion.orderModifiedAt)
    let lastAddedAt = base.addingTimeInterval(Double(FavoriteSyncMerger.tombstoneLimit + 1))
    let addition = FavoriteSyncMerger.applyingLocalFavorites(
      [favorite("/last-deletion")], to: boundaryDocument, at: lastAddedAt
    ).document
    let onlineDocument = FavoriteSyncMerger.applyingLocalFavorites(
      [], to: addition, at: lastAddedAt.addingTimeInterval(1)
    ).document

    let merged = FavoriteSyncMerger.merge(onlineDocument, staleOfflineDocument)

    #expect(onlineDocument.tombstones.count == FavoriteSyncMerger.tombstoneLimit)
    #expect(!onlineDocument.tombstones.contains { $0.key == staleFavorite.key })
    #expect(merged.items.map(\.favorite.key).contains(staleFavorite.key))
  }

  private func favorite(_ path: String) -> PortableFavorite {
    PortableFavorite(provider: .local, path: path, displayName: path)
  }
}
