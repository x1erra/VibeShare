import AppKit

/// Minimal delegate: enforce menu-bar-only (accessory) policy, create the status
/// bar item, boot the engine, and stop child processes on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBar = StatusBarController()
        AppController.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProcessManager.shared.stopAll()
    }
}
