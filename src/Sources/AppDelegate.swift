import AppKit

/// Minimal delegate: enforce menu-bar-only (accessory) policy, boot the
/// engine, and stop child processes on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppController.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProcessManager.shared.stopAll()
    }
}
