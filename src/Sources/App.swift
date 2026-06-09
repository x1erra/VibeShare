import SwiftUI

@main
struct VibeShareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("VibeShare", systemImage: "person.2.wave.2.fill") {
            MenuContentView()
                .environmentObject(AppController.shared)
        }
        .menuBarExtraStyle(.window)
    }
}
