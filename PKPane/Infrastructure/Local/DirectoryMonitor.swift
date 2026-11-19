import Darwin
import Dispatch
import Foundation

@MainActor
final class DirectoryMonitor {
  private let url: URL
  private let onChange: () -> Void
  private var source: DispatchSourceFileSystemObject?

  init(url: URL, onChange: @escaping () -> Void) {
    self.url = url
    self.onChange = onChange
  }

  func start() throws {
    guard source == nil else { return }

    let fileDescriptor = open(url.path, O_EVTONLY)
    guard fileDescriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: [.write, .delete, .rename],
      queue: .main)
    source.setEventHandler { [weak self] in
      self?.onChange()
    }
    source.setCancelHandler {
      close(fileDescriptor)
    }
    self.source = source
    source.resume()
  }

  func stop() {
    source?.cancel()
    source = nil
  }
}
