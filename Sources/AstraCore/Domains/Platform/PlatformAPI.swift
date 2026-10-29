import Foundation

// M8 owns the Platform row of section 8.4. Plugin RPC (`callPlugin`) is Shared.
// It also reads `GET /api/plugins/lifecycle`, which section 8.4 assigns to
// nobody: the runtime health the Plugins screen shows lives only there.

/// `POST /api/plugins/lifecycle {id, status}`.
public struct PlatformLifecycleRequest: Encodable, Equatable, Sendable {
    public var id: String
    public var status: String
}

/// `POST /api/storage/bindings/delete {kind, id}`.
public struct PlatformBindingDeleteRequest: Encodable, Equatable, Sendable {
    public var kind: String
    public var id: String
}

/// `POST /api/storage/tokens/revoke {kind, token_id}`.
public struct PlatformTokenRevokeRequest: Encodable, Equatable, Sendable {
    public var kind: String
    public var tokenID: String

    enum CodingKeys: String, CodingKey {
        case kind
        case tokenID = "token_id"
    }
}

/// `POST /api/subscription-shares/{id}/reveal {step_up_grant}`.
public struct PlatformShareRevealRequest: Encodable, Equatable, Sendable {
    public var stepUpGrant: String

    enum CodingKeys: String, CodingKey {
        case stepUpGrant = "step_up_grant"
    }
}

/// The empty object rotate and refresh send.
public struct PlatformEmptyBody: Encodable, Equatable, Sendable {
    public init() {}
}

// Share ids are server-minted and path-safe; URLComponents escapes the rest.

public extension LatticeClient {
    // MARK: Plugins

    /// `GET /api/plugins` (audit:read): every verified, registered plugin.
    func platformPlugins() async throws -> [PlatformPlugin] {
        try await perform([PlatformPlugin].self, path: "/api/plugins")
    }

    /// `GET /api/plugin-contributions` (any signed-in caller): active plugins
    /// with the pages and actions this caller's scopes allow.
    func platformContributions() async throws -> [PlatformPlugin] {
        try await perform([PlatformPlugin].self, path: "/api/plugin-contributions")
    }

    /// `GET /api/plugins/lifecycle` (plugin:admin): status, runtime and digest.
    func platformLifecycle() async throws -> [PlatformInstallation] {
        try await perform([PlatformInstallation].self, path: "/api/plugins/lifecycle")
    }

    /// `POST /api/plugins/lifecycle` (plugin:admin). Activation starts the
    /// runtime and answers 409 when a required dependency is not active.
    func platformSetPluginStatus(id: String, status: String) async throws -> PlatformInstallation {
        try await perform(PlatformInstallation.self, path: "/api/plugins/lifecycle", method: "POST",
                          body: PlatformLifecycleRequest(id: id, status: status))
    }

    /// A page's data through the plugin gateway, kept generic (`PluginView.vue`).
    func platformExtensionData(pluginID: String, source: PlatformViewSource) async throws -> PlatformJSONValue {
        let data = try await callPlugin(id: pluginID, service: source.interface, method: source.method)
        return try PlatformJSONValue.parse(data)
    }

    // MARK: Publishing

    /// `GET /api/publishing/records`: routes of the origins the caller may read.
    func platformPublishingRecords() async throws -> PlatformPublishingList {
        try await perform(PlatformPublishingList.self, path: "/api/publishing/records")
    }

    /// `GET /api/storage/buckets?kind=` (kv:read or static:read).
    func platformBuckets(kind: PlatformStorageKind) async throws -> PlatformBucketList {
        try await perform(PlatformBucketList.self, path: "/api/storage/buckets", query: [URLQueryItem(name: "kind", value: kind.rawValue)])
    }

    /// `GET /api/storage/bindings?kind=` (kv:read or static:read).
    func platformBindings(kind: PlatformStorageKind) async throws -> [PlatformStorageBinding] {
        struct Envelope: Decodable { var bindings: [PlatformStorageBinding]? }
        return try await perform(Envelope.self, path: "/api/storage/bindings", query: [URLQueryItem(name: "kind", value: kind.rawValue)]).bindings ?? []
    }

    /// `GET /api/storage/tokens?kind=` (kv:admin or static:admin).
    func platformStorageTokens(kind: PlatformStorageKind) async throws -> [PlatformStorageToken] {
        struct Envelope: Decodable { var tokens: [PlatformStorageToken]? }
        return try await perform(Envelope.self, path: "/api/storage/tokens", query: [URLQueryItem(name: "kind", value: kind.rawValue)]).tokens ?? []
    }

    /// `POST /api/storage/bindings/delete` (kv:admin or static:admin).
    func platformDeleteBinding(kind: PlatformStorageKind, id: String) async throws {
        try await performVoid(path: "/api/storage/bindings/delete", body: PlatformBindingDeleteRequest(kind: kind.rawValue, id: id))
    }

