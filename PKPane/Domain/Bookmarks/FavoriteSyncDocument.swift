import Foundation

enum PortableFavoriteProvider: String, Codable, Hashable, Sendable {
  case local
  case smb
  case sftp
}

struct PortableFavorite: Codable, Hashable, Sendable {
  struct Key: Codable, Hashable, Sendable {
    let provider: PortableFavoriteProvider
    let connectionIdentifier: String?
    let path: String
  }

  let provider: PortableFavoriteProvider
  let connectionIdentifier: String?
  let path: String
  let displayName: String

  init(
    provider: PortableFavoriteProvider,
    connectionIdentifier: String? = nil,
    path: String,
    displayName: String
  ) {
    self.provider = provider
    self.connectionIdentifier = connectionIdentifier
    self.path = path
    self.displayName = displayName
  }

  var key: Key {
    Key(provider: provider, connectionIdentifier: connectionIdentifier, path: path)
  }
}

struct FavoriteSyncItem: Codable, Equatable, Sendable {
  let favorite: PortableFavorite
  let modifiedAt: Date
}

struct FavoriteSyncTombstone: Codable, Equatable, Sendable {
  let key: PortableFavorite.Key
  let deletedAt: Date
}

struct FavoriteSyncDocument: Codable, Equatable, Sendable {
  static let currentVersion = 1

  let version: Int
  let items: [FavoriteSyncItem]
  let tombstones: [FavoriteSyncTombstone]
  let orderModifiedAt: Date

  init(
    version: Int = currentVersion,
    items: [FavoriteSyncItem],
    tombstones: [FavoriteSyncTombstone],
    orderModifiedAt: Date
  ) {
    self.version = version
    self.items = items
    self.tombstones = tombstones
    self.orderModifiedAt = orderModifiedAt
  }
}

struct FavoriteSyncLocalUpdate: Equatable, Sendable {
  let document: FavoriteSyncDocument
  let droppedFavoriteCount: Int
}

enum FavoriteSyncCodec {
  static func encode(_ document: FavoriteSyncDocument) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(document)
  }

  static func decode(_ data: Data) throws -> FavoriteSyncDocument {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode(FavoriteSyncDocument.self, from: data)
  }
}

enum PortableFavoriteConnectionIdentifier {
  static func smb(host: String, shareName: String) -> String? {
    var components = URLComponents()
    components.scheme = "smb"
    components.host = host.lowercased()
    components.path = "/\(shareName)"
    return components.string
  }

  static func sftp(target: SFTPConnectionTarget) -> String? {
    var components = URLComponents()
    components.scheme = "sftp"
    components.host = target.host.lowercased()
    components.port = target.port
    components.user = target.username
    return components.string
  }

  static func smbLocation(
    identifier: String,
    remotePath: String
  ) -> SMBFolderLocation? {
    guard let components = URLComponents(string: identifier),
      components.scheme == "smb",
      let host = components.host,
      let shareName = components.path.split(separator: "/").first.map(String.init)
    else {
      return nil
    }
    return SMBFolderLocation(
      host: host,
      shareName: shareName,
      relativePathComponents: remotePath.split(separator: "/").map(String.init))
  }

  static func sftpTarget(identifier: String) -> SFTPConnectionTarget? {
    guard let components = URLComponents(string: identifier),
      components.scheme == "sftp",
      let host = components.host,
      let port = components.port,
      let username = components.user
    else {
      return nil
    }
    return try? SFTPConnectionTarget(host: host, port: port, username: username)
  }
}

enum FavoriteSyncMerger {
  static let favoriteLimit = 500
  static let tombstoneLimit = 500

  static func initialDocument(
    favorites: [PortableFavorite],
    at date: Date
  ) -> FavoriteSyncLocalUpdate {
    applyingLocalFavorites(
      favorites,
      to: FavoriteSyncDocument(items: [], tombstones: [], orderModifiedAt: date),
      at: date)
  }

