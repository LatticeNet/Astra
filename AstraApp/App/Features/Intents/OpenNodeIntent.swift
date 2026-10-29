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
        await IntentsGate.open(Self.link(for: target))
        return .result()
    }
}

/// A node as Shortcuts and Siri see it: its id, its name and its honesty word.
struct IntentsNodeEntity: AppEntity, Identifiable, Hashable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Node", numericFormat: "\(placeholder: .int) nodes")
    static let defaultQuery = IntentsNodeQuery()

    let id: String
    let name: String
    /// The honesty word ("online", "never reported"), or "not in the node list".
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

    /// A node the directory does not hold (not loaded, removed, or outside this
    /// token's allowlist). NodeDetail then shows the server's answer for the id.
    init(unknownID id: String) {
        self.id = id
        name = id
        status = "not in the node list"
        symbol = "server.rack"
        region = nil
    }
}

/// Reads nodes from `NodeDirectory`, the app's shared node list.
struct IntentsNodeQuery: EntityStringQuery {
    func entities(for identifiers: [IntentsNodeEntity.ID]) async throws -> [IntentsNodeEntity] {
        let nodes = await Self.directory()
        return identifiers.map { id in nodes[id].map(IntentsNodeEntity.init(node:)) ?? IntentsNodeEntity(unknownID: id) }
    }

    func entities(matching string: String) async throws -> [IntentsNodeEntity] {
        let nodes = await Self.directory()
        return Self.matching(string, in: Array(nodes.values)).map(IntentsNodeEntity.init(node:))
    }

    func suggestedEntities() async throws -> [IntentsNodeEntity] {
        let nodes = await Self.directory()
        return Self.ordered(Array(nodes.values)).map(IntentsNodeEntity.init(node:))
    }

    @MainActor
    private static func directory() async -> [String: LatticeNode] {
        let directory = AppServices.shared.nodes
        await directory.refreshIfOlder(than: 15)
        return directory.nodes
    }

    /// Worst state first, then by name, the order Fleet's node list groups by.
    private static func ordered(_ nodes: [LatticeNode]) -> [LatticeNode] {
        nodes.sorted {
            let left = $0.honesty.severityRank, right = $1.honesty.severityRank
            if left != right { return left < right }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    /// Name, id or tag containment, so "tyo" finds every Tokyo edge by name.
    private static func matching(_ text: String, in nodes: [LatticeNode]) -> [LatticeNode] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return ordered(nodes) }
        return ordered(nodes.filter { node in
            node.displayName.localizedStandardContains(needle)
                || node.id.localizedStandardContains(needle)
                || node.tags.contains { $0.localizedStandardContains(needle) }
        })
    }
}
