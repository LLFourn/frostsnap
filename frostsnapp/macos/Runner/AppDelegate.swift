import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Sim runs ask the app NOT to steal focus on launch: it's driven over the flutter_driver
    // VM service, so it needn't be frontmost, and grabbing the foreground while you work is
    // disruptive. Becoming an accessory keeps the window visible + drivable but stops it pulling
    // focus. Sim-ONLY — gated on the env var the harness sets; a normal launch is unaffected, and
    // the VM-service path is untouched.
    if ProcessInfo.processInfo.environment["FROSTSNAP_SIM_NO_ACTIVATE"] != nil {
      NSApp.setActivationPolicy(.accessory)
    }
    NSWindow.allowsAutomaticWindowTabbing = false
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
