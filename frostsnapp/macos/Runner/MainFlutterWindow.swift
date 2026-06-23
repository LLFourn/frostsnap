import Cocoa
import FlutterMacOS

private enum MainWindowDefaults {
  static let contentSize = NSSize(width: 1280, height: 832)
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
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
