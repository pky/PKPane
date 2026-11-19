import Testing

@testable import PKPane

struct SSHConfigParserTests {
  @Test("同じIncludeファイルは別のHostからそれぞれ適用し自己循環だけを止める")
  func includeSameFileFromDifferentHostsIsAppliedToBoth() {
    let base = "/Users/me/.ssh"
    let commonPath = base + "/common.conf"
    var readCount = 0
    let document = SSHConfigParser.parse(
      "Host a\nInclude common.conf\nHost b\nInclude common.conf",
      includeResolver: { path in
        readCount += 1
        return [
          (
            path: path,
            text: "User deploy\nIdentityFile ~/.ssh/deploy"
          )
        ]
      }, baseDirectory: base)

    for alias in ["a", "b"] {
      let resolved = SSHConfigParser.resolve(alias: alias, in: document)
      #expect(values(in: resolved, for: "user") == ["deploy"])
      #expect(values(in: resolved, for: "identityfile") == [base + "/deploy"])
    }
    #expect(readCount == 2)
    #expect(!document.warnings.contains(.includeUnreadable(path: commonPath)))

    var cyclicReadCount = 0
    let cyclic = SSHConfigParser.parse(
      "Host cycle\nInclude common.conf",
      includeResolver: { path in
        cyclicReadCount += 1
        return [(path: path, text: "User deploy\nInclude common.conf")]
      }, baseDirectory: base)

    #expect(
      values(in: SSHConfigParser.resolve(alias: "cycle", in: cyclic), for: "user") == ["deploy"])
    #expect(cyclicReadCount == 1)
    #expect(cyclic.warnings.contains(.includeUnreadable(path: commonPath)))
  }

  @Test("警告表示では実ホームの絶対パスをチルダへ置き換える")
  func warningDisplayTextMasksHomeDirectory() {
    let homePath = UserHomeDirectory.current.path
    let warnings = [
      SSHConfigWarning.includeUnreadable(path: homePath + "/.ssh/conf.d/x"),
      SSHConfigWarning.identityFileOutsideAccessibleFolder(path: homePath + "/keys/id"),
    ]

    for warning in warnings {
      #expect(!warning.displayText.contains(homePath))
      #expect(warning.displayText.contains("~/"))
    }
  }

  @Test("Include後は親のHostとMatch状態へ戻る")
  func includeRestoresHostAndMatchState() {
    let document = SSHConfigParser.parse(
      "Host parent\nInclude child.conf\nUser parent-user\nPort 2200\nHost sibling\nUser sibling-user",
      includeResolver: { _ in
        [
          (
            path: "/Users/me/.ssh/child.conf",
            text: "Host child\nUser child-user\nMatch all\nPort 9999"
          )
        ]
      }, baseDirectory: "/Users/me/.ssh")

    let parent = SSHConfigParser.resolve(alias: "parent", in: document)
    let child = SSHConfigParser.resolve(alias: "child", in: document)
    #expect(values(in: parent, for: "user") == ["parent-user"])
    #expect(values(in: parent, for: "port") == ["2200"])
    #expect(values(in: child, for: "user") == ["child-user"])
    #expect(values(in: child, for: "port").isEmpty)
    #expect(
      values(in: SSHConfigParser.resolve(alias: "sibling", in: document), for: "user") == [
        "sibling-user"
      ])
  }

  @Test("Include展開総数を64件に制限する")
  func includeCapsTotalFiles() {
    let base = "/Users/me/.ssh"
    let capped = SSHConfigParser.parse(
      "Include conf.d/*",
      includeResolver: { _ in
        (0..<65).map { (path: base + "/conf.d/\($0)", text: "Host host\($0)") }
      }, baseDirectory: base)
    #expect(capped.concreteAliases.count == 64)
    #expect(!capped.concreteAliases.contains("host64"))
    #expect(capped.warnings.contains(.includeUnreadable(path: base + "/conf.d/64")))
  }

  @Test
  func firstValueWinsExceptIdentityFileAccumulates() {
    let document = SSHConfigParser.parse(
      """
      Host files
        User tester
        IdentityFile ~/.ssh/a
      Host *
        User fallback
        IdentityFile ~/.ssh/b
        Port 2222
      """,
      includeResolver: { _ in [] },
      baseDirectory: "/Users/me/.ssh"
    )

    let resolved = SSHConfigParser.resolve(alias: "files", in: document)

    #expect(values(in: resolved, for: "user") == ["tester"])
    #expect(lines(in: resolved, for: "user") == [2])
    #expect(values(in: resolved, for: "port") == ["2222"])
    #expect(lines(in: resolved, for: "port") == [7])
    #expect(
      values(in: resolved, for: "identityfile")
        == ["/Users/me/.ssh/a", "/Users/me/.ssh/b"]
    )
    #expect(lines(in: resolved, for: "identityfile") == [3, 6])
  }

  @Test
  func wildcardAndNegationPatterns() {
    #expect(SSHConfigParser.matches(pattern: "*.example", host: "files.example"))
    #expect(SSHConfigParser.matches(pattern: "fil?s", host: "files"))

    let document = SSHConfigParser.parse(
      """
      Host *.example !files.example
        User blocked
      Host *.example
        Port 2200
      """,
      includeResolver: { _ in [] },
      baseDirectory: "/Users/me/.ssh"
    )

    let excluded = SSHConfigParser.resolve(alias: "files.example", in: document)
    let included = SSHConfigParser.resolve(alias: "radio.example", in: document)

    #expect(values(in: excluded, for: "user").isEmpty)
    #expect(values(in: excluded, for: "port") == ["2200"])
    #expect(values(in: included, for: "user") == ["blocked"])
  }

  @Test
  func equalsSeparatorQuotesAndComments() {
    let document = SSHConfigParser.parse(
      """
      Host sample
        UsEr = "my user" # comment
      """,
      includeResolver: { _ in [] },
      baseDirectory: "/Users/me/.ssh"
    )

    let resolved = SSHConfigParser.resolve(alias: "sample", in: document)

    #expect(values(in: resolved, for: "user") == ["my user"])
    #expect(lines(in: resolved, for: "user") == [2])
  }

  @Test
  func includeExpandsInPlaceAndWarnsOutsideFolder() {
    var requestedPatterns: [String] = []
    let document = SSHConfigParser.parse(
      """
      Host seed
        User seed
      Include conf.d/*
      Host target
        User main-after
        IdentityFile ~/.ssh/main
      Include /etc/ssh/x
      """,
      includeResolver: { pattern in
        requestedPatterns.append(pattern)
        switch pattern {
        case "/Users/me/.ssh/conf.d/*":
          return [
            (
              path: "/Users/me/.ssh/conf.d/10-first",
              text: """
              Host target
                User include-first
                IdentityFile ~/.ssh/include-first
              """
            ),
            (
              path: "/Users/me/.ssh/conf.d/20-second",
              text: """
              Host target
                User include-second
                IdentityFile ~/.ssh/include-second
              """
            ),
          ]
        case "/etc/ssh/x":
          return nil
        default:
          return []
        }
      },
      baseDirectory: "/Users/me/.ssh"
    )

    let resolved = SSHConfigParser.resolve(alias: "target", in: document)

    #expect(requestedPatterns == ["/Users/me/.ssh/conf.d/*", "/etc/ssh/x"])
    #expect(values(in: resolved, for: "user") == ["include-first"])
    #expect(
      values(in: resolved, for: "identityfile")
        == [
          "/Users/me/.ssh/include-first",
          "/Users/me/.ssh/include-second",
          "/Users/me/.ssh/main",
        ]
    )
    #expect(
      document.warnings.contains(
        .includeOutsideAccessibleFolder(path: "/etc/ssh/x")
      )
    )
  }

  @Test
  func matchBlocksAreIgnoredWithWarning() {
    let document = SSHConfigParser.parse(
      """
      Host before
        User kept
      Match host *.example
        User ignored
        Port 2200
      Host after
        User restored
      """,
      includeResolver: { _ in [] },
      baseDirectory: "/Users/me/.ssh"
    )

    let before = SSHConfigParser.resolve(alias: "before", in: document)
    let after = SSHConfigParser.resolve(alias: "after", in: document)

    #expect(values(in: before, for: "user") == ["kept"])
    #expect(values(in: before, for: "port").isEmpty)
    #expect(values(in: after, for: "user") == ["restored"])
    #expect(document.warnings == [.matchBlockIgnored(line: 3)])
  }

  @Test
  func tokenExpansion() {
    let document = SSHConfigParser.parse(
      """
      Host files
        HostName files.example
        Port 2200
        User tester
        ProxyCommand ssh gateway nc %h %p
        IdentityFile ~/keys/%%-%r@%h-%p
      """,
      includeResolver: { _ in [] },
      baseDirectory: "/Users/me/.ssh"
    )

    let resolved = SSHConfigParser.resolve(alias: "files", in: document)

    #expect(
      values(in: resolved, for: "proxycommand")
        == ["ssh gateway nc files.example 2200"]
    )
    #expect(
      values(in: resolved, for: "identityfile")
        == ["/Users/me/keys/%-tester@files.example-2200"]
    )
  }

  @Test
  func concreteAliasesExcludeWildcards() {
    let document = SSHConfigParser.parse(
      """
      Host a b *.x !c
      Host b d host?
      """,
      includeResolver: { _ in [] },
      baseDirectory: "/Users/me/.ssh"
    )

    #expect(document.concreteAliases == ["a", "b", "d"])
  }

  private func values(
    in resolved: [String: [(value: String, line: Int)]],
    for keyword: String
  ) -> [String] {
    resolved[keyword, default: []].map { $0.value }
  }

  private func lines(
    in resolved: [String: [(value: String, line: Int)]],
    for keyword: String
  ) -> [Int] {
    resolved[keyword, default: []].map { $0.line }
  }
}