    /// `POST /api/storage/tokens/revoke` (kv:admin or static:admin). The
    /// server purges the token's cache, so it stops working at once.
    func platformRevokeStorageToken(kind: PlatformStorageKind, tokenID: String) async throws -> PlatformStorageToken {
        try await perform(PlatformStorageToken.self, path: "/api/storage/tokens/revoke", method: "POST",
                          body: PlatformTokenRevokeRequest(kind: kind.rawValue, tokenID: tokenID))
    }

    // MARK: Shares

    /// `GET /api/subscription-shares` (proxy:admin, unconfined).
    func platformShares() async throws -> [PlatformShare] {
        try await perform([PlatformShare].self, path: "/api/subscription-shares")
    }

    /// `POST /api/subscription-shares/{id}/rotate`: a new token; the old URL stops working.
    func platformRotateShare(id: String) async throws -> PlatformShare {
        try await perform(PlatformShare.self, path: "/api/subscription-shares/\(id)/rotate", method: "POST", body: PlatformEmptyBody())
    }

    /// `POST /api/subscription-shares/{id}/refresh`: a provider fetch now (plugin sources only).
    func platformRefreshShare(id: String) async throws -> PlatformShareRefresh {
        try await perform(PlatformShareRefresh.self, path: "/api/subscription-shares/\(id)/refresh", method: "POST", body: PlatformEmptyBody())
    }

    /// `POST /api/subscription-shares/{id}/reveal` on the session, with a step-up grant.
    func platformRevealShare(id: String, grant: StepUpGrant) async throws -> PlatformShareReveal {
        try await perform(PlatformShareReveal.self, path: "/api/subscription-shares/\(id)/reveal", method: "POST",
                          body: PlatformShareRevealRequest(stepUpGrant: grant.grant))
    }

    /// `DELETE /api/subscription-shares/{id}` (204).
    func platformDeleteShare(id: String) async throws {
        try await performVoid(path: "/api/subscription-shares/\(id)", method: "DELETE")
    }

    // MARK: Store

    /// `GET /api/kv?bucket=` (kv:read), values dropped.
    func platformKVKeys(bucket: String) async throws -> [PlatformKVKey] {
        try await perform([PlatformKVKey].self, path: "/api/kv", query: [URLQueryItem(name: "bucket", value: bucket)])
    }

    /// `GET /api/static?bucket=` (static:read), content dropped.
    func platformStaticObjects(bucket: String) async throws -> [PlatformStaticObject] {
        try await perform([PlatformStaticObject].self, path: "/api/static", query: [URLQueryItem(name: "bucket", value: bucket)])
    }

    /// One entry's value, read again from the bucket listing (the server has
    /// no read by key). Nil when the entry is gone.
    func platformStoreValue(kind: PlatformStorageKind, bucket: String, key: String) async throws -> PlatformStoreValue? {
        let path = kind == .kv ? "/api/kv" : "/api/static"
        let data = try await performData(path: path, query: [URLQueryItem(name: "bucket", value: bucket)])
        let parsed: [PlatformStoreValueRow]
        do {
            parsed = try JSONDecoder().decode([PlatformStoreValueRow].self, from: data)
        } catch {
            throw LatticeAPIError.invalidResponse
        }
        guard let row = parsed.first(where: { (kind == .kv ? $0.key : $0.path) == key }) else { return nil }
        let text = kind == .kv ? row.value : row.content
        return PlatformStoreValue(text: text, contentType: row.contentType, size: row.size ?? text.utf8.count)
    }

    // MARK: System

    /// `GET /api/system/health?range=` (scope `*`, unconfined).
    func platformSystemHealth(range: String) async throws -> PlatformSystemHealth {
        try await perform(PlatformSystemHealth.self, path: "/api/system/health", query: [URLQueryItem(name: "range", value: range)])
    }

    /// `GET /api/system/series?owner=&series=&range=&points=` (scope `*`, unconfined).
    func platformSystemSeries(owner: String = "cp", series: [String], range: String, points: Int = 400) async throws -> PlatformMetricsQuery {
        try await perform(PlatformMetricsQuery.self, path: "/api/system/series", query: [
            URLQueryItem(name: "owner", value: owner),
            URLQueryItem(name: "series", value: series.joined(separator: ",")),
            URLQueryItem(name: "range", value: range),
            URLQueryItem(name: "points", value: String(points)),
        ])
    }
}

/// A KV entry or static object with its bytes, decoded only for M8-10.
private struct PlatformStoreValueRow: Decodable {
    var key: String
    var path: String
    var value: String
    var content: String
    var contentType: String
    var size: Int?

    enum CodingKeys: String, CodingKey {
        case key, path, value, content, size
        case contentType = "content_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType) ?? ""
        size = try c.decodeIfPresent(Int.self, forKey: .size)
    }
}
