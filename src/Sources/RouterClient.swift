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
    func config() async throws -> RouterConfig {
        try await get("/api/config")
    }

    // MARK: Writes

    @discardableResult
    func createGrant(label: String, providers: [String], models: [String]) async throws -> GrantView {
        try await send("/api/grants", method: "POST", body: [
            "label": label, "providers": providers, "models": models,
        ])
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
    func updateConfig(_ cfg: RouterConfig) async throws {
        let data = try JSONEncoder().encode(cfg)
        _ = try await raw("/api/config", method: "PUT", body: data)
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

    private func raw(_ path: String, method: String, body: Data?) async throws -> Data {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 10
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { return data }
        if http.statusCode >= 400 {
            throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}
