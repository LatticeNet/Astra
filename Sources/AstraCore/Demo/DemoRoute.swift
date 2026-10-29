import Foundation

/// Which demo client a request came from: the PAT client or the session.
public enum DemoIdentity: String, Sendable, Hashable {
    case pat, session
}

/// A request as a demo route sees it.
public struct DemoRequest: Sendable {
    public var identity: DemoIdentity
    public var method: String
    /// The path without the query, starting with "/api".
    public var path: String
    public var segments: [String]
    public var query: [String: String]
    public var body: Data?
    /// The scenario the transport serves, so a route can answer its Quiet
    /// or Limited token variant without a second route.
    public var scenario: DemoScenario = .normal
    /// The `-AstraDemoToken` override, if any.
    public var token: DemoToken?

    /// The scopes `/api/me` reports for this request's caller.
    public var scopes: ScopeSet {
        DemoTransport.scopes(for: identity, scenario: scenario, token: token)
    }

    public init(identity: DemoIdentity, method: String, path: String, query: [String: String] = [:], body: Data? = nil) {
        self.identity = identity
        self.method = method.uppercased()
        self.path = path
        self.segments = path.split(separator: "/").map(String.init)
        self.query = query
        self.body = body
    }

    /// The decoded JSON body when it is an object.
    public func bodyObject() -> [String: Any]? {
        guard let body, !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    /// Top-level string (and boolean or number, as text) values of the body,
    /// the part `bodyMatch` compares.
    public var bodyStrings: [String: String] {
        guard let object = bodyObject() else { return [:] }
        var values: [String: String] = [:]
        for (key, value) in object {
            switch value {
            case let text as String: values[key] = text
            case let number as NSNumber: values[key] = number.stringValue
            default: break
            }
        }
        return values
    }
}

/// What a demo route answers.
public struct DemoResponse: Sendable {
    public var status: Int
    /// JSON text; time tokens such as `{{now-12s}}` are substituted at serve time.
    public var body: String
    /// Extra response headers, such as the session cookie of a sign-in.
    public var headers: [String: String] = [:]

    public init(status: Int = 200, body: String) {
        self.status = status
        self.body = body
    }

    public init(status: Int = 200, body: String, headers: [String: String]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    public static func json(_ body: String) -> DemoResponse {
        DemoResponse(status: 200, body: body)
    }

    /// The server's error envelope.
    public static func error(status: Int, code: String, message: String) -> DemoResponse {
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return DemoResponse(status: status, body: #"{"error":{"code":"\#(code)","message":"\#(escaped)","request_id":"req_demo"}}"#)
    }
}

/// One fixture route (section 8.6). Matching is by method, then
/// `pathPattern` (segments may be `*`), then the required `query` items (a
/// subset match), then `bodyMatch`; the most specific route wins.
public struct DemoRoute: Sendable {
    public var method: String
    public var pathPattern: String
    public var query: [String: String]
    public var bodyMatch: [String: String]
    public var status: Int
    /// JSON shaped exactly like the server response, as a raw string literal.
    public var body: String
    /// Served by the Empty scenario; GET routes with an object body must set it.
    public var emptyBody: String?
    /// For routes that depend on session state (writes, reads after a write).
    public var respond: (@Sendable (DemoRequest, DemoState) async -> DemoResponse)?
    /// The scope the server's route wrapper requires; a demo identity
    /// without it is answered 403, as the server would.
    public var requiredScope: String?

    public init(
        method: String = "GET",
        pathPattern: String,
        query: [String: String] = [:],
        bodyMatch: [String: String] = [:],
        status: Int = 200,
        body: String = "",
        emptyBody: String? = nil,
        respond: (@Sendable (DemoRequest, DemoState) async -> DemoResponse)? = nil
    ) {
        self.method = method.uppercased()
        self.pathPattern = pathPattern
        self.query = query
        self.bodyMatch = bodyMatch
        self.status = status
        self.body = body
        self.emptyBody = emptyBody
        self.respond = respond
    }

    /// This route, answered 403 for an identity that lacks `scope`.
    public func requiring(_ scope: String) -> DemoRoute {
        var route = self
        route.requiredScope = scope
        return route
    }

    /// The uniqueness key `DemoChecks` asserts has no duplicates.
    public var uniquenessKey: String {
        let query = self.query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let body = bodyMatch.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return "\(method) \(pathPattern) ?\(query) #\(body)"
    }

    /// Nil when the route does not match; otherwise how specific the match is.
    public func specificity(for request: DemoRequest) -> Int? {
        guard method == request.method else { return nil }
        let pattern = pathPattern.split(separator: "/").map(String.init)
        guard pattern.count == request.segments.count else { return nil }
        var score = 0
        for (expected, actual) in zip(pattern, request.segments) {
            if expected == "*" { continue }
            guard expected == actual else { return nil }
            score += 1
        }
        for (name, value) in query {
            guard request.query[name] == value else { return nil }
            score += 1
        }
        if !bodyMatch.isEmpty {
            let body = request.bodyStrings
            for (name, value) in bodyMatch {
                guard body[name] == value else { return nil }
                score += 1
            }
        }
        return score
    }
}
