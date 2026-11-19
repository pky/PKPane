import Darwin

struct SystemFullDiskAccessChecker: FullDiskAccessChecking {
  private static let protectedDatabasePath =
    "/Library/Application Support/com.apple.TCC/TCC.db"

  var status: FullDiskAccessStatus {
    let descriptor = Self.protectedDatabasePath.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC)
    }
    if descriptor >= 0 {
      Darwin.close(descriptor)
      return .granted
    }

    switch errno {
    case EPERM, EACCES:
      return .denied
    default:
      return .unknown
    }
  }
}
