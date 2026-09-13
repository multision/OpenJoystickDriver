import AppKit
import OpenJoystickDriverKit

enum CompatibilityConsumerRouting {
  private static let browserEngineDetector = BrowserEngineDetector()
  private static let bundledSDLDetector = BundledSDLDetector()

  static func changes() -> AsyncStream<CompatibilityConsumerFamily> {
    AsyncStream { continuation in
      final class TokenBox: @unchecked Sendable { var token: NSObjectProtocol? }
      let box = TokenBox()
      box.token = observe { continuation.yield($0) }
      continuation.onTermination = { _ in
        if let token = box.token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
      }
    }
  }

  static func observe(
    notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
    activatedBundleURL: @escaping @Sendable (Notification) -> URL? = { notification in
      (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
        .bundleURL
    },
    consumerResolver: @escaping @Sendable (URL?) -> CompatibilityConsumerFamily = consumer,
    _ change: @escaping @Sendable (CompatibilityConsumerFamily) -> Void
  ) -> NSObjectProtocol {
    notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { notification in change(consumerResolver(activatedBundleURL(notification))) }
  }

  static func current() -> CompatibilityConsumerFamily {
    consumer(bundleURL: NSWorkspace.shared.frontmostApplication?.bundleURL)
  }

  static func consumer(bundleURL: URL?) -> CompatibilityConsumerFamily {
    guard let bundleURL else { return .unknown }
    switch browserEngineDetector.detect(bundleURL: bundleURL) {
    case .blink: return .blinkGamepad
    case .gecko: return .geckoGamepad
    case .webkit: return .webkitGamepad
    case .unknown: return .unknownBrowserGamepad
    case nil: return bundledSDLDetector.detect(bundleURL: bundleURL) ? .sdlHIDAPI : .unknown
    }
  }
}
