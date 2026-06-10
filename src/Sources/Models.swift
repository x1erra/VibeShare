import Foundation

// Codable mirrors of the router's control-API JSON. Field names match exactly.

struct RouterStatus: Codable {
    var running: Bool
    var frontPort: Int
    var controlPort: Int
    var identityName: String
    var sharingEnabled: Bool
    var upstream: UpstreamStatus
    var nostr: NostrStatus
    var localModels: [String]?

    struct UpstreamStatus: Codable {
        var url: String
        var reachable: Bool
    }
    struct NostrStatus: Codable {
        var relays: [RelayStatus]
    }
    struct RelayStatus: Codable, Identifiable {
        var url: String
        var connected: Bool
        var id: String { url }
    }

    var models: [String] { localModels ?? [] }
    var connectedRelayCount: Int { nostr.relays.filter { $0.connected }.count }
}

struct GrantView: Codable, Identifiable {
    var id: String
    var label: String
    var code: String
    var providers: [String]
    var models: [String]
    var createdAt: Int64
    var revoked: Bool
    var online: Bool
    var routing: Bool
    var advertisedModels: [String]
    var totalReqs: Int
    var inputTokens: Int
    var outputTokens: Int
    var tokenLimit: Int // 0 = unlimited

    var totalTokens: Int { inputTokens + outputTokens }

    /// Whether this friend has a capped allotment.
    var hasLimit: Bool { tokenLimit > 0 }
    /// Tokens left in the allotment (host side: the host's own tally is the
    /// authoritative meter). Only meaningful when `hasLimit`.
    var remaining: Int { max(0, tokenLimit - totalTokens) }

    // Tolerant decoding: a null or missing field defaults instead of throwing,
    // so create vs. list response shapes can never crash the UI.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        providers = try c.decodeIfPresent([String].self, forKey: .providers) ?? []
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        revoked = try c.decodeIfPresent(Bool.self, forKey: .revoked) ?? false
        online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? false
        routing = try c.decodeIfPresent(Bool.self, forKey: .routing) ?? false
        advertisedModels = try c.decodeIfPresent([String].self, forKey: .advertisedModels) ?? []
        totalReqs = try c.decodeIfPresent(Int.self, forKey: .totalReqs) ?? 0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        tokenLimit = try c.decodeIfPresent(Int.self, forKey: .tokenLimit) ?? 0
    }
}

struct ConnectionView: Codable, Identifiable {
    var id: String
    var label: String
    var redeemedAt: Int64
    var online: Bool
    var routing: Bool
    var hostName: String
    var models: [String]
    var totalReqs: Int
    var inputTokens: Int
    var outputTokens: Int
    var tokenLimit: Int // host-advertised allotment, 0 = unlimited
    var tokensUsed: Int // host-authoritative usage, drives remaining

    var totalTokens: Int { inputTokens + outputTokens }

    /// Whether the host capped this connection's allotment.
    var hasLimit: Bool { tokenLimit > 0 }
    /// Tokens left in your allotment (guest side: uses the host's authoritative
    /// tally, which is what the host actually enforces). Only meaningful when
    /// `hasLimit`.
    var remaining: Int { max(0, tokenLimit - tokensUsed) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        redeemedAt = try c.decodeIfPresent(Int64.self, forKey: .redeemedAt) ?? 0
        online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? false
        routing = try c.decodeIfPresent(Bool.self, forKey: .routing) ?? false
        hostName = try c.decodeIfPresent(String.self, forKey: .hostName) ?? ""
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        totalReqs = try c.decodeIfPresent(Int.self, forKey: .totalReqs) ?? 0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        tokenLimit = try c.decodeIfPresent(Int.self, forKey: .tokenLimit) ?? 0
        tokensUsed = try c.decodeIfPresent(Int.self, forKey: .tokensUsed) ?? 0
    }
}

struct RouterConfig: Codable {
    var frontPort: Int
    var controlPort: Int
    var upstreamUrl: String
    var upstreamApiKey: String
    var nostrRelays: [String]
    var identityName: String
    var enableSharing: Bool
}
