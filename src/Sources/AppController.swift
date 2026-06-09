import Foundation
import SwiftUI
import AppKit

/// AppController is the single source of truth the SwiftUI views observe. It
/// boots the child processes and polls the router's control API.
@MainActor
final class AppController: ObservableObject {
    @Published var status: RouterStatus?
    @Published var grants: [GrantView] = []
    @Published var connections: [ConnectionView] = []
    @Published var softError: String?
    @Published var lastUpdated: Date?

    let processes = ProcessManager.shared
    let providers = ProviderManager()
    var client = RouterClient()

    static let shared = AppController()

    private var pollTask: Task<Void, Never>?

    func start() {
        processes.startAll()
        startPolling()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func refresh() async {
        do {
            async let s = client.status()
            async let g = client.grants()
            async let c = client.connections()
            let (st, gr, co) = try await (s, g, c)
            status = st
            grants = gr
            connections = co
            softError = nil
            lastUpdated = Date()
        } catch {
            // The router may still be coming up; keep prior data, surface softly.
            softError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Actions

    @discardableResult
    func createGrant(label: String, providers: [String], models: [String]) async -> GrantView? {
        do {
            let g = try await client.createGrant(label: label, providers: providers, models: models)
            await refresh()
            return g
        } catch {
            softError = error.localizedDescription
            return nil
        }
    }

    func revokeGrant(_ id: String) async {
        try? await client.revokeGrant(id: id)
        await refresh()
    }

    @discardableResult
    func redeem(code: String, label: String) async -> Bool {
        do {
            _ = try await client.redeem(code: code, label: label)
            await refresh()
            return true
        } catch {
            softError = error.localizedDescription
            return false
        }
    }

    func removeConnection(_ id: String) async {
        try? await client.removeConnection(id: id)
        await refresh()
    }

    func connectProvider(_ provider: ProviderInfo) {
        providers.connect(provider)
    }

    func setIdentityName(_ name: String) async {
        guard var cfg = try? await client.config() else { return }
        cfg.identityName = name
        try? await client.updateConfig(cfg)
        await refresh()
    }

    func setSharingEnabled(_ enabled: Bool) async {
        guard var cfg = try? await client.config() else { return }
        cfg.enableSharing = enabled
        try? await client.updateConfig(cfg)
        await refresh()
    }

    var endpointURL: String {
        "http://127.0.0.1:\(status?.frontPort ?? 8788)/v1"
    }

    func copyEndpoint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpointURL, forType: .string)
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openLogsFolder() {
        NSWorkspace.shared.open(AppPaths.stateDir)
    }

    func quit() {
        ProcessManager.shared.stopAll()
        NSApplication.shared.terminate(nil)
    }
}
