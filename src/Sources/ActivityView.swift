import SwiftUI

// MARK: - Activity (live feed of routed requests, both directions)

struct ActivityTab: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        SectionTitle("Recent activity",
                     subtitle: "Requests routed through your shares, newest first. Resets when the engine restarts.")
        if controller.activity.isEmpty {
            EmptyHint(icon: "list.bullet.rectangle",
                      text: "Nothing routed yet. Requests appear here the moment a friend uses your models (or you use theirs).")
        }
        ForEach(controller.activity) { e in
            ActivityRow(entry: e)
        }
    }
}

struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.hosted ? "arrow.up.right.circle.fill" : "arrow.down.left.circle.fill")
                .foregroundStyle(entry.ok ? (entry.hosted ? Color.blue : Color.green) : Color.red)
                .font(.system(size: 14))
                .help(entry.hosted ? "A friend used your account" : "You used a friend's account")
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(headline)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(entry.date, style: .relative)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if entry.ok {
                    Text("\(compact(entry.inputTokens))↑ \(compact(entry.outputTokens))↓ tok · \(durationText)")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(entry.error.isEmpty ? "failed" : entry.error)
                        .font(.caption2).foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var headline: String {
        let peer = entry.peer.isEmpty ? "friend" : entry.peer
        let model = entry.model.isEmpty ? "unknown model" : entry.model
        return entry.hosted ? "\(peer) used \(model)" : "You used \(peer)'s \(model)"
    }

    private var durationText: String {
        entry.durationMs >= 1000
            ? String(format: "%.1fs", Double(entry.durationMs) / 1000)
            : "\(entry.durationMs)ms"
    }
}
