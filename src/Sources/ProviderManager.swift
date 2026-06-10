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
    /// Per-provider sign-in failures, keyed by provider key, so the row that
    /// failed can explain itself instead of failing silently.
    @Published private(set) var errors: [String: String] = [:]

    func isConnected(_ provider: ProviderInfo, localModels: [String]) -> Bool {
        let lower = localModels.map { $0.lowercased() }
        return lower.contains { id in
            provider.modelHints.contains { id.contains($0) }
        }
    }

    /// Where this provider's OAuth flow writes its output.
    func loginLogURL(_ provider: ProviderInfo) -> URL {
        AppPaths.stateDir.appendingPathComponent("login-\(provider.key).log")
    }

    /// The credential files cli-proxy-api stores for this provider — one JSON
    /// per signed-in account, named "<key>-<account>.json" in its auth dir
    /// (e.g. claude-user@example.com.json).
    func authFiles(_ provider: ProviderInfo) -> [URL] {
        let dir = AppPaths.providerAuthDir
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter {
            $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix(provider.key + "-")
        }
    }

    /// Disconnect = delete the locally stored sign-in(s). cli-proxy-api watches
    /// its auth dir and hot-reloads, so the provider's models disappear from the
    /// local list (and from anything shared with friends) within seconds.
    func disconnect(_ provider: ProviderInfo) {
        for f in authFiles(provider) {
            try? FileManager.default.removeItem(at: f)
        }
        DispatchQueue.main.async { self.errors[provider.key] = nil }
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

        DispatchQueue.main.async {
            self.connecting.insert(provider.key)
            self.errors[provider.key] = nil
        }

        let proc = Process()
        proc.executableURL = bin
        proc.arguments = [flag, "-config", AppPaths.providerConfigPath().path]
        let logURL = loginLogURL(provider)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: logURL)
        if let handle {
            proc.standardOutput = handle
            proc.standardError = handle
        }
        proc.terminationHandler = { [weak self] p in
            try? handle?.close()
            let failed = p.terminationStatus != 0
            DispatchQueue.main.async {
                self?.connecting.remove(provider.key)
                if failed {
                    self?.errors[provider.key] =
                        "Sign-in didn't finish (exit \(p.terminationStatus)) — open the log for details."
                }
            }
        }
        do {
            try proc.run()
        } catch {
            DispatchQueue.main.async {
                self.connecting.remove(provider.key)
                self.errors[provider.key] = "Login failed to start: \(error.localizedDescription)"
            }
        }
    }
}
