struct LRUDictionary<Key: Hashable, Value> {
  private struct Entry {
    var value: Value
    var accessSequence: UInt64
  }

  private let capacity: Int
  private var entries: [Key: Entry] = [:]
  private var nextAccessSequence: UInt64 = 0

  init(capacity: Int) {
    precondition(capacity > 0, "LRUキャッシュの上限は1以上である必要があります。")
    self.capacity = capacity
  }

  subscript(key: Key) -> Value? {
    mutating get {
      value(forKey: key, touching: true)
    }
    set {
      if let newValue {
        setValue(newValue, forKey: key)
      } else {
        removeValue(forKey: key)
      }
    }
  }

  var count: Int {
    entries.count
  }

  var keys: [Key] {
    Array(entries.keys)
  }

  mutating func value(forKey key: Key, touching: Bool) -> Value? {
    guard var entry = entries[key] else { return nil }
    if touching {
      entry.accessSequence = takeNextAccessSequence()
      entries[key] = entry
    }
    return entry.value
  }

  mutating func setValue(
    _ value: Value,
    forKey key: Key,
    isPinned: (Key) -> Bool = { _ in false }
  ) {
    entries[key] = Entry(value: value, accessSequence: takeNextAccessSequence())
    evictIfNeeded(isPinned: isPinned)
  }

  @discardableResult
  mutating func removeValue(forKey key: Key) -> Value? {
    entries.removeValue(forKey: key)?.value
  }

  mutating func removeAll() {
    entries.removeAll()
    nextAccessSequence = 0
  }

  private mutating func takeNextAccessSequence() -> UInt64 {
    defer { nextAccessSequence &+= 1 }
    return nextAccessSequence
  }

  private mutating func evictIfNeeded(isPinned: (Key) -> Bool) {
    while entries.count > capacity {
      guard
        let oldestKey =
          entries
          .filter({ !isPinned($0.key) })
          .min(by: { $0.value.accessSequence < $1.value.accessSequence })?
          .key
      else {
        return
      }
      entries.removeValue(forKey: oldestKey)
    }
  }
}
