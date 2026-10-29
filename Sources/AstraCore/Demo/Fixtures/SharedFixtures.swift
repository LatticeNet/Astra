import Foundation

/// Demo routes for the Shared domain, owned by M0a (section 8.6). Every body
/// is built from `DemoWorld`, so a node, approval or incident reads the same
/// on every screen. The parts live in `SharedFixtures+<Area>.swift`.
///
/// Session state other modules' routes may read or write, through `DemoState`:
///
/// - `approval.status.<id>` and `approval.by.<id>`: a decision on an approval
///   (`approved`, `rejected`, `dismissed`), which `?id=` and the listing show.
/// - `incident.acked` and `incident.unacked` (sets of ids) and
///   `incident.snooze.<id>` (minutes from the clock's anchor, "0" to end).
/// - `window.<id>`: a maintenance window body upserted this session;
///   `window.deleted` (a set of ids).
/// - `node.disabled` and `node.enabled` (sets of node ids).
public enum SharedFixtures {
    public static var routes: [DemoRoute] {
        identityRoutes + fleetRoutes + approvalRoutes + monitoringRoutes + activityRoutes + networkingRoutes + sessionRoutes
    }

    // MARK: Identity

    static var identityRoutes: [DemoRoute] {
        [
            DemoRoute(pathPattern: "/api/me", body: me(identity: .pat, scenario: .normal).text, emptyBody: me(identity: .pat, scenario: .normal).text) { request, _ in
                .json(me(identity: request.identity, scenario: request.scenario).text)
            },
            DemoRoute(pathPattern: "/api/version", body: version.text, emptyBody: version.text),
            DemoRoute(pathPattern: "/api/health", body: #"{"status":"ok"}"#, emptyBody: #"{"status":"ok"}"#),
            DemoRoute(pathPattern: "/api/plugin-trust", body: pluginTrust.text, emptyBody: #"{"non_official":false,"publishers":[],"allow_unsigned_host_risk":false}"#),
        ]
    }

    /// `/api/me` for a demo identity: the Operator preset on the token
    /// (Triage in Limited token) and `*` on the session.
    static func me(identity: DemoIdentity, scenario: DemoScenario) -> DemoJSON {
        let scopeSet = DemoTransport.scopes(for: identity, scenario: scenario)
        let scopes = scopeSet.scopes
        return .object([
            "actor_id": .string(DemoWorld.actorID),
            "username": .string(DemoWorld.username),
            "token_id": identity == .pat ? "tok_demo0001phone" : "",
            "scopes": .strings(scopes),
            "server_allowlist": .strings(scopeSet.serverAllowlist),
            "csrf_token": identity == .session ? "csrf_demo_notasecret" : "",
            "totp_enabled": true,
            "mfa_required": false,
            "totp_policy_required": true,
        ])
    }

    static let version: DemoJSON = .object([
        "server_version": "alpha-0.9.4a2",
        "server_commit": "4f1c2ab",
        "server_date": "{{now-6d}}",
        "dashboard_ref": "integration@9d3e7b1",
        "dashboard_built": "{{now-6d}}",
    ])

    static let pluginTrust: DemoJSON = .object([
        "non_official": true,
        "publishers": ["example-labs"],
        "allow_unsigned_host_risk": false,
    ])

    // MARK: Helpers

    /// A whole-number query item.
    static func intQuery(_ request: DemoRequest, _ name: String) -> Int? {
        request.query[name].flatMap { Int($0) }
    }

    /// An envelope `{<key>: [...], total, limit, offset}` for one page.
    static func page(_ key: String, _ items: [DemoJSON], limit: Int?, offset: Int?) -> DemoJSON {
        let start = min(offset ?? 0, items.count)
        let end = limit.map { min(start + $0, items.count) } ?? items.count
        return .object([
            (key, .array(Array(items[start..<end]))),
            ("total", .number(Double(items.count))),
            ("limit", .number(Double(limit ?? items.count))),
            ("offset", .number(Double(start))),
        ])
    }
}
