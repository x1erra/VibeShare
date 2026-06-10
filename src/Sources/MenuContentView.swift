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
        // Sheets don't present from the menu bar popover, so the create form is
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

            allotmentSummary

            if controller.grants.filter({ !$0.revoked }).isEmpty {
                EmptyHint(icon: "square.and.arrow.up",
                          text: "Create a code and send it to a friend to share usage.")
            }

            ForEach(controller.grants.filter { !$0.revoked }) { g in
                GrantRow(grant: g)
            }
        }
    }

    /// Host-side at-a-glance: how much you've committed across capped friends and
    /// how much of that they've used.
    @ViewBuilder
    private var allotmentSummary: some View {
        let limited = controller.grants.filter { !$0.revoked && $0.hasLimit }
        if !limited.isEmpty {
            let allotted = limited.reduce(0) { $0 + $1.tokenLimit }
            let used = limited.reduce(0) { $0 + $1.totalTokens }
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill").font(.caption2)
                Text("Allotted \(compact(allotted)) tokens to \(limited.count) friend\(limited.count == 1 ? "" : "s") · \(compact(used)) used")
                    .font(.caption2)
                Spacer()
            }
            .foregroundStyle(.secondary)
        }
    }
}

struct GrantRow: View {
    @EnvironmentObject var controller: AppController
    let grant: GrantView
    @State private var editingLimit = false
    @State private var limitDraft = ""

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
                Text("\(grant.totalReqs) reqs · \(compact(grant.totalTokens)) tok")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help("↑ \(grant.inputTokens) in · ↓ \(grant.outputTokens) out tokens")
                Button(role: .destructive) {
                    Task { await controller.revokeGrant(grant.id) }
                } label: { Text("Revoke").font(.caption2) }
                    .buttonStyle(.borderless)
            }
            allotmentRow
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder
    private var allotmentRow: some View {
        if editingLimit {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill").font(.caption2).foregroundStyle(.secondary)
                TextField("Unlimited", text: $limitDraft)
                    .textFieldStyle(.roundedBorder).frame(width: 64).controlSize(.small)
                Text("M tokens").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Save") {
                    let newLimit = tokensFromMillions(limitDraft)
                    editingLimit = false
                    Task { await controller.setGrantLimit(grant.id, tokenLimit: newLimit) }
                }.font(.caption2).buttonStyle(.borderless)
                Button("Cancel") { editingLimit = false }
                    .font(.caption2).buttonStyle(.borderless)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.fill").font(.caption2).foregroundStyle(allotmentColor)
                    Text(allotmentText).font(.caption2).foregroundStyle(allotmentColor)
                    Spacer()
                    Button {
                        limitDraft = grant.hasLimit ? millionsString(grant.tokenLimit) : ""
                        editingLimit = true
                    } label: {
                        Image(systemName: "pencil").font(.caption2)
                    }.buttonStyle(.borderless).help("Set token allotment")
                }
                if grant.hasLimit {
                    ProgressView(value: min(Double(grant.totalTokens), Double(grant.tokenLimit)),
                                 total: Double(grant.tokenLimit))
                        .progressViewStyle(.linear).tint(allotmentColor)
                }
            }
        }
    }

    private var allotmentText: String {
        guard grant.hasLimit else { return "Unlimited tokens" }
        if grant.remaining == 0 { return "Allotment used up (\(compact(grant.tokenLimit)) tok)" }
        return "\(compact(grant.remaining)) of \(compact(grant.tokenLimit)) tokens left"
    }

    private var allotmentColor: Color {
        guard grant.hasLimit else { return .secondary }
        if grant.remaining == 0 { return .red }
        if Double(grant.remaining) < Double(grant.tokenLimit) * 0.1 { return .orange }
        return .secondary
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
            if connection.hasLimit {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.bar.fill").font(.caption2)
                        Text(allotmentText).font(.caption2)
                        Spacer()
                    }
                    .foregroundStyle(allotmentColor)
                    ProgressView(value: min(Double(connection.tokensUsed), Double(connection.tokenLimit)),
                                 total: Double(connection.tokenLimit))
                        .progressViewStyle(.linear).tint(allotmentColor)
                }
            }
            HStack {
                Text("\(connection.models.count) models").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(connection.totalReqs) reqs · \(compact(connection.totalTokens)) tok")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help("↑ \(connection.inputTokens) in · ↓ \(connection.outputTokens) out tokens")
                Button(role: .destructive) {
                    Task { await controller.removeConnection(connection.id) }
                } label: { Text("Remove").font(.caption2) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private var allotmentText: String {
        if connection.remaining == 0 {
            return "Allotment used up (\(compact(connection.tokenLimit)) tok)"
        }
        return "\(compact(connection.remaining)) of \(compact(connection.tokenLimit)) tokens left"
    }

    private var allotmentColor: Color {
        if connection.remaining == 0 { return .red }
        if Double(connection.remaining) < Double(connection.tokenLimit) * 0.1 { return .orange }
        return .secondary
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

// MARK: - Inline forms (presented in-place; the menu bar popover can't host sheets)

struct CreateGrantView: View {
    @EnvironmentObject var controller: AppController
    var onClose: () -> Void

    @State private var label = ""
    @State private var selected: Set<String> = []
    @State private var allotment = "" // millions of tokens; blank = unlimited
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

                Text("Token allotment").font(.subheadline)
                HStack(spacing: 6) {
                    TextField("Unlimited", text: $allotment)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                    Text("million tokens").font(.caption).foregroundStyle(.secondary)
                }
                Text("Caps how much of your subscription this friend can use. Leave blank for unlimited; you can top it up later.")
                    .font(.caption2).foregroundStyle(.secondary)

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
                        let limit = tokensFromMillions(allotment)
                        Task {
                            let g = await controller.createGrant(
                                label: label, providers: Array(selected), models: [], tokenLimit: limit)
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

/// compact renders a count as 950, 12.3K, or 4.5M for tight UI labels.
func compact(_ n: Int) -> String {
    let v = Double(n)
    switch n {
    case ..<1_000: return "\(n)"
    case ..<1_000_000: return String(format: "%.1fK", v / 1_000)
    default: return String(format: "%.1fM", v / 1_000_000)
    }
}

/// tokensFromMillions parses a user-entered "millions of tokens" string into an
/// absolute token count. Blank or unparseable (incl. negative) means unlimited (0).
func tokensFromMillions(_ s: String) -> Int {
    let m = Double(s.trimmingCharacters(in: .whitespaces)) ?? 0
    return m > 0 ? Int(m * 1_000_000) : 0
}

/// millionsString renders an absolute token count back as a clean millions value
/// for prefilling the edit field (10_000_000 -> "10", 2_500_000 -> "2.5").
func millionsString(_ tokens: Int) -> String {
    let m = Double(tokens) / 1_000_000
    return m == m.rounded() ? String(Int(m)) : String(format: "%.2f", m)
}

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
