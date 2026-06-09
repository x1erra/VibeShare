import SwiftUI

// MARK: - Root

struct MenuContentView: View {
    @EnvironmentObject var controller: AppController
    @State private var tab: Tab = .providers

    enum Tab: String, CaseIterable, Identifiable {
        case providers = "Providers"
        case share = "Share"
        case borrow = "Borrow"
        case settings = "Settings"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .providers: return "bolt.horizontal.circle"
            case .share: return "square.and.arrow.up"
            case .borrow: return "square.and.arrow.down"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Label(t.rawValue, systemImage: t.symbol).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch tab {
                    case .providers: ProvidersTab(providers: controller.providers)
                    case .share: ShareTab()
                    case .borrow: BorrowTab()
                    case .settings: SettingsTab()
                    }
                }
                .padding(12)
            }
            .frame(height: 360)

            Divider()
            FooterView()
        }
        .frame(width: 420)
    }
}

// MARK: - Header

struct HeaderView: View {
    @EnvironmentObject var controller: AppController

    private var running: Bool { controller.status?.running ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "person.2.wave.2.fill")
                    .foregroundStyle(.tint)
                Text("VibeShare").font(.headline)
                Spacer()
                StatusDot(on: running)
                Text(running ? "Running" : "Starting…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "link").font(.caption2).foregroundStyle(.secondary)
                Text(controller.endpointURL)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    controller.copyEndpoint()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy the OpenAI endpoint URL")
            }
            HStack(spacing: 12) {
                pill(icon: "antenna.radiowaves.left.and.right",
                     text: "\(controller.status?.connectedRelayCount ?? 0) relays")
                pill(icon: "cpu",
                     text: "\(controller.status?.models.count ?? 0) local models",
                     ok: controller.status?.upstream.reachable ?? false)
                pill(icon: "person.crop.circle",
                     text: controller.status?.identityName ?? "—")
            }
            .font(.caption2)
        }
        .padding(12)
    }

    private func pill(icon: String, text: String, ok: Bool = true) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
        }
        .foregroundStyle(ok ? .secondary : Color.orange)
    }
}

// MARK: - Providers

struct ProvidersTab: View {
    @EnvironmentObject var controller: AppController
    @ObservedObject var providers: ProviderManager

    private var localModels: [String] { controller.status?.models ?? [] }

    var body: some View {
        SectionTitle("Your AI subscriptions",
                     subtitle: "Sign in once. Credentials are stored locally by cli-proxy-api.")
        ForEach(ProviderCatalog.all) { p in
            let connected = providers.isConnected(p, localModels: localModels)
            HStack {
                Image(systemName: p.symbol).frame(width: 22).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.subheadline)
                    Text(connected ? "Connected" : "Not connected")
                        .font(.caption2)
                        .foregroundStyle(connected ? Color.green : .secondary)
                }
                Spacer()
                if providers.connecting.contains(p.key) {
                    ProgressView().controlSize(.small)
                } else {
                    Button(connected ? "Reconnect" : "Connect") {
                        controller.connectProvider(p)
                    }
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 2)
        }

        if !localModels.isEmpty {
            DisclosureGroup("Local models (\(localModels.count))") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(localModels, id: \.self) { m in
                        Text(m).font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
    }
}

// MARK: - Share (host / grants)

struct ShareTab: View {
    @EnvironmentObject var controller: AppController
    @State private var creating = false

