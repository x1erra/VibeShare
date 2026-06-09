import Foundation
import Combine

/// A connectable LLM provider, mapped to the cli-proxy-api login flag that
/// authenticates it. `modelHints` let us infer "connected" from the live model
/// list rather than parsing auth files.
struct ProviderInfo: Identifiable {
    let key: String
    let name: String
    let loginFlag: String?
    let symbol: String
    let modelHints: [String]
    var id: String { key }
}

enum ProviderCatalog {
    static let all: [ProviderInfo] = [
        ProviderInfo(key: "claude", name: "Claude (Anthropic)", loginFlag: "-claude-login",
                     symbol: "sparkles", modelHints: ["claude"]),
        ProviderInfo(key: "codex", name: "ChatGPT / Codex (OpenAI)", loginFlag: "-codex-login",
                     symbol: "chevron.left.forwardslash.chevron.right", modelHints: ["gpt", "o1", "o3", "o4", "codex"]),
        ProviderInfo(key: "gemini", name: "Gemini (Google)", loginFlag: "-login",
                     symbol: "diamond", modelHints: ["gemini"]),
        ProviderInfo(key: "kimi", name: "Kimi (Moonshot)", loginFlag: "-kimi-login",
                     symbol: "moon.stars", modelHints: ["kimi", "moonshot"]),
        ProviderInfo(key: "antigravity", name: "Antigravity", loginFlag: "-antigravity-login",
                     symbol: "arrow.up.forward.app", modelHints: ["antigravity"]),
        ProviderInfo(key: "xai", name: "xAI / Grok", loginFlag: "-xai-login",
                     symbol: "x.circle", modelHints: ["grok"]),
    ]
}

/// ProviderManager drives cli-proxy-api OAuth logins and infers which providers
/// are currently connected from the live model list.
final class ProviderManager: ObservableObject {
    @Published private(set) var connecting: Set<String> = []
    @Published private(set) var lastError: String?

    func isConnected(_ provider: ProviderInfo, localModels: [String]) -> Bool {
        let lower = localModels.map { $0.lowercased() }
        return lower.contains { id in
            provider.modelHints.contains { id.contains($0) }
        }
    }

    /// Launches the provider's OAuth flow. cli-proxy-api opens the browser and
    /// writes credentials into ~/.cli-proxy-api, which the running server then
    /// hot-reloads.
    func connect(_ provider: ProviderInfo) {
        guard let flag = provider.loginFlag else { return }
        guard let bin = AppPaths.providerBinary else {
            lastError = "cli-proxy-api binary missing"
            return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

        DispatchQueue.main.async { self.connecting.insert(provider.key) }

        let proc = Process()
        proc.executableURL = bin
        proc.arguments = [flag, "-config", AppPaths.providerConfigPath().path]
        let logURL = AppPaths.stateDir.appendingPathComponent("login-\(provider.key).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: logURL)
        if let handle {
            proc.standardOutput = handle
            proc.standardError = handle
        }
        proc.terminationHandler = { [weak self] _ in
            try? handle?.close()
            DispatchQueue.main.async { self?.connecting.remove(provider.key) }
        }
        do {
            try proc.run()
        } catch {
            DispatchQueue.main.async {
                self.connecting.remove(provider.key)
                self.lastError = "Login failed to start: \(error.localizedDescription)"
            }
        }
    }
}
