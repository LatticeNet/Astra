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

    /// An approval the picker cannot describe. `note` says why: locked, not
    /// connected, not found or not visible, or a failed load. Review shows the
    /// server's answer for the id when it opens.
    init(unknownID id: String, note: String) {
        self.id = id
        title = id
        detail = note
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
        let all = try await Self.pending()
        guard !needle.isEmpty else { return all }
        return all.filter { entity in
            entity.title.localizedStandardContains(needle)
                || (entity.detail?.localizedStandardContains(needle) ?? false)
                || entity.id.localizedStandardContains(needle)
        }
    }

    func suggestedEntities() async throws -> [IntentsApprovalEntity] {
        try await Self.pending()
    }

    /// The pending list, or the reason it cannot be read. An empty array means
    /// the server answered that nothing needs a person.
    @MainActor
    private static func pending() async throws(IntentsQueryError) -> [IntentsApprovalEntity] {
        let client = try IntentsGate.client()
        let services = AppServices.shared
        if let scopes = services.session.tokenScopes, approvalsDenied(scopes) {
            throw IntentsQueryError.hidden(what: "approvals", scope: "network:plan")
        }
        // Node names only label the rows, so their refresh runs beside the list.
        let nodes = services.nodes
        async let refresh: Void = nodes.refreshIfOlder(than: 15)
        let approvals: [Approval]
        do {
            approvals = try await client.listHumanPendingApprovals()
        } catch {
            throw IntentsQueryError(error, what: "approvals", scope: "network:plan")
        }
        await refresh
        return approvals
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            .map { entity(for: $0, nodes: nodes) }
    }

    /// Inbox's test: the server hides every approval only when the token can
    /// list no plugin at all.
    private static func approvalsDenied(_ scopes: ScopeSet) -> Bool {
        !scopes.allows("network:plan")
            && ApprovalVisibility.hiddenPlugins(scopes: scopes).count == ApprovalVisibility.knownPlugins.count
    }

    @MainActor
    private static func resolve(_ ids: [String]) async -> [IntentsApprovalEntity] {
        let client: LatticeClient
        do {
            client = try IntentsGate.client()
        } catch {
            let note = if case .locked = error { "Lattice is locked" } else { "Not connected" }
            return ids.map { IntentsApprovalEntity(unknownID: $0, note: note) }
        }
        let nodes = AppServices.shared.nodes
        async let refresh: Void = nodes.refreshIfOlder(than: 15)
        var fetched: [(String, Swift.Result<Approval, LatticeAPIError>)] = []
        for id in ids {
            do {
                fetched.append((id, .success(try await client.fetchApproval(id: id))))
            } catch {
                fetched.append((id, .failure(LatticeAPIError(error))))
            }
        }
        await refresh
        return fetched.map { id, result in
            switch result {
            case .success(let approval):
                return entity(for: approval, nodes: nodes)
            case .failure(.notFound), .failure(.forbidden):
                return IntentsApprovalEntity(unknownID: id, note: "Not found, or not visible to this token")
            case .failure(let error):
                return IntentsApprovalEntity(unknownID: id, note: "Could not load. \(error.errorDescription ?? "Unknown error.")")
            }
        }
    }

    @MainActor
    private static func entity(for approval: Approval, nodes: NodeDirectory) -> IntentsApprovalEntity {
        let name: String? = approval.nodeID.isEmpty ? nil : nodes.name(for: approval.nodeID)
        return IntentsApprovalEntity(approval: approval, nodeName: name)
    }
}
