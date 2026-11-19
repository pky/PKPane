import Testing

@testable import PKPane

struct SSHConfigImportResolverTests {
  @Test("具体別名の無い踏み台にもワイルドカード設定と全体既定を適用する")
  func wildcardOnlyJumpAliasStillAppliesConfig() throws {
    let document = SSHConfigParser.parse(
      """
      Host target
        ProxyJump gw.example.com
      Host *.example.com
        User ops
        IdentityFile ~/.ssh/gateway-key
      Host *
        Port 2222
      """, includeResolver: { _ in [] }, baseDirectory: "/Users/tester/.ssh")
    let result = SSHConfigImportResolver.resolve(
      alias: "target", in: document, localUsername: "local")
    let hop = try #require(result.jumpHops.first)
    #expect(hop.hostName == "gw.example.com")
    #expect(hop.username == "ops")
    #expect(hop.port == 2222)
    #expect(hop.identityFiles == ["/Users/tester/.ssh/gateway-key"])
    #expect(!result.warnings.contains(.undefinedJumpAlias(alias: "gw.example.com")))
  }

  @Test("兄弟の踏み台が同じbastionを参照してもループ警告を出さない")
  func sharedBastionAcrossSiblingsIsNotLoop() {
    let document = SSHConfigParser.parse(
      "Host target\nProxyJump a,b\nHost a\nProxyJump bastion\nHost b\nProxyJump bastion\nHost bastion",
      includeResolver: { _ in [] }, baseDirectory: "/Users/tester/.ssh")
    let result = SSHConfigImportResolver.resolve(
      alias: "target", in: document, localUsername: "local")
    #expect(!result.warnings.contains(.jumpChainLoop(alias: "bastion")))
    #expect(result.jumpHops.map(\.alias) == ["bastion", "a", "b"])
  }

  @Test("カンマ列の2番目以降の踏み台は自身のProxy指示を辿らない")
  func secondJumpInListDoesNotFollowOwnProxyJump() {
    for directive in ["ProxyJump unexpected", "ProxyCommand ssh unexpected nc %h %p"] {
      let document = SSHConfigParser.parse(
        "Host target\nProxyJump a,b\nHost a\nUser first\nHost b\nUser second\n\(directive)\nHost unexpected",
        includeResolver: { _ in [] }, baseDirectory: "/Users/tester/.ssh")
      let result = SSHConfigImportResolver.resolve(
        alias: "target", in: document, localUsername: "local")
      #expect(result.jumpHops.map(\.alias) == ["a", "b"])
      #expect(result.jumpHops.map(\.username) == ["first", "second"])
      #expect(result.warnings.isEmpty)
    }
  }

