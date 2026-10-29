import Cocoa
import FlutterMacOS

private enum MainWindowDefaults {
  static let contentSize = NSSize(width: 1280, height: 832)
  static let simWindowSlotEnv = "FROSTSNAP_SIM_WINDOW_SLOT"
  static let simWindowMargin: CGFloat = 24
  static let simWindowXStep: CGFloat = 56
  static let simWindowYStep: CGFloat = 44

  static var simWindowSlot: Int? {
    guard let raw = ProcessInfo.processInfo.environment[simWindowSlotEnv],
          let slot = Int(raw),
          slot >= 0 else {
      return nil
    }
    return slot
  }

  static func simWindowOrigin(slot: Int, windowSize: NSSize, screen: NSScreen?) -> NSPoint? {
    guard let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame else {
      return nil
    }

    let availableWidth = visibleFrame.width - windowSize.width - (simWindowMargin * 2)
    let availableHeight = visibleFrame.height - windowSize.height - (simWindowMargin * 2)
    let columns = max(1, Int(floor(availableWidth / simWindowXStep)) + 1)
    let rows = max(1, Int(floor(availableHeight / simWindowYStep)) + 1)
    let wrappedSlot = slot % max(1, columns * rows)
    let column = wrappedSlot % columns
    let row = wrappedSlot / columns

    let proposedX = visibleFrame.minX + simWindowMargin + (CGFloat(column) * simWindowXStep)
    let proposedY = visibleFrame.maxY - simWindowMargin - windowSize.height - (CGFloat(row) * simWindowYStep)
    let minY = visibleFrame.minY + simWindowMargin
    let minX = visibleFrame.minX + simWindowMargin
    let maxX = max(minX, visibleFrame.maxX - windowSize.width - simWindowMargin)
    let maxY = max(minY, visibleFrame.maxY - windowSize.height - simWindowMargin)

    return NSPoint(
      x: min(max(proposedX, minX), maxX),
      y: min(max(proposedY, minY), maxY)
    )
  }
}

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    self.tabbingMode = .disallowed
    // AppDelegate opts into secure state restoration, so AppKit would otherwise restore a
    // previously-saved (small) frame and ignore our default size. Opt this window out.
    self.isRestorable = false

    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Must come AFTER setting contentViewController: installing it resizes the window to
    // Flutter's default, so apply our size last.
    self.setContentSize(MainWindowDefaults.contentSize)
    if let slot = MainWindowDefaults.simWindowSlot,
       let origin = MainWindowDefaults.simWindowOrigin(
        slot: slot,
        windowSize: self.frame.size,
        screen: self.screen
       ) {
      self.setFrameOrigin(origin)
    } else {
      self.center()
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
