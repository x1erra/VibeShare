import Foundation

/// RouterClient is an async wrapper over the router's loopback control API.
struct RouterClient {
    var controlPort: Int = 8799
    private var base: URL { URL(string: "http://127.0.0.1:\(controlPort)")! }

    enum ClientError: LocalizedError {
        case http(Int, String)
        case decoding(String)
        var errorDescription: String? {
            switch self {
            case let .http(code, body): return "Router returned \(code): \(body)"
            case let .decoding(msg): return "Could not read router response: \(msg)"
            }
        }
    }

    // MARK: Reads

    func status() async throws -> RouterStatus {
        try await get("/api/status")
    }
    func grants() async throws -> [GrantView] {
        try await get("/api/grants")
    }
    func connections() async throws -> [ConnectionView] {
        try await get("/api/connections")
    }
    func activity(limit: Int = 50) async throws -> [ActivityEntry] {
        try await get("/api/activity?limit=\(limit)")
    }

    /// Long-lived SSE subscription to /api/events. Calls `onEvent` for every
    /// state-change line the router pushes; returns when the stream ends.
    func subscribeEvents(onEvent: @escaping @Sendable () -> Void) async throws {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(controlPort)/api/events")!)
        req.timeoutInterval = 3600
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ClientError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "events stream")
        }
        for try await line in bytes.lines {
            if line.hasPrefix("data:") { onEvent() }
        }
    }

    // MARK: Writes

    @discardableResult
    func createGrant(label: String, providers: [String], models: [String], tokenLimit: Int) async throws -> GrantView {
        try await send("/api/grants", method: "POST", body: [
            "label": label, "providers": providers, "models": models, "tokenLimit": tokenLimit,
        ])
    }
    func updateGrantLimit(id: String, tokenLimit: Int) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["tokenLimit": tokenLimit])
        _ = try await raw("/api/grants/\(id)", method: "PATCH", body: data)
    }
    func setGrantPaused(id: String, paused: Bool) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["paused": paused])
        _ = try await raw("/api/grants/\(id)", method: "PATCH", body: data)
    }
    func revokeGrant(id: String) async throws {
        _ = try await raw("/api/grants/\(id)", method: "DELETE", body: nil)
    }
    @discardableResult
    func redeem(code: String, label: String) async throws -> ConnectionView {
        try await send("/api/connections", method: "POST", body: [
            "code": code, "label": label,
        ])
    }
    func removeConnection(id: String) async throws {
        _ = try await raw("/api/connections/\(id)", method: "DELETE", body: nil)
    }
    func updateConfig(_ update: RouterConfigUpdate) async throws {
        let data = try JSONEncoder().encode(update)
        _ = try await raw("/api/config", method: "PUT", body: data)
    }
    /// Force an immediate usage refetch for one provider (bypasses the 10-min
    /// cache). The longer timeout covers the provider's own usage endpoint.
    func refreshUsage(provider: String) async throws {
        _ = try await raw("/api/usage/\(provider)/refresh", method: "POST", body: nil, timeout: 25)
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await raw(path, method: "GET", body: nil)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ClientError.decoding(String(describing: error))
        }
    }

    private func send<T: Decodable>(_ path: String, method: String, body: [String: Any]) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        let resp = try await raw(path, method: method, body: data)
        do {
            return try JSONDecoder().decode(T.self, from: resp)
        } catch {
            throw ClientError.decoding(String(describing: error))
        }
    }

    private func raw(_ path: String, method: String, body: Data?, timeout: TimeInterval = 10) async throws -> Data {
        // Relative resolution (not appendingPathComponent) so query strings work.
        guard let url = URL(string: path, relativeTo: base) else {
            throw ClientError.http(0, "bad path \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { return data }
        if http.statusCode >= 400 {
            throw ClientError.http(http.statusCode, errorMessage(from: data))
        }
        return data
    }

    private func errorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = obj["error"] {
            if let text = error as? String { return text }
            if let dict = error as? [String: Any],
               let message = dict["message"] as? String {
                return message
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
