import AppKit
import SwiftUI

/// Owns the menu bar status item directly instead of using SwiftUI's
/// `MenuBarExtra`, so the icon can be updated imperatively. A blue dot shows in
/// the top-right corner while a request is being routed, giving an at-a-glance
/// signal without opening the app. The main UI lives in a popover.
///
/// We don't use `MenuBarExtra` because its label renders as a cached, monochrome
/// (template) image that doesn't reliably re-render on state changes — so a
/// blinking, colored dot isn't achievable there.
@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    /// The routing indicator, drawn on top of the icon. A real subview (not part
    /// of the template image) so it keeps its color against the menu bar.
    private let dot = NSView()

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 420, height: 540)
        popover.contentViewController = NSHostingController(
            rootView: MenuContentView().environmentObject(AppController.shared)
        )

        if let button = statusItem.button {
            let icon = NSImage(systemSymbolName: "person.2.wave.2.fill",
                               accessibilityDescription: "VibeShare")
            icon?.isTemplate = true
            button.image = icon
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover(_:))

            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
            dot.layer?.cornerRadius = Self.dotSize / 2
            dot.isHidden = true
            button.addSubview(dot)
        }

        // Refreshes happen every ~2s; re-evaluate the routing state each time.
        AppController.shared.onUpdate = { [weak self] in self?.routingChanged() }
    }

    // MARK: Routing dot

    private static let dotSize: CGFloat = 7
    /// Minimum time the dot stays visible, so a short completion still blinks.
    private static let dotLinger: TimeInterval = 1.5

    private var hideDotWork: DispatchWorkItem?
    private var dotShownAt = Date.distantPast

    private func positionDot() {
        guard let button = statusItem.button else { return }
        let d = Self.dotSize
        let b = button.bounds
        // Top-right corner, tucked just inside the icon's bounds.
        dot.frame = NSRect(x: b.maxX - d - 0.5, y: b.maxY - d - 1.5, width: d, height: d)
    }

    /// Show a solid dot while any request is in flight; hide it (after a short
    /// linger so it's actually perceivable) when idle.
    private func routingChanged() {
        let routing = AppController.shared.isRouting
        if routing {
            hideDotWork?.cancel()
            hideDotWork = nil
            positionDot()
            if dot.isHidden { dotShownAt = Date() }
            dot.isHidden = false
        } else if !dot.isHidden, hideDotWork == nil {
            let elapsed = Date().timeIntervalSince(dotShownAt)
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hideDotWork = nil
                if !AppController.shared.isRouting { self.dot.isHidden = true }
            }
            hideDotWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + max(0, Self.dotLinger - elapsed), execute: work)
        }
    }

    // MARK: Popover

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