  @Test
  func resolvesUserEnvironmentExample() {
    let document = SSHConfigParser.parse(
      """
      Host files
        HostName files.example
        User tester
        ProxyCommand ssh storage-gateway nc %h %p
      Host storage-gateway
        HostName 192.0.2.10
        User ops
        IdentityFile ~/.ssh/id_ed25519
      """,
      includeResolver: { _ in [] },
      baseDirectory: "/Users/tester/.ssh"
    )

    let result = SSHConfigImportResolver.resolve(
      alias: "files",
      in: document,
      localUsername: "local-user"
    )

    #expect(
      result.final
        == SSHConfigResolvedHop(
          alias: "files",
          hostName: "files.example",
          port: 22,
          username: "tester",
          identityFiles: []
        )
    )
    #expect(
      result.jumpHops == [
        SSHConfigResolvedHop(
          alias: "storage-gateway",
          hostName: "192.0.2.10",
          port: 22,
          username: "ops",
          identityFiles: ["/Users/tester/.ssh/id_ed25519"]
        )
      ]
    )
    #expect(result.warnings.isEmpty)
  }

  @Test
  func proxyJumpChainOrder() {
    let document = SSHConfigParser.parse(
      """
      Host target
        HostName target.local
        ProxyJump a,b
      Host a
        HostName 192.0.2.1
        User first
        Port 2201
      Host b
        HostName 192.0.2.2
        User second
        Port 2202
      """,
      includeResolver: { _ in [] },
      baseDirectory: "/Users/tester/.ssh"
    )

    let result = SSHConfigImportResolver.resolve(
      alias: "target",
      in: document,
      localUsername: "local-user"
    )

    #expect(
      result.jumpHops == [
        SSHConfigResolvedHop(
          alias: "a",
          hostName: "192.0.2.1",
          port: 2201,
          username: "first",
          identityFiles: []
        ),
        SSHConfigResolvedHop(
          alias: "b",
          hostName: "192.0.2.2",
          port: 2202,
          username: "second",
          identityFiles: []
        ),
      ]
    )
  }

  @Test
  func nestedJumpResolvesRecursively() {
    let document = SSHConfigParser.parse(
      """
      Host target
        ProxyJump b
      Host b
        HostName b.local
        ProxyJump a
      Host a
        HostName a.local
      """,
      includeResolver: { _ in [] },
      baseDirectory: "/Users/tester/.ssh"
    )

    let result = SSHConfigImportResolver.resolve(
      alias: "target",
      in: document,
      localUsername: "local-user"
    )

    #expect(result.jumpHops.map(\.alias) == ["a", "b"])
    #expect(result.jumpHops.map(\.hostName) == ["a.local", "b.local"])
  }

  @Test
  func loopIsDetected() {
    let document = SSHConfigParser.parse(
      """
      Host a
        HostName a.local
        ProxyJump a
      """,
      includeResolver: { _ in [] },
      baseDirectory: "/Users/tester/.ssh"
    )

    let result = SSHConfigImportResolver.resolve(
      alias: "a",
      in: document,
      localUsername: "local-user"
    )

    #expect(result.final.alias == "a")
    #expect(result.jumpHops.isEmpty)
    #expect(result.warnings.contains(.jumpChainLoop(alias: "a")))
  }

  @Test
  func missingUserUsesLocalUsername() {
    let document = SSHConfigParser.parse(
      """
      Host target
        HostName target.local
      """,
      includeResolver: { _ in [] },
      baseDirectory: "/Users/tester/.ssh"
    )

    let result = SSHConfigImportResolver.resolve(
      alias: "target",
      in: document,
      localUsername: "local-user"
    )

    #expect(result.final.username == "local-user")
  }

  @Test
  func undefinedJumpAliasFallsBack() {
    let document = SSHConfigParser.parse(
      """
      Host target
        HostName target.local
        ProxyCommand ssh gateway nc %h %p
      """,
      includeResolver: { _ in [] },
      baseDirectory: "/Users/tester/.ssh"
    )

    let result = SSHConfigImportResolver.resolve(
      alias: "target",
      in: document,
      localUsername: "local-user"
    )

    #expect(
      result.jumpHops == [
        SSHConfigResolvedHop(
          alias: "gateway",
          hostName: "gateway",
          port: 22,
          username: "local-user",
          identityFiles: []
        )
      ]
    )
    #expect(result.warnings.contains(.undefinedJumpAlias(alias: "gateway")))
  }

  @Test
  func unsupportedProxyCommandYieldsWarningAndNoHops() {
    let document = SSHConfigParser.parse(
      """
      Host target
        HostName target.local
        ProxyCommand corkscrew proxy 8080 %h %p
      """,
      includeResolver: { _ in [] },
      baseDirectory: "/Users/tester/.ssh"
    )

    let result = SSHConfigImportResolver.resolve(
      alias: "target",
      in: document,
      localUsername: "local-user"
    )

    #expect(result.jumpHops.isEmpty)
    #expect(
      result.warnings.contains(
        .unsupportedProxyCommand(
          alias: "target",
          command: "corkscrew proxy 8080 target.local 22"
        )
      )
    )
  }
}
