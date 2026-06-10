import SwiftUI

// MARK: - Settings

struct SettingsTab: View {
    @EnvironmentObject var controller: AppController
    @State private var name: String = ""
    @State private var nameSaved = false
    @State private var sharing: Bool = true
    @State private var notifyFriends = NotificationManager.shared.friendEventsEnabled
    @State private var notifyAllotment = NotificationManager.shared.allotmentEnabled
    @State private var editingRelays = false
    @State private var relaysDraft = ""
    @State private var relaysRestarting = false

    private var upstreamOK: Bool { controller.status?.upstream.reachable ?? false }

    private func saveName() {
        Task {
            if await controller.setIdentityName(name) {
                nameSaved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { nameSaved = false }
            }
        }
    }

    var body: some View {
        identitySection
        Divider().padding(.vertical, 4)
        notificationsSection
        Divider().padding(.vertical, 4)
        relaysSection
        Divider().padding(.vertical, 4)
        engineSection
    }

    // MARK: Identity & behavior

    @ViewBuilder
    private var identitySection: some View {
        SectionTitle("Identity", subtitle: "The name friends see when you're online.")
        HStack {
            TextField("Your name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveName() } // Return saves, no extra click
            Button(action: { saveName() }) {
                // Fixed width so Save → Saved ✓ doesn't resize the text field.
                Text(nameSaved ? "Saved ✓" : "Save").frame(width: 52)
            }
            .controlSize(.small)
            .disabled(nameSaved)
        }
        .onAppear {
            name = controller.status?.identityName ?? ""
            sharing = controller.status?.sharingEnabled ?? true
        }

        Toggle("Enable peer-to-peer sharing", isOn: $sharing)
            .onChange(of: sharing) { newValue in
                Task { await controller.setSharingEnabled(newValue) }
            }
            .font(.subheadline)

        if AppController.launchAtLoginAvailable {
            Toggle("Start VibeShare at login", isOn: Binding(
                get: { controller.launchAtLogin },
                set: { controller.setLaunchAtLogin($0) }
            ))
            .font(.subheadline)
            .help("Friends can only use your models while VibeShare is running.")
        } else {
            HStack(spacing: 6) {
                Toggle("Start VibeShare at login", isOn: .constant(false))
                    .font(.subheadline).disabled(true)
            }
            Text("Available when running the packaged VibeShare.app (make app).")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Notifications

    @ViewBuilder
    private var notificationsSection: some View {
        SectionTitle("Notifications", subtitle: "Heads-up while the popover is closed.")
        if NotificationManager.available {
            Toggle("Friends connecting, going online, or pausing", isOn: $notifyFriends)
                .onChange(of: notifyFriends) { NotificationManager.shared.friendEventsEnabled = $0 }
                .font(.subheadline)
            Toggle("Token allotments at 90% and used up", isOn: $notifyAllotment)
                .onChange(of: notifyAllotment) { NotificationManager.shared.allotmentEnabled = $0 }
                .font(.subheadline)
        } else {
            Text("Available when running the packaged VibeShare.app (make app).")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Relays

    @ViewBuilder
    private var relaysSection: some View {
        HStack {
            SectionTitle("Signaling relays",
                         subtitle: "Public Nostr relays (used only for encrypted connection setup).")
            Spacer()
            if !editingRelays {
                Button("Edit") {
                    relaysDraft = (controller.status?.nostr.relays ?? [])
                        .map(\.url).joined(separator: "\n")
                    editingRelays = true
                }
                .controlSize(.small)
            }
        }
        if editingRelays {
            TextField("wss://relay.example.com (one per line)", text: $relaysDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(3...8)
            HStack {
                Button("Cancel") { editingRelays = false }
                    .controlSize(.small)
                Spacer()
                Button(relaysRestarting ? "Restarting…" : "Save & restart engine") {
                    let relays = relaysDraft
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { $0.contains("://") }
                    guard !relays.isEmpty else { return }
                    relaysRestarting = true
                    Task {
                        _ = await controller.setRelays(relays)
                        relaysRestarting = false
                        editingRelays = false
                    }
                }
                .controlSize(.small)
                .disabled(relaysRestarting)
            }
            Text("Relays only apply on engine start, so saving restarts the router (a second or two).")
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            ForEach(controller.status?.nostr.relays ?? []) { r in
                HStack {
                    StatusDot(on: r.connected)
                    Text(r.url).font(.system(.caption2, design: .monospaced))
                    Spacer()
                }
            }
        }
    }

    // MARK: Engine

    @ViewBuilder
    private var engineSection: some View {
        HStack {
            Image(systemName: upstreamOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(upstreamOK ? Color.green : Color.orange)
            Text(upstreamOK ? "Provider engine reachable" : "Provider engine starting…")
                .font(.caption)
        }
        HStack {
            Button {
                controller.openLogsFolder()
            } label: { Label("Open logs folder", systemImage: "folder") }
                .controlSize(.small)
            Button {
                ProcessManager.shared.restartAll()
            } label: { Label("Restart engine", systemImage: "arrow.clockwise") }
                .controlSize(.small)
                .help("Restarts both bundled engines (router + provider)")
        }
        Text("VibeShare 0.1.0").font(.caption2).foregroundStyle(.secondary)
    }
}
