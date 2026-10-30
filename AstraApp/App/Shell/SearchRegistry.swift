import SwiftUI

/// What a Browse search provider can read.
@MainActor
struct SearchContext: Sendable {
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

    /// Runs every provider at once and reports the results gathered so far
    /// each time one returns, so a slow endpoint holds back only its own
    /// group. Every update keeps the providers' order.
    @MainActor
    static func search(_ query: LatticeQuery, context: SearchContext, onUpdate: ([SearchResult]) -> Void) async {
        var found: [Int: [SearchResult]] = [:]
        await withTaskGroup(of: (Int, [SearchResult]).self) { group in
            for index in providers.indices {
                group.addTask { await run(index, query: query, context: context) }
            }
            for await landed in group {
                if Task.isCancelled { return }
                found[landed.0] = landed.1
                onUpdate(providers.indices.flatMap { found[$0] ?? [] })
            }
        }
    }

    @MainActor
    private static func run(_ index: Int, query: LatticeQuery, context: SearchContext) async -> (Int, [SearchResult]) {
        (index, await providers[index].results(for: query, context: context))
    }
}
