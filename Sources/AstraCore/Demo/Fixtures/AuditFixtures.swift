import Foundation

/// Demo routes for the Audit domain, owned by the Audit module (section 8.6):
/// the chain verification of an anchored WAL whose head matches its anchor.
public enum AuditFixtures {
    /// An invented head: the SHA-256 of a fixed phrase, never a real chain.
    public static let head = PlanHasher.sha256Hex("lattice demo audit wal head")
    public static let verifiedCount = 5_760

    public static let routes: [DemoRoute] = [
        DemoRoute(pathPattern: "/api/audit/verify", body: verifyBody, emptyBody: #"{"enabled":false}"#).requiring("audit:read"),
    ]

    static var verifyBody: String {
        DemoJSON.object([
            ("enabled", true),
            ("ok", true),
            ("count", .number(Double(verifiedCount))),
            ("head", .string(head)),
            ("anchored", true),
            ("anchor_count", .number(Double(verifiedCount))),
            ("anchor_head", .string(head)),
        ]).text
    }
}
