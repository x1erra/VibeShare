import SwiftUI

// MARK: - Providers

struct ProvidersTab: View {
    @EnvironmentObject var controller: AppController
    @ObservedObject var providers: ProviderManager

    private var localModels: [String] { controller.status?.models ?? [] }

    var body: some View {
        SectionTitle("Your AI subscriptions",
                     subtitle: "Sign in once. Credentials are stored locally by cli-proxy-api.")
        ForEach(ProviderCatalog.all) { p in
            ProviderRow(provider: p,
                        connected: providers.isConnected(p, localModels: localModels),
                        connecting: providers.connecting.contains(p.key),
                        usage: controller.status?.providerUsage?[p.key],
                        error: providers.errors[p.key],
                        logURL: providers.loginLogURL(p))
        }

        if let err = providers.lastError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(err).font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
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

        UseWithToolsSection()
    }
}

/// One provider as a card: the connect/disconnect row, any sign-in failure (with
/// its log), and — for providers we can read the host's own subscription usage
/// for (Claude, Codex) — the session/weekly limit windows underneath.
struct ProviderRow: View {
    @EnvironmentObject var controller: AppController
    let provider: ProviderInfo
    let connected: Bool
    let connecting: Bool
    let usage: ProviderUsage?
    let error: String?
    let logURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: provider.symbol).frame(width: 22).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.name).font(.subheadline)
                    Text(connected ? "Connected" : "Not connected")
                        .font(.caption2)
                        .foregroundStyle(connected ? Color.green : Color.secondary)
                }
                Spacer()
                if connecting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Finish sign-in in your browser")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else if connected {
                    Button("Disconnect") {
                        controller.disconnectProvider(provider)
                    }
                    .controlSize(.small)
                    .help("Remove the stored sign-in. Connect again any time.")
                } else {
                    Button("Connect") {
                        controller.connectProvider(provider)
                    }
                    .controlSize(.small)
                }
            }
            // Sign-in failures used to die silently in a log file; show them here.
            if let error {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                    Text(error).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("Open log") {
                        controller.openLogFile(logURL)
                    }
                    .font(.caption2).buttonStyle(.borderless)
                    Spacer()
                }
            }
            if connected, let usage {
                usageSection(usage)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder
    private func usageSection(_ usage: ProviderUsage) -> some View {
        if usage.hasData, !usage.shownWindows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(usage.shownWindows) { windowRow($0) }
            }
            .padding(.top, 2)
        } else if let err = usage.error, !err.isEmpty {
            Label("Limits: \(err)", systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            Text("Loading subscription limits…")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func windowRow(_ w: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(w.label).font(.caption2)
                Spacer()
                Text(detail(w)).font(.caption2).foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(w.utilization, 0), 100), total: 100)
                .progressViewStyle(.linear)
                .tint(w.percentUsed >= 90 ? .red : w.percentUsed >= 75 ? .orange : .blue)
        }
    }

    private func detail(_ w: UsageWindow) -> String {
        var parts = ["\(w.percentUsed)% used"]
        if let r = w.resetText { parts.append(r) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Use with your tools (copy-paste setup for the endpoint)

struct UseWithToolsSection: View {
    @EnvironmentObject var controller: AppController
    @AppStorage("useWithExpanded") private var expanded = false

    var body: some View {
        Divider().padding(.vertical, 2)
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Everything below points at your local endpoint — no real API key needed.")
                    .font(.caption2).foregroundStyle(.secondary)
                snippet("Claude Code (one-off)",
                        "ANTHROPIC_BASE_URL=\(controller.endpointBase) ANTHROPIC_API_KEY=vibeshare claude")
                snippet("Claude Code (shell alias — add to ~/.zshrc)",
                        "vibeclaude() { ANTHROPIC_BASE_URL=\(controller.endpointBase) ANTHROPIC_API_KEY=vibeshare claude \"$@\"; }")
                snippet("OpenAI SDK (Python)",
                        "client = OpenAI(base_url=\"\(controller.endpointURL)\", api_key=\"vibeshare\")")
                snippet("OpenAI SDK (JS / TS)",
                        "const client = new OpenAI({ baseURL: \"\(controller.endpointURL)\", apiKey: \"vibeshare\" })")
                snippet("List available models (yours + friends')",
                        "curl \(controller.endpointURL)/models")
            }
            .padding(.top, 6)
        } label: {
            Label("Use with your tools", systemImage: "terminal")
                .font(.subheadline).bold()
        }
    }

    private func snippet(_ title: String, _ cmd: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(cmd)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.vertical, 1)
                }
                CopyIconButton(text: cmd, help: "Copy",
                               onCopy: { controller.markToolSetupSeen() })
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        }
    }
}
