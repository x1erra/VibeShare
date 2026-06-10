import SwiftUI

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
    @State private var codeRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "person.crop.circle.badge.checkmark")
                Text(grant.label).font(.subheadline).bold()
                Spacer()
                if grant.routing { Badge(text: "routing", color: .blue) }
                if grant.paused {
                    Badge(text: "paused", color: .orange)
                } else {
                    Badge(text: grant.online ? "online" : "offline",
                          color: grant.online ? .green : .secondary)
                }
            }
            HStack(spacing: 6) {
                // The code is a bearer credential — mask it unless revealed.
                Text(codeRevealed ? grant.code : maskedCode)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Button {
                    codeRevealed.toggle()
                } label: {
                    // Fixed footprint: eye / eye.slash glyphs differ in size.
                    Image(systemName: codeRevealed ? "eye.slash" : "eye")
                        .frame(width: 18, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(codeRevealed ? "Hide code" : "Reveal code")
                CopyIconButton(text: grant.code, help: "Copy code")
                Spacer()
            }
            HStack {
                Text(grantScope).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(grant.totalReqs) reqs · \(compact(grant.totalTokens)) tok")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help("↑ \(grant.inputTokens) in · ↓ \(grant.outputTokens) out tokens")
                // Pause keeps the code alive (resume any time); revoke kills it.
                Button(action: {
                    Task { await controller.setGrantPaused(grant.id, paused: !grant.paused) }
                }) {
                    // Fixed width: Pause ↔ Resume shouldn't nudge its neighbors.
                    Text(grant.paused ? "Resume" : "Pause").font(.caption2).frame(width: 46)
                }
                .buttonStyle(.borderless)
                .help(grant.paused
                      ? "Start serving this friend again"
                      : "Temporarily stop serving this friend (the code keeps working when you resume)")
                Button(role: .destructive) {
                    Task { await controller.revokeGrant(grant.id) }
                } label: { Text("Revoke").font(.caption2) }
                    .buttonStyle(.borderless)
                    .help("Permanently kill this code — to share again you'll need to send a new one")
            }
            allotmentRow
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .opacity(grant.paused ? 0.75 : 1)
    }

    /// Same length and shape as the real code ("VS-" and hyphens kept, the rest
    /// dotted) so toggling the eye doesn't move anything — the font is
    /// monospaced, so equal character counts mean equal width.
    private var maskedCode: String {
        String(grant.code.enumerated().map { i, ch in
            i < 3 || ch == "-" ? ch : "•"
        })
    }

    @ViewBuilder
    private var allotmentRow: some View {
        if editingLimit {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill").font(.caption2).foregroundStyle(.secondary)
                TextField("Unlimited", text: $limitDraft)
                    .textFieldStyle(.roundedBorder).frame(width: 90).controlSize(.small)
                    .onSubmit { saveLimit() } // Return saves, no extra click
                Text("tokens (e.g. 500k, 2m)").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Save") { saveLimit() }
                    .font(.caption2).buttonStyle(.borderless)
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
                        limitDraft = grant.hasLimit ? tokenAmountString(grant.tokenLimit) : ""
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

    private func saveLimit() {
        let newLimit = parseTokenAmount(limitDraft)
        editingLimit = false
        Task { await controller.setGrantLimit(grant.id, tokenLimit: newLimit) }
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
        if !grant.models.isEmpty {
            return "sharing \(grant.models.count) specific model\(grant.models.count == 1 ? "" : "s")"
        }
        if !grant.providers.isEmpty {
            return "sharing: " + grant.providers.joined(separator: ", ")
        }
        if !grant.advertisedModels.isEmpty {
            return "sharing everything (\(grant.advertisedModels.count) models)"
        }
        return "sharing everything"
    }
}

// MARK: - Create grant (inline; the menu bar popover can't host sheets)

struct CreateGrantView: View {
    @EnvironmentObject var controller: AppController
    var onClose: () -> Void

    enum ShareScope: String, CaseIterable, Identifiable {
        case everything = "Everything"
        case providers = "Providers"
        case models = "Models"
        var id: String { rawValue }
    }

    @State private var label = ""
    @State private var scope: ShareScope = .everything
    @State private var selectedProviders: Set<String> = []
    @State private var selectedModels: Set<String> = []
    @State private var allotment = "" // millions of tokens; blank = unlimited
    @State private var creating = false
    @State private var createdCode: String?

    private var localModels: [String] { controller.status?.models ?? [] }

    /// Selection must be explicit: no more "leave everything unchecked to share
    /// it all" foot-gun.
    private var canCreate: Bool {
        switch scope {
        case .everything: return true
        case .providers: return !selectedProviders.isEmpty
        case .models: return !selectedModels.isEmpty
        }
    }

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
                    CopyIconButton(text: code, help: "Copy code")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                Text("They paste it into VibeShare → Borrow → Enter code. Treat it like a password — anyone holding it can use what you shared.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            } else {
                Text("Who is this for?").font(.subheadline)
                TextField("Friend's name (e.g. Steve)", text: $label)
                    .textFieldStyle(.roundedBorder)

                Text("Token allotment").font(.subheadline)
                HStack(spacing: 6) {
                    TextField("Unlimited", text: $allotment)
                        .textFieldStyle(.roundedBorder).frame(width: 110)
                    Text("tokens — plain number or 500k / 2m")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Caps how much of your subscription this friend can use. Leave blank for unlimited; you can top it up later.")
                    .font(.caption2).foregroundStyle(.secondary)

                Text("What to share").font(.subheadline)
                Picker("", selection: $scope) {
                    ForEach(ShareScope.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                scopeDetails

                HStack {
                    Button("Cancel") { onClose() }
                    Spacer()
                    Button(creating ? "Creating…" : "Create code") {
                        creating = true
                        let limit = parseTokenAmount(allotment)
                        let providers = scope == .providers ? Array(selectedProviders) : []
                        let models = scope == .models ? Array(selectedModels) : []
                        Task {
                            let g = await controller.createGrant(
                                label: label, providers: providers, models: models, tokenLimit: limit)
                            creating = false
                            createdCode = g?.code
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating || !canCreate)
                }
            }
        }
        .onAppear {
            // Pre-check what's actually connected so "Providers" starts sensible.
            let models = localModels
            selectedProviders = Set(ProviderCatalog.all
                .filter { controller.providers.isConnected($0, localModels: models) }
                .map(\.key))
        }
    }

    @ViewBuilder
    private var scopeDetails: some View {
        switch scope {
        case .everything:
            Text("Every model you have now — and any you connect later.")
                .font(.caption2).foregroundStyle(.secondary)
        case .providers:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ProviderCatalog.all) { p in
                    Toggle(isOn: Binding(
                        get: { selectedProviders.contains(p.key) },
                        set: { on in
                            if on { selectedProviders.insert(p.key) } else { selectedProviders.remove(p.key) }
                        }
                    )) {
                        Label(p.name, systemImage: p.symbol)
                    }
                    .font(.subheadline)
                }
                if selectedProviders.isEmpty {
                    Text("Pick at least one provider.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        case .models:
            VStack(alignment: .leading, spacing: 4) {
                if localModels.isEmpty {
                    Text("No local models yet — connect a provider first.")
                        .font(.caption2).foregroundStyle(.orange)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(localModels, id: \.self) { m in
                                Toggle(isOn: Binding(
                                    get: { selectedModels.contains(m) },
                                    set: { on in
                                        if on { selectedModels.insert(m) } else { selectedModels.remove(m) }
                                    }
                                )) {
                                    Text(m).font(.system(.caption2, design: .monospaced))
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                    if selectedModels.isEmpty {
                        Text("Pick at least one model.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}