    var body: some View {
        // Sheets don't present from a MenuBarExtra window, so the create form is
        // shown inline (it replaces the list until dismissed).
        if creating {
            CreateGrantView(onClose: { creating = false })
        } else {
            HStack {
                SectionTitle("Codes you've shared",
                             subtitle: "Each code lets one friend route through your providers.")
                Spacer()
                Button {
                    creating = true
                } label: { Label("New", systemImage: "plus") }
                    .controlSize(.small)
            }

            if controller.grants.filter({ !$0.revoked }).isEmpty {
                EmptyHint(icon: "square.and.arrow.up",
                          text: "Create a code and send it to a friend to share usage.")
            }

            ForEach(controller.grants.filter { !$0.revoked }) { g in
                GrantRow(grant: g)
            }
        }
    }
}

struct GrantRow: View {
    @EnvironmentObject var controller: AppController
    let grant: GrantView

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "person.crop.circle.badge.checkmark")
                Text(grant.label).font(.subheadline).bold()
                Spacer()
                if grant.routing { Badge(text: "routing", color: .blue) }
                Badge(text: grant.online ? "online" : "offline",
                      color: grant.online ? .green : .secondary)
            }
            HStack(spacing: 6) {
                Text(grant.code)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Button { controller.copyToPasteboard(grant.code) } label: {
                    Image(systemName: "doc.on.doc")
                }.buttonStyle(.borderless).help("Copy code")
                Spacer()
            }
            HStack {
                Text(grantScope).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(grant.totalReqs) reqs").font(.caption2).foregroundStyle(.secondary)
                Button(role: .destructive) {
                    Task { await controller.revokeGrant(grant.id) }
                } label: { Text("Revoke").font(.caption2) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private var grantScope: String {
        if !grant.advertisedModels.isEmpty {
            return "sharing \(grant.advertisedModels.count) models"
        }
        if !grant.providers.isEmpty {
            return "sharing: " + grant.providers.joined(separator: ", ")
        }
        if !grant.models.isEmpty {
            return "sharing \(grant.models.count) models"
        }
        return "sharing all models"
    }
}

// MARK: - Borrow (guest / connections)

struct BorrowTab: View {
    @EnvironmentObject var controller: AppController
    @State private var redeeming = false

    var body: some View {
        if redeeming {
            RedeemView(onClose: { redeeming = false })
        } else {
            HStack {
                SectionTitle("Friends sharing with you",
                             subtitle: "Enter a code a friend gave you to use their models.")
                Spacer()
                Button {
                    redeeming = true
                } label: { Label("Enter code", systemImage: "plus") }
                    .controlSize(.small)
            }

            if controller.connections.isEmpty {
                EmptyHint(icon: "square.and.arrow.down",
                          text: "No connections yet. Ask a friend for a VibeShare code.")
            }

            ForEach(controller.connections) { c in
                ConnectionRow(connection: c)
            }
        }
    }
}

struct ConnectionRow: View {
    @EnvironmentObject var controller: AppController
    let connection: ConnectionView

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "person.crop.circle")
                Text(displayName).font(.subheadline).bold()
                Spacer()
                if connection.routing { Badge(text: "routing", color: .blue) }
                Badge(text: connection.online ? "online" : "offline",
                      color: connection.online ? .green : .secondary)
            }
            if !connection.models.isEmpty {
                Text(connection.models.prefix(4).joined(separator: ", ")
                     + (connection.models.count > 4 ? "…" : ""))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(connection.online ? "Waiting for shared model list…" : "Friend is offline")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Text("\(connection.models.count) models").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(connection.totalReqs) reqs").font(.caption2).foregroundStyle(.secondary)
                Button(role: .destructive) {
                    Task { await controller.removeConnection(connection.id) }
                } label: { Text("Remove").font(.caption2) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private var displayName: String {
        if !connection.hostName.isEmpty { return connection.hostName }
        return connection.label
    }
}

// MARK: - Settings

struct SettingsTab: View {
    @EnvironmentObject var controller: AppController
    @State private var name: String = ""
    @State private var sharing: Bool = true

    private var upstreamOK: Bool { controller.status?.upstream.reachable ?? false }

    var body: some View {
        Group {
            SectionTitle("Identity", subtitle: "The name friends see when you're online.")
            HStack {
                TextField("Your name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { Task { await controller.setIdentityName(name) } }
                    .controlSize(.small)
            }

            Toggle("Enable peer-to-peer sharing", isOn: $sharing)
                .onChange(of: sharing) { newValue in
                    Task { await controller.setSharingEnabled(newValue) }
                }
                .font(.subheadline)

            Divider().padding(.vertical, 4)

            SectionTitle("Signaling relays", subtitle: "Public Nostr relays (used only for connection setup).")
            ForEach(controller.status?.nostr.relays ?? []) { r in
                HStack {
                    StatusDot(on: r.connected)
                    Text(r.url).font(.system(.caption2, design: .monospaced))
                    Spacer()
                }
            }

            Divider().padding(.vertical, 4)

            HStack {
                Image(systemName: upstreamOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(upstreamOK ? Color.green : Color.orange)
                Text(upstreamOK ? "Provider engine reachable" : "Provider engine starting…")
                    .font(.caption)
            }
            Button {
                controller.openLogsFolder()
            } label: { Label("Open logs folder", systemImage: "folder") }
                .controlSize(.small)
            Text("VibeShare 0.1.0").font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear {
            name = controller.status?.identityName ?? ""
            sharing = controller.status?.sharingEnabled ?? true
        }
    }
}

// MARK: - Footer

struct FooterView: View {
    @EnvironmentObject var controller: AppController
    var body: some View {
        HStack {
            if let err = controller.softError {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(err).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Updated \(controller.lastUpdated?.formatted(date: .omitted, time: .standard) ?? "—")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit") { controller.quit() }
                .controlSize(.small)
        }
        .padding(8)
    }
}

// MARK: - Inline forms (presented in-place; MenuBarExtra can't host sheets)

struct CreateGrantView: View {
    @EnvironmentObject var controller: AppController
    var onClose: () -> Void

    @State private var label = ""
    @State private var selected: Set<String> = []
    @State private var creating = false
    @State private var createdCode: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { onClose() } label: {
                    Image(systemName: "chevron.left")
                }.buttonStyle(.borderless)
                Text("Share a code").font(.headline)
                Spacer()
            }

            if let code = createdCode {
                Text("Send this code to \(label.isEmpty ? "your friend" : label):")
                    .font(.subheadline)
                HStack {
                    Text(code).font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled).lineLimit(1).minimumScaleFactor(0.6)
                    Button { controller.copyToPasteboard(code) } label: {
                        Image(systemName: "doc.on.doc")
                    }.buttonStyle(.borderless)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                Text("They paste it into VibeShare → Borrow → Enter code.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            } else {
                Text("Who is this for?").font(.subheadline)
                TextField("Friend's name (e.g. Steve)", text: $label)
                    .textFieldStyle(.roundedBorder)

                Text("Which providers to share?").font(.subheadline)
                Text("Leave all unchecked to share every model you have.")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(ProviderCatalog.all) { p in
                    Toggle(isOn: Binding(
                        get: { selected.contains(p.key) },
                        set: { on in if on { selected.insert(p.key) } else { selected.remove(p.key) } }
                    )) {
                        Label(p.name, systemImage: p.symbol)
                    }
                    .font(.subheadline)
                }

                HStack {
                    Button("Cancel") { onClose() }
                    Spacer()
                    Button(creating ? "Creating…" : "Create code") {
                        creating = true
                        Task {
                            let g = await controller.createGrant(
                                label: label, providers: Array(selected), models: [])
                            creating = false
                            createdCode = g?.code
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating)
                }
            }
        }
    }
}

struct RedeemView: View {
    @EnvironmentObject var controller: AppController
    var onClose: () -> Void

    @State private var code = ""
    @State private var label = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { onClose() } label: {
                    Image(systemName: "chevron.left")
                }.buttonStyle(.borderless)
                Text("Enter a friend's code").font(.headline)
                Spacer()
            }
            TextField("VS-XXXX-XXXX-…", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
            TextField("Label (e.g. Brandon)", text: $label)
                .textFieldStyle(.roundedBorder)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { onClose() }
                Spacer()
                Button(working ? "Linking…" : "Link up") {
                    working = true
                    error = nil
                    Task {
                        let ok = await controller.redeem(code: code, label: label)
                        working = false
                        if ok { onClose() } else { error = controller.softError ?? "Invalid code" }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || code.isEmpty)
            }
        }
    }
}

// MARK: - Small components

struct StatusDot: View {
    let on: Bool
    var body: some View {
        Circle().fill(on ? Color.green : Color.secondary.opacity(0.5))
            .frame(width: 8, height: 8)
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

struct SectionTitle: View {
    let title: String
    let subtitle: String?
    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline).bold()
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct EmptyHint: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}
