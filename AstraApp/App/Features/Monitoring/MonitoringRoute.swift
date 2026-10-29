import SwiftUI

/// M3 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M3 may add cases but must not rename or remove these.
enum MonitoringRoute: Hashable, Codable, Sendable {
    case path(key: String)
    case matrix
    case chain(id: String)
    case check(id: String)
    case checkResults(id: String)
    case definition(id: String)
    case incident(id: String)
    case maintenanceWindow(id: String)
    /// Paths filtered by a query, pushed from a matrix header (M3-03).
    case paths(query: String)
    /// One check's cell on a pair: a pair several checks measure opens the
    /// row's own check, not whichever cell the server listed first.
    case pathCheck(key: String, monitor: String)

    /// The route for a path row: its pair and the check behind it.
    static func cell(_ item: MonitoringPathItem) -> MonitoringRoute {
        item.path.monitorID.isEmpty ? .path(key: item.key) : .pathCheck(key: item.key, monitor: item.path.monitorID)
    }
}

/// M3's demo intents for `-AstraPresent confirm:<id>` (section 9.2). They
/// name invented fixture objects and run against DemoTransport only.
extension MonitoringRoute: DemoHooks {
    static func demoIntent(_ id: String, session: SessionStore) -> WriteIntent? {
        guard session.isDemo else { return nil }
        var portal = Monitor(id: "mon_http_portal", name: "status portal", typeRaw: "http", target: "https://status.example.org/")
        portal.version = 4
        switch id {
        case "monitoring.pause":
            return MonitoringIntents.setEnabled(portal, enabled: false)
        case "monitoring.pause.stale":
            portal.version = 1
            return MonitoringIntents.setEnabled(portal, enabled: false)
        case "monitoring.delete":
            var bastion = Monitor(id: "mon_tcp_bastion", name: "bastion ssh", typeRaw: "tcp", target: "203.0.113.20:22", enabled: false)
            bastion.version = 3
            return MonitoringIntents.deleteCheck(bastion)
        case "monitoring.definition.delete":
            return MonitoringIntents.deleteDefinition(id: "def_dns_watch", name: "DNS answers")
        case "monitoring.replan":
            return PathDetailScreen.replanIntent(BeaconPlanRequest(nodeID: "n-dns-fra-1", action: .change), nodeName: "dns-fra-1")
        case "monitoring.window.end":
            return MonitoringIntents.endMaintenance(MaintenanceWindow(id: "mw_d01", name: "Home lab rewiring", reason: "Moving the rack; lab nodes go dark",
                                                                      groupIDs: ["g-home-lab"], startsAt: Date().addingTimeInterval(-6 * 86_400), endsAt: Date().addingTimeInterval(7_200)))
        default:
            return nil
        }
    }
}
