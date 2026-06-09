import SwiftUI

@main
struct VibeShareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The menu bar item is managed imperatively by StatusBarController (created
    // in AppDelegate) so the icon can show a routing dot. This app therefore
    // has no visible SwiftUI window; the hidden Settings scene just satisfies
    // the App scene requirement for a menu-bar-only (accessory) app.
    var body: some Scene {
        Settings { EmptyView() }
    }
}
