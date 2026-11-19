import AppKit
import SwiftUI

/// メニューの宛先は、そのウインドウがキーウインドウになったときだけ切り替える。
struct WindowMenuActivationObserver: NSViewRepresentable {
  let activated: () -> Void

  func makeNSView(context: Context) -> WindowMenuActivationView {
    WindowMenuActivationView(activated: activated)
  }

  func updateNSView(_ view: WindowMenuActivationView, context: Context) {
    view.activated = activated
  }
}

@MainActor
final class WindowMenuActivationView: NSView {
  var activated: () -> Void
  private var observer: (any NSObjectProtocol)?

  init(activated: @escaping () -> Void) {
    self.activated = activated
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    guard let window else { return }
    observer = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.activated() }
    }
    Task { @MainActor [weak self, weak window] in
      if window?.isKeyWindow == true { self?.activated() }
    }
  }

  isolated deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }
}
