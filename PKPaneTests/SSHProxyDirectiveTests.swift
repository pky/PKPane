import Testing

@testable import PKPane

struct SSHProxyDirectiveTests {
  @Test("接続先や資格情報を変える-o指定を黙って捨てない")
  func dashOWithUserIsUnsupported() {
    let specifiedCommand = "ssh -o User=ops -W %h:%p gw"
    #expect(
      SSHProxyDirective.parseProxyCommand(specifiedCommand) == .unsupported(specifiedCommand))

    for option in [
      "User=ops", "uSeR=ops", "Port=2222", "IdentityFile=~/.ssh/key", "ProxyJump=bastion",
    ] {
      let command = "ssh -o \(option) gateway nc target.example 22"
      #expect(SSHProxyDirective.parseProxyCommand(command) == .unsupported(command))
    }
  }

  @Test("空白区切りのUser指定を黙って捨てない")
  func dashOWithSpaceSeparatedUserIsUnsupported() {
    let specifiedCommand = "ssh -o \"User admin\" -W files.example:22 gw"
    #expect(
      SSHProxyDirective.parseProxyCommand(specifiedCommand) == .unsupported(specifiedCommand))

    let harmlessCommand = "ssh -o \"StrictHostKeyChecking no\" gw nc files.example 22"
    #expect(
      SSHProxyDirective.parseProxyCommand(harmlessCommand)
        == .jump([
          SSHJumpSpec(alias: "gw", user: nil, port: nil, identityFile: nil)
        ]))
  }

  @Test("接続先を変えない-o指定は無視して踏み台を取り込める")
  func dashOOtherIsIgnored() {
    let command = "ssh -o StrictHostKeyChecking=no gw nc %h %p"
    #expect(
      SSHProxyDirective.parseProxyCommand(command)
        == .jump([
          SSHJumpSpec(alias: "gw", user: nil, port: nil, identityFile: nil)
        ]))
  }

  @Test
  func proxyJumpList() {
    let directive = SSHProxyDirective.parseProxyJump("ops@gateway:2222,relay2")

    #expect(
      directive
        == .jump([
          SSHJumpSpec(alias: "gateway", user: "ops", port: 2222, identityFile: nil),
          SSHJumpSpec(alias: "relay2", user: nil, port: nil, identityFile: nil),
        ])
    )
  }

  @Test
  func proxyJumpNone() {
    #expect(SSHProxyDirective.parseProxyJump("none") == .none)
  }

  @Test
  func proxyCommandNetcatForm() {
    let directive = SSHProxyDirective.parseProxyCommand(
      "ssh gateway nc files.example 22"
    )

    #expect(
      directive
        == .jump([
          SSHJumpSpec(alias: "gateway", user: nil, port: nil, identityFile: nil)
        ])
    )
  }

  @Test
  func proxyCommandWForms() {
    let optionsBeforeJump = SSHProxyDirective.parseProxyCommand(
      "ssh -p 2222 -l ops gateway -W files.example:22"
    )
    let destinationBeforeOptions = SSHProxyDirective.parseProxyCommand(
      "ssh -W files.example:22 -i ~/.ssh/k gateway"
    )

    #expect(
      optionsBeforeJump
        == .jump([
          SSHJumpSpec(alias: "gateway", user: "ops", port: 2222, identityFile: nil)
        ])
    )
    #expect(
      destinationBeforeOptions
        == .jump([
          SSHJumpSpec(
            alias: "gateway", user: nil, port: nil, identityFile: "~/.ssh/k")
        ])
    )
  }

  @Test
  func proxyCommandUnsupported() {
    let corkscrew = "corkscrew proxy 8080 %h %p"
    let socat = "ssh gateway socat - TCP:%h:%p"

    #expect(SSHProxyDirective.parseProxyCommand(corkscrew) == .unsupported(corkscrew))
    #expect(SSHProxyDirective.parseProxyCommand(socat) == .unsupported(socat))
  }
}
