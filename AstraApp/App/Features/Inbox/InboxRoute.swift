import SwiftUI

/// M1 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M1 may add cases but must not rename or remove these.
enum InboxRoute: Hashable, Codable, Sendable {
    case allAttention
    case trust
}

/// M1's demo hooks for `-AstraPresent` (section 9.2):
/// `confirm:inbox.ack` acknowledges the degraded-path incident from the
/// root, so the banner, the Undo and a held reorder can be captured.
/// Review and BatchReview open through `review:<id>` and `batch:<group key
/// or plugin>`; `-AstraInboxFilter approvals|incidents|attention` starts
/// Inbox filtered and `-AstraInboxHoldUpdates YES` holds reorders as if
/// VoiceOver were running.
extension InboxRoute: DemoHooks {
    static func demoIntent(_ id: String, session: SessionStore) -> WriteIntent? {
        guard session.isDemo, id == "inbox.ack" else { return nil }
        let incidentID = "inc_d02"
        let title = "Path edge-tyo-1 to relay-fra-1 degraded"
        let object = ObjectRef(kind: "incident", id: incidentID, name: title)
        return WriteIntent(
            tier: .t1, verb: "Acknowledge", object: object, scopes: ["monitor:admin"],
            consequence: "Stops repeat alerts for \(title).",
            inverse: {
                WriteIntent(
                    tier: .t1, verb: "Unacknowledge", object: object, scopes: ["monitor:admin"],
                    consequence: "Repeat alerts for \(title) resume.", idempotent: true, changes: [.incidents],
                    perform: { client, _ in
                        _ = try await client.unacknowledgeIncident(id: incidentID)
                        return .done("Unacknowledged \(title)")
                    }
                )
            },
            idempotent: true, changes: [.incidents],
            perform: { client, _ in
                _ = try await client.acknowledgeIncident(id: incidentID)
                return .done("Acknowledged \(title)")
            }
        )
    }
}
