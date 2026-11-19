import Testing

@testable import PKPane

struct PosixPermissionsTests {
  @Test("8進数と9ビットの権限値を相互変換する")
  func convertsOctalAndMode() {
    #expect(PosixPermissions.mode(fromOctalString: "640") == 0o640)
    #expect(PosixPermissions.octalString(for: 0o100755) == "755")
  }

  @Test("権限値をシンボリック表記へ変換する")
  func convertsModeToSymbolicString() {
    #expect(PosixPermissions.symbolicString(for: 0o755) == "rwxr-xr-x")
    #expect(PosixPermissions.symbolicString(for: 0o640) == "rw-r-----")
  }

  @Test("チェック変更は対象ビットだけを変更する")
  func settingPermissionChangesOnlyTargetBit() {
    #expect(PosixPermissions.setting(0o020, enabled: true, in: 0o640) == 0o660)
    #expect(PosixPermissions.setting(0o400, enabled: false, in: 0o640) == 0o240)
  }

  @Test("8進数入力は0から7の3桁だけを確定値として受け付ける")
  func validatesOctalInput() {
    #expect(PosixPermissions.mode(fromOctalString: "755") == 0o755)
    #expect(PosixPermissions.mode(fromOctalString: "75") == nil)
    #expect(PosixPermissions.mode(fromOctalString: "7555") == nil)
    #expect(PosixPermissions.mode(fromOctalString: "789") == nil)
    #expect(PosixPermissions.isValidPartialOctalInput("07"))
    #expect(!PosixPermissions.isValidPartialOctalInput("078"))
    #expect(!PosixPermissions.isValidPartialOctalInput("0755"))
  }
}
