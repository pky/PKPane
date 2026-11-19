import AppKit
import Foundation
import NetFS

enum SMBShareError: LocalizedError, Equatable {
  case invalidHost
  case invalidShareName

  var errorDescription: String? {
    switch self {
    case .invalidHost:
      "SMBサーバー名が正しくありません。"
    case .invalidShareName:
      "SMB共有名が正しくありません。"
    }
  }
}

struct SMBShare: Equatable {
  let host: String
  let shareName: String
  let url: URL

  init(host: String, shareName: String, allowsServerOnly: Bool = false) throws {
    let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedShareName = shareName.trimmingCharacters(in: .whitespacesAndNewlines)

    guard Self.isValidHost(normalizedHost) else {
      throw SMBShareError.invalidHost
    }
    guard
      (allowsServerOnly && normalizedShareName.isEmpty)
        || Self.isValidShareName(normalizedShareName)
    else {
      throw SMBShareError.invalidShareName
    }

    var components = URLComponents()
    components.scheme = "smb"
    components.host = normalizedHost
    components.path = normalizedShareName.isEmpty ? "" : "/\(normalizedShareName)"

    guard let url = components.url else {
      throw SMBShareError.invalidHost
    }

    self.host = normalizedHost
    self.shareName = normalizedShareName
    self.url = url
  }

  private static func isValidHost(_ host: String) -> Bool {
    !host.isEmpty && !host.contains(where: { "/@?#".contains($0) })
  }

  private static func isValidShareName(_ shareName: String) -> Bool {
    !shareName.isEmpty && !shareName.contains("/") && !shareName.contains("\\")
  }
}

struct SMBMountedVolume: Equatable {
  let volumeURL: URL
  let remountingURL: URL

  init(volumeURL: URL, remountingURL: URL) {
    self.volumeURL = volumeURL
    self.remountingURL = Self.sanitizedRemountingURL(remountingURL)
  }

  func matches(_ share: SMBShare) -> Bool {
    guard remountingURL.scheme?.lowercased() == "smb" else {
      return false
    }

    return remountingURL.host?.caseInsensitiveCompare(share.host) == .orderedSame
      && Self.normalizedPath(remountingURL) == Self.normalizedPath(share.url)
  }

  private static func sanitizedRemountingURL(_ url: URL) -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url
    }

    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    return components.url ?? url
  }

  private static func normalizedPath(_ url: URL) -> String {
    let path = url.path(percentEncoded: false)
    guard path.count > 1 else {
      return path
    }
    return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }
}

enum SMBMountEvent: Equatable {
  case mounted(SMBMountedVolume)
  case unmounted(SMBMountedVolume)
}

@MainActor
protocol VolumeRemountingURLResolving: AnyObject {
  func remountingURL(for volumeURL: URL) -> URL?
}

@MainActor
final class SMBMountObserver {
  typealias EventHandler = @MainActor (SMBMountEvent) -> Void

  private let notificationCenter: NotificationCenter
  private let resolver: any VolumeRemountingURLResolving
  private let onEvent: EventHandler
  private let mountedVolumeURLs: @MainActor () -> [URL]
  private var notificationTokens: [NSObjectProtocol] = []
  private var mountedVolumes: [URL: SMBMountedVolume] = [:]

  init(
    notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
    resolver: any VolumeRemountingURLResolving = SystemVolumeRemountingURLResolver(),
    mountedVolumeURLs: @escaping @MainActor () -> [URL] = {
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: [.volumeURLForRemountingKey],
        options: [.skipHiddenVolumes]
      ) ?? []
    },
    onEvent: @escaping EventHandler
  ) {
    self.notificationCenter = notificationCenter
    self.resolver = resolver
    self.mountedVolumeURLs = mountedVolumeURLs
    self.onEvent = onEvent
  }

  func start() {
    guard notificationTokens.isEmpty else {
      return
    }

    notificationTokens = [
      observe(NSWorkspace.didMountNotification) { [weak self] volumeURL in
        self?.handleMount(volumeURL)
      },
      observe(NSWorkspace.didUnmountNotification) { [weak self] volumeURL in
        self?.handleUnmount(volumeURL)
      },
    ]
    mountedVolumeURLs().forEach(handleMount)
  }

  func stop() {
    notificationTokens.forEach(notificationCenter.removeObserver)
    notificationTokens.removeAll()
    mountedVolumes.removeAll()
  }

  private func observe(
    _ name: Notification.Name,
    handler: @escaping @MainActor (URL) -> Void
  ) -> NSObjectProtocol {
    notificationCenter.addObserver(forName: name, object: nil, queue: .main) { notification in
      guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else {
        return
      }

      MainActor.assumeIsolated {
        handler(volumeURL)
      }
    }
  }

  private func handleMount(_ volumeURL: URL) {
    guard let remountingURL = resolver.remountingURL(for: volumeURL),
      remountingURL.scheme?.lowercased() == "smb"
    else {
      return
    }

    let volume = SMBMountedVolume(volumeURL: volumeURL, remountingURL: remountingURL)
    mountedVolumes[volumeURL] = volume
    onEvent(.mounted(volume))
  }

  private func handleUnmount(_ volumeURL: URL) {
    guard let volume = mountedVolumes.removeValue(forKey: volumeURL) else {
      return
    }

    onEvent(.unmounted(volume))
  }
}

@MainActor
protocol SMBMountConnecting: AnyObject {
  func connect(
    to share: SMBShare,
    completion: @escaping @MainActor (Result<[URL], SMBMountError>) -> Void
  )
  func disconnect(
    volumeURL: URL,
    completion: @escaping @MainActor (Result<Void, SMBMountError>) -> Void
  )
}

@MainActor
final class SystemSMBMountService: SMBMountConnecting {
  func connect(
    to share: SMBShare,
    completion: @escaping @MainActor (Result<[URL], SMBMountError>) -> Void
  ) {
    // 共有を指定しないサーバーURLでは、NetFSがmacOS標準の共有選択画面を表示する。
    var requestID: AsyncRequestID?
    let status = NetFSMountURLAsync(
      share.url as CFURL,
      nil,
      nil,
      nil,
      nil,
      nil,
      &requestID,
      DispatchQueue.main
    ) { status, _, mountpoints in
      Task { @MainActor in
        guard status == 0 else {
          completion(.failure(.connectionFailed(status)))
          return
        }
        let urls = (mountpoints as? [String] ?? []).map(URL.init(fileURLWithPath:))
        completion(.success(urls))
      }
    }
    if status != 0 {
      completion(.failure(.connectionFailed(status)))
    }
  }

  func disconnect(
    volumeURL: URL,
    completion: @escaping @MainActor (Result<Void, SMBMountError>) -> Void
  ) {
    DispatchQueue.global(qos: .utility).async {
      let result: Result<Void, SMBMountError>
      do {
        try NSWorkspace.shared.unmountAndEjectDevice(at: volumeURL)
        result = .success(())
      } catch {
        result = .failure(.disconnectionFailed)
      }

      Task { @MainActor in
        completion(result)
      }
    }
  }
}

enum SMBMountError: LocalizedError, Equatable, Sendable {
  case connectionFailed(Int32)
  case disconnectionFailed

  var errorDescription: String? {
    switch self {
    case .connectionFailed:
      "macOS標準のSMB接続を開始できませんでした。"
    case .disconnectionFailed:
      "NAS共有を解除できませんでした。"
    }
  }
}

@MainActor
private final class SystemVolumeRemountingURLResolver: VolumeRemountingURLResolving {
  func remountingURL(for volumeURL: URL) -> URL? {
    try? volumeURL.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting
  }
}
