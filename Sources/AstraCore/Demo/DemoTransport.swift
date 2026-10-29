import Foundation

/// Serves `DemoFixtures.all` in place of the network (section 8.6). Writes
/// and reveals go through the real flows; routes with `respond` apply their
/// change to the shared `DemoState`. Unmatched requests answer 404 with the
/// server's envelope, so a missing fixture looks like a missing endpoint,
/// never like an empty list.
public struct DemoTransport: HTTPTransport {
    public let identity: DemoIdentity
    public let scenario: DemoScenario
    public let token: DemoToken?
    public let clock: DemoClock
    public let state: DemoState
    public let routes: [DemoRoute]

    public init(
        identity: DemoIdentity,
        scenario: DemoScenario = .normal,
        token: DemoToken? = nil,
        clock: DemoClock = DemoClock(),
        state: DemoState = DemoState(),
        routes: [DemoRoute] = DemoFixtures.all
    ) {
        self.identity = identity
        self.scenario = scenario
        self.token = token
        self.clock = clock
        self.state = state
        self.routes = routes
    }

    /// The scopes `/api/me` reports for a demo identity: the Operator preset
    /// on the token (Triage in Limited token, Operator plus root in Root
    /// token, `*` in Full administrator) and `*` on the session. A `token`
    /// override replaces the scenario's choice on the token.
    public static func scopes(for identity: DemoIdentity, scenario: DemoScenario, token: DemoToken? = nil) -> ScopeSet {
        if identity == .session { return ScopeSet(scopes: ["*"]) }
        if let token { return token.scopes }
        return switch scenario {
        case .limitedToken: ScopeSet(scopes: TokenPresets.triage.scopes)
        case .confinedToken: ScopeSet(scopes: TokenPresets.operator.scopes, serverAllowlist: DemoWorld.confinedNodeIDs)
        case .rootToken: ScopeSet(scopes: TokenPresets.operatorPlusRoot.scopes)
        case .fullAdmin: ScopeSet(scopes: ["*"])
        default: ScopeSet(scopes: TokenPresets.operator.scopes)
        }
    }

    public var scopes: ScopeSet { Self.scopes(for: identity, scenario: scenario, token: token) }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let demoRequest = Self.demoRequest(from: request, identity: identity, scenario: scenario)
        if !clock.isPinned {
            try await Task.sleep(for: .milliseconds(Int.random(in: 80...300)))
        }
        let response = try await answer(demoRequest)
        let body = Data(clock.substitute(response.body).utf8)
        var headers = ["Content-Type": "application/json"]
        headers.merge(response.headers) { _, new in new }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers)
        return (body, http ?? URLResponse(url: url, mimeType: "application/json", expectedContentLength: body.count, textEncodingName: "utf-8"))
    }

    /// The route answer for a request, after the scenario's overrides.
    public func answer(_ request: DemoRequest) async throws -> DemoResponse {
        var request = request
        request.scenario = scenario
        request.token = token
        if case .offline = scenario {
            throw URLError(.notConnectedToInternet)
        }
        if case .noSession = scenario, request.identity == .session {
            return .error(status: 401, code: "unauthorized", message: "authentication required")
        }
        if case .failing(let prefix) = scenario, Self.matches(request.path, prefix: prefix, defaults: ["/api/incidents", "/api/tasks"]) {
            return .error(status: 503, code: "unavailable", message: "service unavailable")
        }
        guard let route = bestRoute(for: request) else {
            return .error(status: 404, code: "not_found", message: "not found")
        }
        switch scenario {
        case .stale:
            // The first answer per route lands; every later one times out, so
            // screens keep their data and turn stale.
            if await state.recordHit("stale " + route.uniquenessKey) > 1 { throw URLError(.timedOut) }
        case .forbidden(let prefix):
            if Self.matches(request.path, prefix: prefix, defaults: ["/api/incidents"]),
               await state.recordHit("forbidden " + route.uniquenessKey) > 1 {
                return .error(status: 403, code: "forbidden", message: "forbidden")
            }
        case .companionBehind(let prefix):
            let hit = prefix.map { request.path.hasPrefix($0) }
                ?? (request.path == "/api/network/approvals" && request.query["id"] != nil)
            if hit { return DemoResponse(status: 200, body: "<!doctype html><title>Lattice</title>") }
        default:
            break
        }
        if let scope = route.requiredScope, !scopes.allows(scope) {
            return .error(status: 403, code: "forbidden", message: "missing scope \(scope)")
        }
        let servesEmpty = scenario == .empty && request.method == "GET"
        if servesEmpty, let emptyBody = route.emptyBody {
            return DemoResponse(status: route.status, body: emptyBody)
        }
        let response = if let respond = route.respond {
            await respond(request, state)
        } else {
            DemoResponse(status: route.status, body: route.body)
        }
        if servesEmpty {
            // Array routes such as approvals and tasks answer an envelope for
            // count and filtered queries, so the empty answer keeps the shape
            // the query produced instead of assuming a bare array.
            return DemoResponse(status: response.status, body: Self.emptied(response.body))
        }
        return response
    }

    /// The same JSON shape with no items: every array emptied, `total` and
    /// every number under `counts` set to zero.
    static func emptied(_ body: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else { return "[]" }
        func empty(_ value: Any, key: String?) -> Any {
            switch value {
            case is [Any]: return [Any]()
            case let number as NSNumber where key == "total" && CFGetTypeID(number) != CFBooleanGetTypeID(): return 0
            case let dictionary as [String: Any] where key == "counts": return dictionary.mapValues { $0 is NSNumber ? 0 : $0 }
            case let dictionary as [String: Any] where key == nil:
                return Dictionary(uniqueKeysWithValues: dictionary.map { ($0.key, empty($0.value, key: $0.key)) })
            default: return value
            }
        }
        let emptiedObject = empty(object, key: nil)
        guard let data = try? JSONSerialization.data(withJSONObject: emptiedObject, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }

    /// The most specific matching route.
    public func bestRoute(for request: DemoRequest) -> DemoRoute? {
        var best: (route: DemoRoute, score: Int)?
        for route in routes {
            guard let score = route.specificity(for: request) else { continue }
            if best == nil || score > best!.score {
                best = (route, score)
            }
        }
        return best?.route
    }

    static func demoRequest(from request: URLRequest, identity: DemoIdentity, scenario: DemoScenario = .normal) -> DemoRequest {
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }
        var demoRequest = DemoRequest(
            identity: identity,
            method: request.httpMethod ?? "GET",
            path: components?.path ?? "/",
            query: query,
            body: request.httpBody
        )
        demoRequest.scenario = scenario
        return demoRequest
    }

    private static func matches(_ path: String, prefix: String?, defaults: [String]) -> Bool {
        let prefixes = prefix.map { [$0] } ?? defaults
        return prefixes.contains { path.hasPrefix($0) }
    }
}
