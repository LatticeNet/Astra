import AppIntents
import Foundation

/// Opens a node's detail screen (M14). It sends the same `LatticeDeepLink`
/// that `lattice://nodes/{id}` parses to, through `DeepLinkRouter`, so the
/// intent lands exactly where the link does: Fleet tab, NodeDetail, Overview.
struct OpenNodeIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Node"
    static let description = IntentDescription(
        "Opens the node's detail screen in Lattice.",
        categoryName: "Navigation",
        searchKeywords: ["server", "host", "fleet"]
    )
    static let supportedModes: IntentModes = .foreground
    // Node names are fleet data; nothing is spoken or listed until the device is unlocked.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Node", requestValueDialog: "Which node?")
    var target: IntentsNodeEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    init() {}

    init(target: IntentsNodeEntity) {
        self.target = target
    }

    /// The link this intent routes, identical to `lattice://nodes/{id}`.
    static func link(for node: IntentsNodeEntity) -> LatticeDeepLink {
        .node(id: node.id, view: nil)
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // On a cold launch DeepLinkRouter holds the link until the shell restores.
        AppServices.shared.deepLinks.handle(Self.link(for: target))
        return .result()
    }
}

/// A node as Shortcuts and Siri see it: its id, its name and its honesty word.
struct IntentsNodeEntity: AppEntity, Identifiable, Hashable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Node", numericFormat: "\(placeholder: .int) nodes")
    static let defaultQuery = IntentsNodeQuery()

    let id: String
    let name: String
    /// The honesty word ("online", "never reported"), or why the node is not known.
    let status: String?
    let symbol: String
    let region: String?

    var displayRepresentation: DisplayRepresentation {
        let subtitle = [status, region].compactMap { $0 }.joined(separator: ", ")
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: subtitle.isEmpty ? nil : "\(subtitle)",
            image: DisplayRepresentation.Image(systemName: symbol)
        )
    }

    init(node: LatticeNode) {
        let style = StatusStyle.node(node.honesty)
        id = node.id
        name = node.displayName
        status = style.word
        symbol = style.symbol
        let place = [node.geo?.city, node.geo?.region].compactMap { $0 }.first { !$0.isEmpty }
        region = place
    }

    /// A node the picker cannot describe: locked, not loaded, removed, or
    /// outside this token's allowlist. `note` says which one is known to be
    /// true. NodeDetail then shows the server's answer for the id.
    init(unknownID id: String, note: String) {
        self.id = id
        name = id
        status = note
        symbol = "server.rack"
        region = nil
    }
}

/// Reads nodes from `NodeDirectory`, the app's shared node list.
struct IntentsNodeQuery: EntityStringQuery {
    /// Matches the directory's own refresh window.
    private static let window: TimeInterval = 15

    /// Saved shortcuts resolve without throwing, so they still run; the screen
    /// they open shows the lock or the server's answer.
    func entities(for identifiers: [IntentsNodeEntity.ID]) async throws -> [IntentsNodeEntity] {
        let nodes: [String: LatticeNode]
        do {
            nodes = try await Self.directory()
        } catch {
            let note = switch error {
            case .locked: "Lattice is locked"
            case .notConnected: "not connected"
            case .hidden: "not visible to this token"
            default: "node list not loaded"
            }
            return identifiers.map { IntentsNodeEntity(unknownID: $0, note: note) }
        }
        return identifiers.map { id in
            nodes[id].map(IntentsNodeEntity.init(node:)) ?? IntentsNodeEntity(unknownID: id, note: "not in the node list")
        }
    }

    func entities(matching string: String) async throws -> [IntentsNodeEntity] {
        let nodes = try await Self.directory()
        return Self.matching(string, in: Array(nodes.values)).map(IntentsNodeEntity.init(node:))
    }

    func suggestedEntities() async throws -> [IntentsNodeEntity] {
        let nodes = try await Self.directory()
        return Self.ordered(Array(nodes.values)).map(IntentsNodeEntity.init(node:))
    }

    /// A node list no older than the refresh window, or the reason there is
    /// none. Rows from a failed refresh are never listed, because their status
    /// words could claim a health that no longer holds.
    @MainActor
    private static func directory() async throws(IntentsQueryError) -> [String: LatticeNode] {
        _ = try IntentsGate.client()
        let directory = AppServices.shared.nodes
        await directory.refreshIfOlder(than: window)
        if let loadedAt = directory.loadedAt, Date().timeIntervalSince(loadedAt) < window {
            return directory.nodes
        }
        guard let error = directory.lastError else { throw IntentsQueryError.notConnected }
        throw IntentsQueryError(error, what: "nodes", scope: "node:read")
    }

    /// Worst state first, then by name, the order Fleet's node list groups by.
    private static func ordered(_ nodes: [LatticeNode]) -> [LatticeNode] {
        nodes.sorted {
            let left = $0.honesty.severityRank, right = $1.honesty.severityRank
            if left != right { return left < right }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    /// Every word must appear in the name, id, tags, role or the place the
    /// row shows, so "fra 2", "relay fra two" and "Frankfurt" all work. Only
    /// when no node matches there does the search widen to the rest of what
    /// Fleet's bare search reads (addresses, host facts), so a digit inside an
    /// IP address does not crowd a spoken name.
    private static func matching(_ text: String, in nodes: [LatticeNode]) -> [LatticeNode] {
        let query = IntentsMatch.words(text)
        guard !query.isEmpty else { return ordered(nodes) }
        let named = nodes.filter { node in
            let haystack = [node.displayName, node.id, node.role, node.geo?.city, node.geo?.region, node.geo?.country]
                .compactMap { $0 } + node.tags
            return IntentsMatch.matches(query, in: haystack)
        }
        if !named.isEmpty { return ordered(named) }
        return ordered(nodes.filter { IntentsMatch.matches(query, in: FleetNodeQuery.text(FleetNodeRecord(node: $0))) })
    }
}
