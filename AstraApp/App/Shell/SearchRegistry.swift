import SwiftUI

/// What a Browse search provider can read.
@MainActor
struct SearchContext {
    let session: SessionStore
    let nodes: NodeDirectory
}

/// One result in Browse search, grouped by `kind`.
struct SearchResult: Identifiable, Hashable, Sendable {
    /// "Nodes", "Incidents": the group heading.
    let kind: String
    let id: String
    let title: String
    var detail: String?
    var style: StatusStyle?
    let target: DirectoryTarget
}

/// A module's contribution to Browse search (section 8.5). Each provider
/// fetches its list once per Browse search session (60 s cache) and filters
/// with `LatticeQuery` on device.
@MainActor
protocol SearchProvider {
    static func results(for query: LatticeQuery, context: SearchContext) async -> [SearchResult]
}

/// Every provider, pre-populated in M0. Modules fill in their own type.
enum SearchRegistry {
    @MainActor static let providers: [any SearchProvider.Type] = [
        InboxSearch.self,
        FleetSearch.self,
        MonitoringSearch.self,
        ActivitySearch.self,
        InventorySearch.self,
        NetworkingSearch.self,
        SSHGuardSearch.self,
        PlatformSearch.self,
        NotifySearch.self,
        EvidenceSearch.self,
        AccountSearch.self,
        TerminalSearch.self,
        VPNSearch.self,
    ]

    /// Runs every provider; results keep the providers' order.
    @MainActor
    static func search(_ query: LatticeQuery, context: SearchContext) async -> [SearchResult] {
        var results: [SearchResult] = []
        for provider in providers {
            if Task.isCancelled { return [] }
            results += await provider.results(for: query, context: context)
        }
        return results
    }
}
