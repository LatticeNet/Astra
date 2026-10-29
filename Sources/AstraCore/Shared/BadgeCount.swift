import Foundation

/// The one badge on Inbox and the app icon (sections 1 and 6.9): human-pending
/// approvals visible to this token, plus open, unacknowledged, unsnoozed,
/// not-held incidents of severity warning or critical.
public enum BadgeCount {
    public static func compute(approvals: [Approval], incidents: [Incident], now: Date = Date()) -> Int {
        let pending = approvals.filter(\.isHumanPending).count
        let urgent = incidents.filter { counts($0, now: now) }.count
        return pending + urgent
    }

    static func counts(_ incident: Incident, now: Date) -> Bool {
        incident.state == "open"
            && !IncidentFilter.isSnoozed(incident, now: now)
            && incident.maintenance.isEmpty
            && (incident.severity == "warning" || incident.severity == "critical")
    }
}
