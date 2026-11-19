import Testing

@testable import PKPane

struct QuickOpenIndexTests {
  @Test("前方一致、単語頭一致、部分一致の順に並べる")
  func ranksMatchesByPosition() {
    let candidates = QuickOpenIndex.makeCandidates(
      favorites: [QuickOpenSourceItem(id: "part", title: "MyProjectArchive")],
      recents: [QuickOpenSourceItem(id: "word", title: "Open Project")],
      connections: [],
      commands: [QuickOpenSourceItem(id: "prefix", title: "Project Settings")])

    let results = QuickOpenIndex.search(candidates, query: "project")

    #expect(
      results.map(\.action) == [
        .performCommand("prefix"), .openRecent("word"), .openFavorite("part"),
      ])
  }

  @Test("検索は大文字小文字と全角半角を区別しない")
  func searchIgnoresCaseAndWidth() {
    let candidates = QuickOpenIndex.makeCandidates(
      favorites: [QuickOpenSourceItem(id: "docs", title: "ＤＯＣＵＭＥＮＴＳ")],
      recents: [], connections: [], commands: [])

    #expect(
      QuickOpenIndex.search(candidates, query: "documents").map(\.title) == [
        "ＤＯＣＵＭＥＮＴＳ"
      ])
  }

  @Test("日本語の前方一致と部分一致を検索できる")
  func searchesJapaneseTitles() {
    let candidates = QuickOpenIndex.makeCandidates(
      favorites: [QuickOpenSourceItem(id: "docs", title: "書類フォルダ")],
      recents: [QuickOpenSourceItem(id: "meeting", title: "昨日の会議資料")],
      connections: [], commands: [])

    #expect(QuickOpenIndex.search(candidates, query: "書類").map(\.title) == ["書類フォルダ"])
    #expect(QuickOpenIndex.search(candidates, query: "会議").map(\.title) == ["昨日の会議資料"])
  }

  @Test("空入力ではお気に入りと最近の場所だけを先頭から表示する")
  func emptyQueryUsesDefaultLocationCandidates() {
    let candidates = QuickOpenIndex.makeCandidates(
      favorites: [
        QuickOpenSourceItem(id: "a", title: "お気に入りA"),
        QuickOpenSourceItem(id: "b", title: "お気に入りB"),
      ],
      recents: [QuickOpenSourceItem(id: "c", title: "最近C")],
      connections: [QuickOpenSourceItem(id: "d", title: "接続D")],
      commands: [QuickOpenSourceItem(id: "e", title: "コマンドE")])

    let results = QuickOpenIndex.search(candidates, query: "", defaultLimit: 2)

    #expect(results.map(\.title) == ["お気に入りA", "お気に入りB"])
  }

  @Test("一致候補がなければ空配列を返す")
  func returnsNoCandidatesForMissingQuery() {
    let candidates = QuickOpenIndex.makeCandidates(
      favorites: [QuickOpenSourceItem(id: "docs", title: "書類")],
      recents: [], connections: [], commands: [])

    #expect(QuickOpenIndex.search(candidates, query: "画像").isEmpty)
  }

  @Test("4種の候補を統合し種別と実行先を保持する")
  func combinesAllCandidateSources() {
    let candidates = QuickOpenIndex.makeCandidates(
      favorites: [QuickOpenSourceItem(id: "favorite", title: "お気に入り")],
      recents: [QuickOpenSourceItem(id: "recent", title: "最近")],
      connections: [QuickOpenSourceItem(id: "connection", title: "接続")],
      commands: [QuickOpenSourceItem(id: "command", title: "コマンド")])

    #expect(candidates.map(\.kind) == [.favorite, .recent, .connection, .command])
    #expect(
      candidates.map(\.action) == [
        .openFavorite("favorite"),
        .openRecent("recent"),
        .connect("connection"),
        .performCommand("command"),
      ])
  }

  @Test("候補構築だけでは場所、接続、コマンドを実行しない")
  func buildingCandidatesHasNoSideEffects() {
    var executionCount = 0
    let dispatcher = QuickOpenDispatcher(
      openFavorite: { _ in executionCount += 1 },
      openRecent: { _ in executionCount += 1 },
      connect: { _ in executionCount += 1 },
      performCommand: { _ in executionCount += 1 })

    let candidates = QuickOpenIndex.makeCandidates(
      favorites: [QuickOpenSourceItem(id: "favorite", title: "お気に入り")],
      recents: [QuickOpenSourceItem(id: "recent", title: "最近")],
      connections: [QuickOpenSourceItem(id: "connection", title: "接続")],
      commands: [QuickOpenSourceItem(id: "command", title: "コマンド")])

    #expect(executionCount == 0)
    dispatcher.execute(candidates[0].action)
    #expect(executionCount == 1)
  }

  @Test("種別ごとの実行先へディスパッチする")
  func dispatchesEveryActionKind() {
    var events: [String] = []
    let dispatcher = QuickOpenDispatcher(
      openFavorite: { events.append("favorite:\($0)") },
      openRecent: { events.append("recent:\($0)") },
      connect: { events.append("connection:\($0)") },
      performCommand: { events.append("command:\($0)") })

    dispatcher.execute(.openFavorite("1"))
    dispatcher.execute(.openRecent("2"))
    dispatcher.execute(.connect("3"))
    dispatcher.execute(.performCommand("4"))

    #expect(events == ["favorite:1", "recent:2", "connection:3", "command:4"])
  }
}
