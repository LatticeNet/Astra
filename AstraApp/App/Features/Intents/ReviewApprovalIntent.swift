import AppIntents
import Foundation

/// Opens the Review sheet for an approval (M14). It only opens: it sends the
/// same `LatticeDeepLink` that `lattice://approvals/{id}` parses to, and the
/// decision stays in Review, where the operator reads the plan, the phone
/// hashes it and Face ID binds the decision to that hash (section 6.1).
/// Nothing here approves, rejects or dismisses.
struct ReviewApprovalIntent: OpenIntent {
    static let title: LocalizedStringResource = "Review Approval"
    static let description = IntentDescription(
        "Opens the approval in Review, where you read its plan before deciding. This action never approves, rejects or dismisses.",
        categoryName: "Navigation",
        searchKeywords: ["plan", "decide", "pending"]
    )
    static let supportedModes: IntentModes = .foreground
    // Pending plans name nodes and actions; nothing is listed until the device is unlocked.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Approval", requestValueDialog: "Which approval?")
    var target: IntentsApprovalEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Review \(\.$target)")
    }

    init() {}

    init(target: IntentsApprovalEntity) {
        self.target = target
    }

    /// The link this intent routes, identical to `lattice://approvals/{id}`.
    static func link(for approval: IntentsApprovalEntity) -> LatticeDeepLink {
        .approval(id: approval.id)
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await IntentsGate.open(Self.link(for: target))
        return .result()
    }
}

/// An approval as Shortcuts and Siri see it. It carries no plan text and no
/// seal: the seal appears only where the phone has hashed the body itself.
struct IntentsApprovalEntity: AppEntity, Identifiable, Hashable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Approval", numericFormat: "\(placeholder: .int) approvals")
    static let defaultQuery = IntentsApprovalQuery()

    let id: String
    let title: String
    let detail: String?
    let symbol: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: detail.map { "\($0)" },
            image: DisplayRepresentation.Image(systemName: symbol)
        )
    }

    /// "Apply the firewall ruleset" with "relay-fra-2, needs you, 4 min ago".
    init(approval: Approval, nodeName: String?) {
        let style = StatusStyle.approval(approval.displayState)
        id = approval.id
        title = ApprovalEvents.title(for: approval)
        var parts: [String] = []
        if let nodeName, !nodeName.isEmpty {
            parts.append(nodeName)
        } else if !approval.targets.isEmpty {
            parts.append(approval.targets.count == 1 ? "1 target" : "\(approval.targets.count) targets")
        }
        parts.append(style.word)
        if let created = approval.createdAt {
            parts.append(RelativeDateFormatter.string(from: created))
        }
        detail = parts.joined(separator: ", ")
        symbol = style.symbol
    }

    /// An approval this token could not load right now (offline, decided and
    /// gone from the pending list, or not visible). Review shows the server's
    /// answer for the id, including "Not found, or not visible to this token".
    init(unknownID id: String) {
        self.id = id
        title = id
        detail = "Not loaded right now"
        symbol = "doc.text.magnifyingglass"
    }
}

/// Suggests the approvals that need a person, newest first; resolves saved
/// ids from that list or by id.
struct IntentsApprovalQuery: EntityStringQuery {
    func entities(for identifiers: [IntentsApprovalEntity.ID]) async throws -> [IntentsApprovalEntity] {
        await Self.resolve(identifiers)
    }

    func entities(matching string: String) async throws -> [IntentsApprovalEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = await Self.pending()
        guard !needle.isEmpty else { return all }
        return all.filter { entity in
            entity.title.localizedStandardContains(needle)
                || (entity.detail?.localizedStandardContains(needle) ?? false)
                || entity.id.localizedStandardContains(needle)
        }
    }

    func suggestedEntities() async throws -> [IntentsApprovalEntity] {
        await Self.pending()
    }

    @MainActor
    private static func pending() async -> [IntentsApprovalEntity] {
        let services = AppServices.shared
        guard let client = services.session.client else { return [] }
        await services.nodes.refreshIfOlder(than: 15)
        guard let approvals = try? await client.listHumanPendingApprovals() else { return [] }
        return approvals
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            .map { entity(for: $0, nodes: services.nodes) }
    }

    @MainActor
    private static func resolve(_ ids: [String]) async -> [IntentsApprovalEntity] {
        let services = AppServices.shared
        guard let client = services.session.client else { return ids.map(IntentsApprovalEntity.init(unknownID:)) }
        await services.nodes.refreshIfOlder(than: 15)
        var resolved: [IntentsApprovalEntity] = []
        for id in ids {
            if let approval = try? await client.fetchApproval(id: id) {
                resolved.append(entity(for: approval, nodes: services.nodes))
            } else {
                resolved.append(IntentsApprovalEntity(unknownID: id))
            }
        }
        return resolved
    }

    @MainActor
    private static func entity(for approval: Approval, nodes: NodeDirectory) -> IntentsApprovalEntity {
        let name: String? = approval.nodeID.isEmpty ? nil : nodes.name(for: approval.nodeID)
        return IntentsApprovalEntity(approval: approval, nodeName: name)
    }
}
