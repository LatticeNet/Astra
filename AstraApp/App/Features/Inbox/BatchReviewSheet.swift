import SwiftUI

/// M1-03 BatchReview (section 6.2): one console event group decided at
/// once. Every approval is loaded by id and hashed; every distinct body is
/// on the sheet; one Face ID decides; each row reports its own outcome.
struct BatchReviewSheet: View {
    let groupKey: String
    let approvalIDs: [String]

    @State private var model: InboxBatchModel
    @Environment(SessionStore.self) private var session
    @Environment(ActionRunner.self) private var runner
    @Environment(ChangeLog.self) private var changes
    @Environment(BannerCenter.self) private var banner
    @Environment(Router.self) private var router
    @Environment(NetworkMonitor.self) private var network
    @Environment(NodeDirectory.self) private var nodeDirectory
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var heightClass
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    init(groupKey: String, approvalIDs: [String]) {
        self.groupKey = groupKey
        self.approvalIDs = approvalIDs
        _model = State(initialValue: InboxBatchModel(groupKey: groupKey, ids: approvalIDs))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    content
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.m)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.isLoaded, heightClass != .compact {
                    DecisionPanel(applyAfterApproval: $model.applyAfterApproval, controls: controls, approve: approve, reject: reject)
                }
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .disabled(model.inFlight)
                }
                if model.isLoaded, !typeSize.isAccessibilitySize || heightClass == .compact, !controls.hidesButtons {
                    InboxDecisionToolbar(applyAfterApproval: model.applyAfterApproval, controls: controls, compactHeight: heightClass == .compact, approve: approve, reject: reject)
                }
            }
            .actionHost(inSheet: true)
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(model.inFlight)
        .task {
            await nodeDirectory.refreshIfOlder(than: 60)
            await model.load(session: session)
            await autoConfirmIfAsked()
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            InboxCard {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Text("Placeholder batch title").font(.title3.weight(.semibold))
                    ForEach(0..<3, id: \.self) { _ in Text("placeholder node row, seal and reason") }
                }
                .redacted(reason: .placeholder)
                .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading the plans")
        case .empty:
            ContentUnavailableView {
                Label("Nothing left to decide in this group", systemImage: "checkmark.circle")
            } description: {
                Text("Its plans were decided, replaced or are no longer visible to this token.")
            } actions: {
                Button("Close") { dismiss() }.buttonStyle(.bordered)
            }
            .padding(.top, Spacing.xxl)
        case .failed(let message):
            ContentUnavailableView {
                Label("Could not load the group", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await model.load(session: session) } }.buttonStyle(.bordered)
            }
            .padding(.top, Spacing.xxl)
        case .loaded:
            loaded
        }
    }

    @ViewBuilder
    private var loaded: some View {
        if let summary = model.summary {
            InboxResultCard(text: summary.text, tone: summary.tone)
        }
        if heightClass == .compact {
            DecisionPanel(applyAfterApproval: $model.applyAfterApproval, controls: controls, inline: true, approve: approve, reject: reject)
        }
        InboxCard {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(model.title)
                    .textRole(.detailHeader)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                let bodies = model.bodies.count
                Text("\(model.rows.count) plans, \(bodies == 1 ? "1 distinct body" : "\(bodies) distinct bodies")")
                    .foregroundStyle(.secondary)
                if let writer = model.writer {
                    Text("Filed by \(writer == ApprovalEvents.systemWriter ? "Lattice" : writer)").textRole(.footnote)
                }
            }
        }
        let offline = offlineNodes
        if !offline.isEmpty {
            InboxCard {
                Label {
                    Text(offline.count == 1
                         ? "\(offline[0]) is offline. Its plan waits until the node reports again."
                         : "\(VerdictBuilder.listed(offline)) are offline. Their plans wait until the nodes report again.")
                        .foregroundStyle(Color.statusWarnText)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.statusFailFill)
                }
            }
        }
        InboxCard(title: "Plans", trailing: excludedNote) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.vertical, Spacing.s) }
                    InboxBatchRowView(row: row, nodeName: nodeName(row), honesty: honesty(row), exclusion: exclusion(row))
                }
            }
        }
        ForEach(model.bodies, id: \.hash) { body in
            InboxCard(title: model.bodies.count == 1 ? "The plan" : "Plan \(PlanSeal.short(body.hash))") {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                        SealLabel(sha256: body.hash, state: body.verified ? .verified : .mismatch, placement: .standalone)
                    }
                    Text("Shared by \(VerdictBuilder.listed(body.approvals.map(nodeName)))")
                        .textRole(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    PlanTextView(text: body.text, wraps: true)
                }
            }
        }
    }

    private var excludedNote: String? {
        let excluded = model.rows.filter { $0.outcome == nil && exclusion($0) != nil }.count
        return excluded == 0 ? nil : "\(excluded) left out"
    }

    // MARK: Decisions

    private var scopes: ScopeSet? { session.tokenScopes }

    private func exclusion(_ row: InboxBatchModel.Row) -> String? {
        if let error = row.loadError { return "Could not load: \(error)" }
        guard let approval = row.approval else { return "Not loaded" }
        return ApprovalsDecisionGate.batchApproveExclusion(approval, scopes: scopes)
    }

    private var approvable: [Approval] {
        model.rows.compactMap { row in exclusion(row) == nil && row.outcome == nil ? row.approval : nil }
    }

    private var rejectable: [Approval] {
        model.rows.compactMap { row in
            guard row.outcome == nil, let approval = row.approval, row.loadError == nil else { return nil }
            return ApprovalsDecisionGate.batchRejectExclusion(approval, scopes: scopes) == nil ? approval : nil
        }
    }

    private var controls: InboxDecisionControls {
        let offline = !network.isSatisfied
        let decided = model.summary != nil
        let approveCount = approvable.count
        let rejectCount = rejectable.count
        var controls = InboxDecisionControls(
            showsToggle: approveCount > 0 && !decided,
            reason: nil,
            canApprove: approveCount > 0 && !offline && !model.inFlight && !decided,
            canReject: rejectCount > 0 && !offline && !model.inFlight && !decided,
            count: approveCount,
            rejectCount: rejectCount,
            rejectTitle: "Reject all",
            inFlight: model.inFlight
        )
        if offline {
            controls.reason = "No connection"
            controls.reasonSymbol = "wifi.slash"
            controls.reasonTone = .warn
        } else if !decided, approveCount == 0, let first = model.rows.compactMap(exclusion).first {
            controls.reason = rejectCount == 0 ? first : "Nothing here can be approved: \(first.prefix(1).lowercased() + first.dropFirst())"
            controls.reasonSymbol = first.hasPrefix("Deciding needs") ? "lock" : "exclamationmark.triangle"
            controls.reasonTone = first.hasPrefix("Deciding needs") ? .quiet : .warn
        }
        if decided {
            controls.canApprove = false
            controls.canReject = false
        }
        return controls
    }

    private func approve() {
        Task { await decide(.approve(queueApply: model.applyAfterApproval), on: approvable) }
    }

    private func reject() {
        Task { await decide(.reject, on: rejectable) }
    }

    private func decide(_ decision: ApprovalsDecision, on approvals: [Approval]) async {
        guard !approvals.isEmpty, let client = session.client, runner.beginDecision() else { return }
        model.inFlight = true
        let flow = DecisionFlow(client: client, authenticator: runner.authenticator, mode: mode, locale: locale)
        let reason = ApprovalsDecisionGate.batchAuthReason(decision, count: approvals.count, title: model.title)
        let result = await flow.decideBatch(decision, on: approvals, actorID: session.primaryIdentity?.actorID ?? "", reason: reason)
        model.inFlight = false
        var haptic: HapticEvent?
        switch result {
        case .cancelled:
            break
        case .authenticationFailed(let message):
            model.summary = (message, .warn)
        case .finished(let rows, let reloaded, let summary):
            model.apply(rows: rows, reloaded: reloaded)
            switch summary {
            case .done(let message, _):
                model.summary = (message, .ok)
                haptic = .batchLanded
            case .partial(_, _, let message):
                model.summary = (message, .warn)
                haptic = .partial
            default:
                model.summary = (summary.message, .fail)
                haptic = .failure
            }
            var kinds: Set<ChangeKind> = []
            for approval in approvals { kinds.formUnion(ApprovalReviewSheet.changeKinds(for: approval)) }
            changes.record(Array(kinds))
            banner.show(BannerMessage(text: summary.message, tone: ApprovalReviewSheet.tone(summary)))
        }
        runner.endDecision(haptic: haptic)
    }

    // MARK: Helpers

    private func nodeName(_ approval: Approval) -> String {
        if approval.plugin == "agentupdate", let name = ApprovalEvents.parseAgentUpdatePlan(approval.plan).nodeName { return name }
        return approval.nodeID.isEmpty ? "global" : nodeDirectory.name(for: approval.nodeID)
    }

    private func nodeName(_ row: InboxBatchModel.Row) -> String {
        row.approval.map(nodeName) ?? row.id
    }

    private func honesty(_ row: InboxBatchModel.Row) -> NodeHonesty? {
        guard let id = row.approval?.nodeID, !id.isEmpty else { return nil }
        return nodeDirectory.nodes[id]?.honesty
    }

    private var offlineNodes: [String] {
        model.rows.compactMap { row in honesty(row) == .offline ? nodeName(row) : nil }
    }

    private func autoConfirmIfAsked() async {
        guard LaunchOverrides.current.autoConfirm, session.isDemo, !InboxReviewModel.autoConfirmed, model.isLoaded, controls.canApprove else { return }
        InboxReviewModel.autoConfirmed = true
        await decide(.approve(queueApply: model.applyAfterApproval), on: approvable)
    }
}