  static func applyingLocalFavorites(
    _ favorites: [PortableFavorite],
    to document: FavoriteSyncDocument,
    at date: Date
  ) -> FavoriteSyncLocalUpdate {
    let uniqueFavorites = removingDuplicates(from: favorites)
    let boundedFavorites = Array(uniqueFavorites.prefix(favoriteLimit))
    let allLocalKeys = Set(uniqueFavorites.map(\.key))
    let previousItems = Dictionary(
      uniqueKeysWithValues: document.items.map {
        ($0.favorite.key, $0)
      })

    let items = boundedFavorites.map { favorite in
      guard let previous = previousItems[favorite.key] else {
        return FavoriteSyncItem(favorite: favorite, modifiedAt: date)
      }
      guard previous.favorite != favorite else { return previous }
      return FavoriteSyncItem(favorite: favorite, modifiedAt: date)
    }

    var tombstonesByKey = latestTombstones(in: document.tombstones)
    for previous in document.items where !allLocalKeys.contains(previous.favorite.key) {
      let key = previous.favorite.key
      if tombstonesByKey[key]?.deletedAt ?? .distantPast < date {
        tombstonesByKey[key] = FavoriteSyncTombstone(key: key, deletedAt: date)
      }
    }

    let previousOrder = document.items.map(\.favorite.key)
    let nextOrder = items.map(\.favorite.key)
    let orderModifiedAt = previousOrder == nextOrder ? document.orderModifiedAt : date

    return FavoriteSyncLocalUpdate(
      document: FavoriteSyncDocument(
        items: items,
        tombstones: prunedTombstones(Array(tombstonesByKey.values)),
        orderModifiedAt: orderModifiedAt),
      droppedFavoriteCount: max(0, uniqueFavorites.count - boundedFavorites.count))
  }

  static func merge(
    _ first: FavoriteSyncDocument,
    _ second: FavoriteSyncDocument
  ) -> FavoriteSyncDocument {
    var itemsByKey: [PortableFavorite.Key: FavoriteSyncItem] = [:]
    for item in first.items + second.items {
      guard let current = itemsByKey[item.favorite.key] else {
        itemsByKey[item.favorite.key] = item
        continue
      }
      if item.modifiedAt > current.modifiedAt
        || (item.modifiedAt == current.modifiedAt
          && favoriteTieBreaker(item.favorite) > favoriteTieBreaker(current.favorite))
      {
        itemsByKey[item.favorite.key] = item
      }
    }

    let tombstonesByKey = latestTombstones(in: first.tombstones + second.tombstones)
    itemsByKey = itemsByKey.filter { key, item in
      guard let tombstone = tombstonesByKey[key] else { return true }
      return item.modifiedAt > tombstone.deletedAt
    }

    let preferred: FavoriteSyncDocument
    let secondary: FavoriteSyncDocument
    if first.orderModifiedAt > second.orderModifiedAt
      || (first.orderModifiedAt == second.orderModifiedAt
        && orderTieBreaker(first) >= orderTieBreaker(second))
    {
      preferred = first
      secondary = second
    } else {
      preferred = second
      secondary = first
    }

    var orderedKeys: [PortableFavorite.Key] = []
    var insertedKeys: Set<PortableFavorite.Key> = []
    for key in (preferred.items + secondary.items).map(\.favorite.key)
    where itemsByKey[key] != nil && insertedKeys.insert(key).inserted {
      orderedKeys.append(key)
    }
    let remainingKeys = itemsByKey.keys.filter { !insertedKeys.contains($0) }
      .sorted { keyTieBreaker($0) < keyTieBreaker($1) }
    orderedKeys.append(contentsOf: remainingKeys)

    let items = orderedKeys.prefix(favoriteLimit).compactMap { itemsByKey[$0] }
    return FavoriteSyncDocument(
      items: items,
      tombstones: prunedTombstones(Array(tombstonesByKey.values)),
      orderModifiedAt: max(first.orderModifiedAt, second.orderModifiedAt))
  }

  private static func removingDuplicates(
    from favorites: [PortableFavorite]
  ) -> [PortableFavorite] {
    var keys: Set<PortableFavorite.Key> = []
    return favorites.filter { keys.insert($0.key).inserted }
  }

  private static func latestTombstones(
    in tombstones: [FavoriteSyncTombstone]
  ) -> [PortableFavorite.Key: FavoriteSyncTombstone] {
    var result: [PortableFavorite.Key: FavoriteSyncTombstone] = [:]
    for tombstone in tombstones
    where tombstone.deletedAt > result[tombstone.key]?.deletedAt ?? .distantPast {
      result[tombstone.key] = tombstone
    }
    return result
  }

  private static func prunedTombstones(
    _ tombstones: [FavoriteSyncTombstone]
  ) -> [FavoriteSyncTombstone] {
    Array(
      tombstones.sorted {
        if $0.deletedAt != $1.deletedAt { return $0.deletedAt > $1.deletedAt }
        return keyTieBreaker($0.key) < keyTieBreaker($1.key)
      }.prefix(tombstoneLimit))
  }

  private static func favoriteTieBreaker(_ favorite: PortableFavorite) -> String {
    "\(keyTieBreaker(favorite.key))\u{0}\(favorite.displayName)"
  }

  private static func keyTieBreaker(_ key: PortableFavorite.Key) -> String {
    "\(key.provider.rawValue)\u{0}\(key.connectionIdentifier ?? "")\u{0}\(key.path)"
  }

  private static func orderTieBreaker(_ document: FavoriteSyncDocument) -> String {
    document.items.map { keyTieBreaker($0.favorite.key) }.joined(separator: "\u{1}")
  }
}
