import Testing

@testable import PKPane

struct LRUDictionaryTests {
  @Test("上限を超えると最も古い値を追い出す")
  func evictsLeastRecentlyUsedValue() {
    var cache = LRUDictionary<String, Int>(capacity: 2)

    cache["first"] = 1
    cache["second"] = 2
    cache["third"] = 3

    #expect(cache.value(forKey: "first", touching: false) == nil)
    #expect(cache.value(forKey: "second", touching: false) == 2)
    #expect(cache.value(forKey: "third", touching: false) == 3)
  }

  @Test("読み取りで触れた値は追い出し順が新しくなる")
  func touchUpdatesEvictionOrder() {
    var cache = LRUDictionary<String, Int>(capacity: 2)
    cache["first"] = 1
    cache["second"] = 2

    #expect(cache["first"] == 1)
    cache["third"] = 3

    #expect(cache.value(forKey: "first", touching: false) == 1)
    #expect(cache.value(forKey: "second", touching: false) == nil)
  }

  @Test("ピン留めされた最古の値を飛ばして追い出す")
  func skipsPinnedValueDuringEviction() {
    var cache = LRUDictionary<String, Int>(capacity: 2)
    cache["pinned"] = 1
    cache["second"] = 2

    cache.setValue(3, forKey: "third", isPinned: { $0 == "pinned" })

    #expect(cache.value(forKey: "pinned", touching: false) == 1)
    #expect(cache.value(forKey: "second", touching: false) == nil)
    #expect(cache.value(forKey: "third", touching: false) == 3)
  }

  @Test("全件がピン留めされている場合は上限超過を許容する")
  func allowsOverflowWhenEveryValueIsPinned() {
    var cache = LRUDictionary<String, Int>(capacity: 1)
    cache["first"] = 1

    cache.setValue(2, forKey: "second", isPinned: { _ in true })

    #expect(cache.count == 2)
    #expect(Set(cache.keys) == ["first", "second"])
  }

  @Test("個別削除と全削除で値を解放する")
  func removesValues() {
    var cache = LRUDictionary<String, Int>(capacity: 2)
    cache["first"] = 1
    cache["second"] = 2

    #expect(cache.removeValue(forKey: "first") == 1)
    #expect(cache.count == 1)

    cache.removeAll()

    #expect(cache.count == 0)
    #expect(cache.keys.isEmpty)
  }
}
