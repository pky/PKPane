import Foundation
import OSLog

enum AppLog {
  private static let subsystem = "com.pky.PKPane"

  static func error(_ message: String, category: String) {
    let masked = sanitizedMessage(message)
    Logger(subsystem: subsystem, category: category).error("\(masked, privacy: .public)")
  }

  static func warning(_ message: String, category: String) {
    let masked = sanitizedMessage(message)
    Logger(subsystem: subsystem, category: category).warning("\(masked, privacy: .public)")
  }

  static func notice(_ message: String, category: String) {
    let masked = sanitizedMessage(message)
    Logger(subsystem: subsystem, category: category).notice("\(masked, privacy: .public)")
  }

  static func info(_ message: String, category: String) {
    let masked = sanitizedMessage(message)
    Logger(subsystem: subsystem, category: category).info("\(masked, privacy: .public)")
  }

  static func debug(_ message: String, category: String) {
    let masked = sanitizedMessage(message)
    Logger(subsystem: subsystem, category: category).debug("\(masked, privacy: .public)")
  }

  static func sanitizedMessage(_ message: String) -> String {
    SecretMasker.maskForLog(message)
  }
}
