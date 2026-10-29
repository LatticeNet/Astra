import Foundation

/// Serves `DemoFixtures.all` in place of the network (section 8.6). Writes
/// and reveals go through the real flows; routes with `respond` apply their
/// change to the shared `DemoState`. Unmatched requests answer 404 with the
/// server's envelope, so a missing fixture looks like a missing endpoint,
/// never like an empty list.
public struct DemoTransport: HTTPTransport {
    public let identity: DemoIdentity
    public let scenario: DemoScenario
    public let clock: DemoClock
    public let state: DemoState
    public let routes: [DemoRoute]

    public init(
        identity: DemoIdentity,
        scenario: DemoScenario = .normal,
        clock: DemoClock = DemoClock(),
        state: DemoState = DemoState(),
        routes: [DemoRoute] = DemoFixtures.all
    ) {
        self.identity = identity
        self.scenario = scenario
        self.clock = clock
        self.state = state
        self.routes = routes
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let demoRequest = Self.demoRequest(from: request, identity: identity)
        if !clock.isPinned {
            try await Task.sleep(for: .milliseconds(Int.random(in: 80...300)))
        }
        let response = try await answer(demoRequest)
        let body = Data(clock.substitute(response.body).utf8)
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        return (body, http ?? URLResponse(url: url, mimeType: "application/json", expectedContentLength: body.count, textEncodingName: "utf-8"))
    }

    /// The route answer for a request, after the scenario's overrides.
    public func answer(_ request: DemoRequest) async throws -> DemoResponse {
        // M0a: implement every scenario of section 8.6 (Quiet, Stale, Limited
        // token and No session are not yet applied here).
        switch scenario {
        case .offline:
            throw URLError(.notConnectedToInternet)
        case .failing(let prefix) where Self.matches(request.path, prefix: prefix, defaults: ["/api/incidents", "/api/tasks"]):
            return .error(status: 503, code: "unavailable", message: "service unavailable")
        default:
            break
        }
        guard let route = bestRoute(for: request) else {
            return .error(status: 404, code: "not_found", message: "not found")
        }
        if case .empty = scenario, request.method == "GET" {
            return DemoResponse(status: route.status, body: route.emptyBody ?? "[]")
        }
        if let respond = route.respond {
            return await respond(request, state)
        }
        return DemoResponse(status: route.status, body: route.body)
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

    static func demoRequest(from request: URLRequest, identity: DemoIdentity) -> DemoRequest {
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }
        return DemoRequest(
            identity: identity,
            method: request.httpMethod ?? "GET",
            path: components?.path ?? "/",
            query: query,
            body: request.httpBody
        )
    }

    private static func matches(_ path: String, prefix: String?, defaults: [String]) -> Bool {
        let prefixes = prefix.map { [$0] } ?? defaults
        return prefixes.contains { path.hasPrefix($0) }
    }
}
