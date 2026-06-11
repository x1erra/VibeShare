import Foundation
import Combine

/// ProcessManager owns the two long-running Go child processes: the provider
/// engine (cli-proxy-api) and the VibeShare router. It is a singleton so the
/// app-termination hook can stop them cleanly. It restarts a child that dies
/// unexpectedly, and never lets `stopAll` hang on quit.
final class ProcessManager: ObservableObject {
    static let shared = ProcessManager()

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

    /// Kills leftover VibeShare children from a prior run. PID files avoid broad
    /// process-name matching; the command line is still checked before killing in
    /// case the OS reused the PID.
    private func reapStale() {
        reapStale(.router)
        reapStale(.provider)
    }

    func stopAll() {
        queue.sync {
            self.stopping = true
            self.kill(self.routerProcess); self.routerProcess = nil
            try? self.routerLog?.close(); self.routerLog = nil
            self.removePID(.router)
            self.kill(self.providerProcess); self.providerProcess = nil
            try? self.providerLog?.close(); self.providerLog = nil
            self.removePID(.provider)
        }
    }

    /// Full engine restart (e.g. after a relay/port config change, or from the
    /// health banner). Async so the UI never blocks on the 3s kill deadline.
    func restartAll() {
        queue.async {
            self.stopping = true
            self.kill(self.routerProcess); self.routerProcess = nil
            try? self.routerLog?.close(); self.routerLog = nil
            self.removePID(.router)
            self.kill(self.providerProcess); self.providerProcess = nil
            try? self.providerLog?.close(); self.providerLog = nil
            self.removePID(.provider)
            DispatchQueue.main.async {
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
            self.removePID(.router)
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
            writePID(proc.processIdentifier, .provider)
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
            "-control-port", "8799",
            "-parent-pid", String(ProcessInfo.processInfo.processIdentifier),
        ]
        routerLog = attachLog(proc, name: "router.log")
        proc.terminationHandler = { [weak self] _ in self?.handleExit(.router) }
        do {
            try proc.run()
            routerProcess = proc
            routerStartedAt = Date()
            writePID(proc.processIdentifier, .router)
        } catch {
            setError("Failed to start router: \(error.localizedDescription)")
        }
    }

    private enum Child {
        case provider, router

        var pidFileName: String {
            switch self {
            case .provider: return "cli-proxy.pid"
            case .router: return "router.pid"
            }
        }

        var commandMarker: String {
            switch self {
            case .provider: return AppPaths.providerConfigPath().path
            case .router: return "vibeshare-router"
            }
        }
    }

    private func handleExit(_ which: Child) {
        queue.async {
            if self.stopping { return }
            switch which {
            case .provider:
                try? self.providerLog?.close(); self.providerLog = nil
                self.removePID(.provider)
                let ranAWhile = Date().timeIntervalSince(self.providerStartedAt) > 5
                self.providerProcess = nil
                if ranAWhile { self.startProvider() } // crashed after running -> recover
            case .router:
                try? self.routerLog?.close(); self.routerLog = nil
                self.removePID(.router)
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

    private func pidFile(_ child: Child) -> URL {
        AppPaths.stateDir.appendingPathComponent(child.pidFileName)
    }

    private func writePID(_ pid: Int32, _ child: Child) {
        try? String(pid).write(to: pidFile(child), atomically: true, encoding: .utf8)
    }

    private func removePID(_ child: Child) {
        try? FileManager.default.removeItem(at: pidFile(child))
    }

    private func reapStale(_ child: Child) {
        let file = pidFile(child)
        guard let raw = try? String(contentsOf: file, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            removePID(child)
            return
        }
        guard isRunning(pid), commandLine(pid)?.contains(child.commandMarker) == true else {
            removePID(child)
            return
        }
        Foundation.kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(3)
        while isRunning(pid) && Date() < deadline { usleep(50_000) }
        if isRunning(pid) {
            Foundation.kill(pid, SIGKILL)
        }
        removePID(child)
    }

    private func isRunning(_ pid: Int32) -> Bool {
        Foundation.kill(pid, 0) == 0
    }

    private func commandLine(_ pid: Int32) -> String? {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", String(pid), "-o", "command="]
        proc.standardOutput = pipe
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private func setError(_ msg: String) {
        NSLog("[VibeShare] %@", msg)
        DispatchQueue.main.async { self.lastError = msg }
    }
}
