import Foundation
import Combine

/// ProcessManager owns the two long-running Go child processes: the provider
/// engine (cli-proxy-api) and the VibeShare router. It is a singleton so the
/// app-termination hook can stop them cleanly. It restarts a child that dies
/// unexpectedly, and never lets `stopAll` hang on quit.
final class ProcessManager: ObservableObject {
    static let shared = ProcessManager()

    @Published private(set) var providerRunning = false
    @Published private(set) var routerRunning = false
    @Published private(set) var lastError: String?

    private var providerProcess: Process?
    private var routerProcess: Process?
    private var providerLog: FileHandle?
    private var routerLog: FileHandle?
    private var providerStartedAt = Date.distantPast
    private var routerStartedAt = Date.distantPast
    private var stopping = false
    private let queue = DispatchQueue(label: "com.vibeshare.process")

    private init() {}

    func startAll() {
        queue.async {
            self.stopping = false
            self.reapStale() // clean up orphans from a previous force-quit/crash
            self.startProvider()
            // Let the provider bind :8317 before the router first probes it.
            Thread.sleep(forTimeInterval: 0.6)
            self.startRouter()
        }
    }

    /// Kills leftover VibeShare children from a prior run (matched narrowly so we
    /// never touch an unrelated cli-proxy-api install).
    private func reapStale() {
        let markers = ["vibeshare-router", AppPaths.providerConfigPath().path]
        for marker in markers {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            p.arguments = ["-f", marker]
            try? p.run()
            p.waitUntilExit()
        }
    }

    func stopAll() {
        queue.sync {
            self.stopping = true
            self.kill(self.routerProcess); self.routerProcess = nil
            try? self.routerLog?.close(); self.routerLog = nil
            self.kill(self.providerProcess); self.providerProcess = nil
            try? self.providerLog?.close(); self.providerLog = nil
        }
        DispatchQueue.main.async {
            self.routerRunning = false
            self.providerRunning = false
        }
    }

    /// Full engine restart (e.g. after a relay/port config change, or from the
    /// health banner). Async so the UI never blocks on the 3s kill deadline.
    func restartAll() {
        queue.async {
            self.stopping = true
            self.kill(self.routerProcess); self.routerProcess = nil
            try? self.routerLog?.close(); self.routerLog = nil
            self.kill(self.providerProcess); self.providerProcess = nil
            try? self.providerLog?.close(); self.providerLog = nil
            DispatchQueue.main.async {
                self.routerRunning = false
                self.providerRunning = false
                self.lastError = nil
            }
            self.stopping = false
            self.startProvider()
            Thread.sleep(forTimeInterval: 0.6)
            self.startRouter()
        }
    }

    /// Restart just the router (relay changes only apply on router start).
    func restartRouter() {
        queue.async {
            self.stopping = true
            self.kill(self.routerProcess); self.routerProcess = nil
            try? self.routerLog?.close(); self.routerLog = nil
            DispatchQueue.main.async { self.routerRunning = false }
            self.stopping = false
            self.startRouter()
        }
    }

    /// SIGTERM, then SIGKILL if the process refuses to exit within 3s, so quit
    /// can never hang on a wedged child.
    private func kill(_ proc: Process?) {
        guard let p = proc, p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning {
            Foundation.kill(p.processIdentifier, SIGKILL)
            p.waitUntilExit()
        }
    }

    // MARK: Launch

    private func startProvider() {
        guard providerProcess == nil else { return }
        guard let bin = AppPaths.providerBinary else {
            setError("cli-proxy-api binary not found in bundle"); return
        }
        makeExecutable(bin)
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = ["-config", AppPaths.providerConfigPath().path]
        providerLog = attachLog(proc, name: "cli-proxy.log")
        proc.terminationHandler = { [weak self] _ in self?.handleExit(.provider) }
        do {
            try proc.run()
            providerProcess = proc
            providerStartedAt = Date()
            DispatchQueue.main.async { self.providerRunning = true }
        } catch {
            setError("Failed to start cli-proxy-api: \(error.localizedDescription)")
        }
    }

    private func startRouter() {
        guard routerProcess == nil else { return }
        guard let bin = AppPaths.routerBinary else {
            setError("vibeshare-router binary not found in bundle"); return
        }
        makeExecutable(bin)
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = [
            "-store", AppPaths.stateDir.path,
            "-parent-pid", String(ProcessInfo.processInfo.processIdentifier),
        ]
        routerLog = attachLog(proc, name: "router.log")
        proc.terminationHandler = { [weak self] _ in self?.handleExit(.router) }
        do {
            try proc.run()
            routerProcess = proc
            routerStartedAt = Date()
            DispatchQueue.main.async { self.routerRunning = true }
        } catch {
            setError("Failed to start router: \(error.localizedDescription)")
        }
    }

    private enum Child { case provider, router }

    private func handleExit(_ which: Child) {
        queue.async {
            if self.stopping { return }
            switch which {
            case .provider:
                DispatchQueue.main.async { self.providerRunning = false }
                try? self.providerLog?.close(); self.providerLog = nil
                let ranAWhile = Date().timeIntervalSince(self.providerStartedAt) > 5
                self.providerProcess = nil
                if ranAWhile { self.startProvider() } // crashed after running -> recover
            case .router:
                DispatchQueue.main.async { self.routerRunning = false }
                try? self.routerLog?.close(); self.routerLog = nil
                let ranAWhile = Date().timeIntervalSince(self.routerStartedAt) > 5
                self.routerProcess = nil
                if ranAWhile { self.startRouter() }
            }
        }
    }

    // MARK: Helpers

    private func attachLog(_ proc: Process, name: String) -> FileHandle? {
        let logURL = AppPaths.stateDir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return nil }
        handle.seekToEndOfFile()
        proc.standardOutput = handle
        proc.standardError = handle
        return handle
    }

    private func makeExecutable(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func setError(_ msg: String) {
        NSLog("[VibeShare] %@", msg)
        DispatchQueue.main.async { self.lastError = msg }
    }
}