/// One row of a batch: node, honesty, seal, and why it is left out or how it ended.
struct InboxBatchRowView: View {
    let row: InboxBatchModel.Row
    let nodeName: String
    let honesty: NodeHonesty?
    let exclusion: String?

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var glyphWidth: CGFloat = 28

    var body: some View {
        let style = honesty.map(StatusStyle.node) ?? StatusStyle(word: "", symbol: "server.rack", tone: .quiet)
        VStack(alignment: .leading, spacing: Spacing.xs) {
            StatusRow(
                style: style,
                title: nodeName,
                detail: row.outcome == nil ? row.approval?.waiting?.reason.inboxNonEmpty : nil,
                accessibilityPhrase: "\(nodeName)" + (style.word.isEmpty ? "" : ", \(style.word)")
            )
            if let approval = row.approval {
                SealLabel(sha256: approval.planSHA256, state: approval.planHashMatchesServer ? .verified : .mismatch)
                    .padding(.leading, typeSize.isAccessibilitySize ? 0 : glyphWidth + Spacing.m)
                    .sealCustomContent(approval.planSHA256, state: approval.planHashMatchesServer ? .verified : .mismatch)
            }
            if let outcome = outcomeOrExclusion {
                Label {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(outcome.word).fontWeight(.semibold)
                        Text(outcome.text).fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: outcome.symbol)
                }
                .font(.subheadline)
                .foregroundStyle(outcome.tone == .ok ? Color.statusOKText : outcome.tone.word)
                .padding(.leading, typeSize.isAccessibilitySize ? 0 : glyphWidth + Spacing.m)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var outcomeOrExclusion: (word: String, text: String, symbol: String, tone: StatusTone)? {
        switch row.outcome {
        case .done(let message, _)?:
            return ("Done", message, "checkmark.circle.fill", .ok)
        case .refused(.alreadyDecided, let message)?:
            return ("Not recorded", message, "xmark.octagon.fill", .fail)
        case let outcome?:
            return ("Not recorded", outcome.message, "xmark.circle.fill", .fail)
        case nil:
            guard let exclusion else { return nil }
            return ("Left out", exclusion, "minus.circle", .warn)
        }
    }
}

/// BatchReview state. View-owned, never registered.
@MainActor @Observable
final class InboxBatchModel {
    enum State: Equatable {
        case loading, loaded, empty
        case failed(String)
    }

    struct Row: Identifiable {
        let id: String
        var approval: Approval?
        var loadError: String?
        var outcome: WriteOutcome?
    }

    /// One distinct plan body and the approvals that share it.
    struct Body {
        let hash: String
        let text: String
        let verified: Bool
        let approvals: [Approval]
    }

    let groupKey: String
    private var ids: [String]
    private(set) var state: State = .loading
    private(set) var rows: [Row] = []
    private(set) var title = "Plans"
    private(set) var writer: String?
    var applyAfterApproval = true
    var inFlight = false
    var summary: (text: String, tone: StatusTone)?

    init(groupKey: String, ids: [String]) {
        self.groupKey = groupKey
        self.ids = ids
    }

    var isLoaded: Bool { state == .loaded }

    var bodies: [Body] {
        var order: [String] = []
        var groups: [String: [Approval]] = [:]
        for approval in rows.compactMap(\.approval) {
            if groups[approval.planSHA256] == nil { order.append(approval.planSHA256) }
            groups[approval.planSHA256, default: []].append(approval)
        }
        return order.compactMap { hash in
            guard let approvals = groups[hash], let first = approvals.first else { return nil }
            return Body(hash: hash, text: first.plan, verified: first.planHashMatchesServer, approvals: approvals)
        }
    }

    /// Resolves the group's ids when only its key is known (a launch
    /// argument, the palette), then loads every approval by id, at most four
    /// at a time, and hashes each body.
    func load(session: SessionStore) async {
        guard let client = session.client else { return }
        state = .loading
        do {
            if ids.isEmpty {
                let page = try await client.approvalsListPage(query: ApprovalQuery(status: "pending", limit: 100), includePlan: true)
                let events = ApprovalEvents.group(page.approvals.filter(\.isHumanPending))
                let event = events.first { $0.key == groupKey } ?? events.first { $0.plugin == groupKey && $0.approvals.count > 1 }
                ids = event?.approvals.map(\.id) ?? []
            }
        } catch {
            state = .failed(LatticeAPIError(error).localizedDescription)
            return
        }
        guard !ids.isEmpty else {
            state = .empty
            return
        }
        let results = await client.approvalsFetchAll(ids: ids)
        rows = ids.map { id in
            switch results[id] {
            case .success(let approval)?: Row(id: id, approval: approval)
            case .failure(let error)?: Row(id: id, loadError: error == .notFound ? "not found, or not visible to this token" : error.localizedDescription)
            case nil: Row(id: id, loadError: "not loaded")
            }
        }
        let loaded = rows.compactMap(\.approval)
        if let event = ApprovalEvents.group(loaded).first, event.approvals.count == loaded.count {
            title = ApprovalEvents.batchTitle(event)
            writer = event.writer
        } else {
            title = loaded.count == 1 ? "1 plan" : "\(rows.count) plans"
            writer = loaded.first.map(ApprovalEvents.writer)
        }
        state = loaded.isEmpty && rows.allSatisfy({ $0.loadError != nil }) ? .failed(rows.first?.loadError ?? "Could not load") : .loaded
    }

    func apply(rows outcomes: [String: WriteOutcome], reloaded: [String: Approval]) {
        for index in rows.indices {
            let id = rows[index].id
            if let outcome = outcomes[id] { rows[index].outcome = outcome }
            if let approval = reloaded[id] { rows[index].approval = approval }
        }
    }
}
