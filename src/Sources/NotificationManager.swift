import Foundation
import UserNotifications

/// Posts macOS notifications for events that matter while the popover is closed
/// (friends connecting, allotments running out, hosts pausing).
///
/// UNUserNotificationCenter only works from a real .app bundle — calling it from
/// a bare `swift build` binary crashes. All entry points are therefore guarded
/// by `available`, and the Settings UI explains when notifications are off.
final class NotificationManager {
    static let shared = NotificationManager()

    /// True when running from a bundle that can post notifications.
    static let available: Bool =
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")

    // User-facing toggles (Settings tab).
    static let friendEventsKey = "notify.friendEvents"
    static let allotmentKey = "notify.allotment"

    var friendEventsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.friendEventsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.friendEventsKey) }
    }
    var allotmentEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.allotmentKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.allotmentKey) }
    }

    private var authRequested = false
    /// Per-key cooldown so flappy online/offline presence can't spam.
    private var lastSent: [String: Date] = [:]

    private init() {}

    private func requestAuthIfNeeded() {
        guard !authRequested else { return }
        authRequested = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post a notification. `key` dedupes/throttles repeats (10 min per key).
    func post(key: String, title: String, body: String, throttle: TimeInterval = 600) {
        guard Self.available else { return }
        if let last = lastSent[key], Date().timeIntervalSince(last) < throttle { return }
        lastSent[key] = Date()
        requestAuthIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(
            identifier: "vibeshare.\(key).\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: State-transition diffing

    /// Compare consecutive refreshes and emit the interesting transitions.
    func diff(oldGrants: [GrantView], newGrants: [GrantView],
              oldConnections: [ConnectionView], newConnections: [ConnectionView]) {
        guard Self.available else { return }

        let oldG = Dictionary(uniqueKeysWithValues: oldGrants.map { ($0.id, $0) })
        for g in newGrants where !g.revoked {
            let prev = oldG[g.id]
            if friendEventsEnabled, g.online, prev?.online == false {
                post(key: "grant.online.\(g.id)",
                     title: "\(g.label) is connected",
                     body: "They can now use the models you shared.")
            }
            if allotmentEnabled, g.hasLimit, let p = prev {
                let was = p.hasLimit ? Double(p.totalTokens) / Double(p.tokenLimit) : 0
                let now = Double(g.totalTokens) / Double(g.tokenLimit)
                if now >= 1, was < 1 {
                    post(key: "grant.cap100.\(g.id)",
                         title: "\(g.label)'s allotment is used up",
                         body: "Top it up from the Share tab to keep them going.",
                         throttle: 0)
                } else if now >= 0.9, was < 0.9 {
                    post(key: "grant.cap90.\(g.id)",
                         title: "\(g.label) has used 90% of their allotment",
                         body: "\(compact(g.remaining)) tokens left.",
                         throttle: 0)
                }
            }
        }

        let oldC = Dictionary(uniqueKeysWithValues: oldConnections.map { ($0.id, $0) })
        for c in newConnections {
            let prev = oldC[c.id]
            let name = c.hostName.isEmpty ? c.label : c.hostName
            if friendEventsEnabled, c.online, prev?.online == false {
                post(key: "conn.online.\(c.id)",
                     title: "\(name) is online",
                     body: "Their shared models are available again.")
            }
            if friendEventsEnabled, c.online, c.paused, prev?.paused == false {
                post(key: "conn.paused.\(c.id)",
                     title: "\(name) paused sharing",
                     body: "Their models are unavailable until they resume.")
            }
            if friendEventsEnabled, c.revoked, prev?.revoked == false {
                post(key: "conn.revoked.\(c.id)",
                     title: "\(name) revoked sharing",
                     body: "This borrowed connection will no longer be used.",
                     throttle: 0)
            }
            if allotmentEnabled, c.hasLimit, let p = prev, p.hasLimit {
                let was = Double(p.tokensUsed) / Double(p.tokenLimit)
                let now = Double(c.tokensUsed) / Double(c.tokenLimit)
                if now >= 1, was < 1 {
                    post(key: "conn.cap100.\(c.id)",
                         title: "Your allotment from \(name) is used up",
                         body: "Ask them to top it up to keep going.",
                         throttle: 0)
                } else if now >= 0.9, was < 0.9 {
                    post(key: "conn.cap90.\(c.id)",
                         title: "90% of your allotment from \(name) used",
                         body: "\(compact(c.remaining)) tokens left.",
                         throttle: 0)
                }
            }
        }
    }
}
