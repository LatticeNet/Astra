import SwiftUI

/// M3's contribution to Browse search (section 8.5): incidents and checks,
/// each list fetched once per search session (60 s) and filtered on device.
enum MonitoringSearch: SearchProvider {
    @MainActor private static var cache: (at: Date, incidents: [Incident], monitors: [Monitor])?

    static func results(for query: LatticeQuery, context: SearchContext) async -> [SearchResult] {
        guard !query.source.trimmingCharacters(in: .whitespaces).isEmpty, let client = context.session.client else { return [] }
        if let missing = context.session.missing(MonitoringStore.readRequirement), !missing.isEmpty { return [] }
        let now = Date()
        if cache == nil || now.timeIntervalSince(cache?.at ?? .distantPast) > 60 {
            async let incidents = try? client.listIncidents()
            async let monitors = try? client.listMonitors()
            cache = (now, await incidents?.incidents ?? [], await monitors ?? [])
        }
        guard let cache else { return [] }
        let incidentRows = cache.incidents.map { MonitoringIncidentItem(incident: $0, now: now) }
        let incidents = MonitoringQuery.filter(incidentRows, query: query.source, provider: MonitoringIncidentQueryFields.self, now: now)
        let checkRows = cache.monitors.map { monitor in
            MonitoringCheckItem(monitor: monitor, health: MonitoringHealth.of(monitor, results: monitor.latest, now: now),
                                nodeNames: monitor.nodeIDs.map { context.nodes.name(for: $0) })
        }
        let checks = MonitoringQuery.filter(checkRows, query: query.source, provider: MonitoringCheckQueryFields.self, now: now)
        var results: [SearchResult] = []
        if incidents.error == nil {
            results += incidents.rows.sorted { IncidentFilter.areInIncreasingOrder($0.incident, $1.incident, now: now) }.map { item in
                SearchResult(kind: "Incidents", id: item.incident.id, title: item.incident.displayTitle, detail: item.incident.nodeName,
                             style: .incident(item.incident.displayState(now: now)), target: .push(.monitoring(.incident(id: item.incident.id))))
            }
        }
        if checks.error == nil {
            results += checks.rows.sorted { $0.health.rank < $1.health.rank }.map { item in
                SearchResult(kind: "Checks", id: item.monitor.id, title: item.monitor.displayName, detail: "\(item.monitor.typeWord), \(item.monitor.target)",
                             style: MonitoringStyle.check(item.health), target: .push(.monitoring(.check(id: item.monitor.id))))
            }
        }
        return results
    }
}
