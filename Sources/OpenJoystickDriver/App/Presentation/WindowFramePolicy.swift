#if canImport(AppKit)

  import AppKit

  enum WindowFramePolicy {
    static func clampedFrame(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
      let width = min(frame.width, visibleFrame.width)
      let height = min(frame.height, visibleFrame.height)
      let x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width)
      let y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height)
      return NSRect(x: x, y: y, width: width, height: height)
    }

    @MainActor
    static func clamp(_ window: NSWindow) {
      guard let screen = window.screen ?? NSScreen.main else { return }
      window.setFrame(clampedFrame(window.frame, to: screen.visibleFrame), display: false)
    }
  }

#endif
