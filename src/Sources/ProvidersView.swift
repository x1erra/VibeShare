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
            providerRow(p)
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

    @ViewBuilder
    private func providerRow(_ p: ProviderInfo) -> some View {
        let connected = providers.isConnected(p, localModels: localModels)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: p.symbol).frame(width: 22).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.subheadline)
                    Text(connected ? "Connected" : "Not connected")
                        .font(.caption2)
                        .foregroundStyle(connected ? Color.green : Color.secondary)
                }
                Spacer()
                if providers.connecting.contains(p.key) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Finish sign-in in your browser")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else if connected {
                    Button("Disconnect") {
                        controller.disconnectProvider(p)
                    }
                    .controlSize(.small)
                    .help("Remove the stored sign-in. Connect again any time.")
                } else {
                    Button("Connect") {
                        controller.connectProvider(p)
                    }
                    .controlSize(.small)
                }
            }
            // Sign-in failures used to die silently in a log file; show them here.
            if let err = providers.errors[p.key] {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                    Text(err).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("Open log") {
                        controller.openLogFile(providers.loginLogURL(p))
                    }
                    .font(.caption2).buttonStyle(.borderless)
                    Spacer()
                }
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 2)
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
