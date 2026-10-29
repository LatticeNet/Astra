import SwiftUI
import UIKit

/// M1-02 Review: the hash-bound contract of section 6.1. The approval is
/// loaded by id, the body on screen is the exact string hashed, Approve
/// sends that hash, a mismatch turns Approve off, stale rows are
/// inspect-only, Face ID runs before every decision, and the transition is
/// verified after the server answers.
struct ApprovalReviewSheet: View {
    let approvalID: String

    @State private var model: InboxReviewModel
    @State private var position = ScrollPosition()
    @State private var planTop: CGFloat = 0
    @State private var contentOffset: CGFloat = 0
    @State private var staleExitsRequest = 0
    @FocusState private var noteFocused: Bool
    @AccessibilityFocusState private var noteAccessibilityFocused: Bool

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
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    init(approvalID: String) {
        self.approvalID = approvalID
        _model = State(initialValue: InboxReviewModel(targetID: approvalID))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xl) {
                        content
                    }
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.m)
                    .coordinateSpace(.named(Self.contentSpace))
                }
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in contentOffset = offset }
                .onChange(of: staleExitsRequest) {
                    withAnimation { proxy.scrollTo(Self.staleCardID, anchor: .top) }
                }
                .onChange(of: model.dismissing) { _, dismissing in
                    // The note field appears where the operator is looking,
                    // with the keyboard and VoiceOver focus on it.
                    guard dismissing else { return }
                    withAnimation { proxy.scrollTo(Self.dismissCardID, anchor: .center) }
                    noteFocused = true
                    noteAccessibilityFocused = true
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let approval = model.approval, model.load == .loaded, heightClass != .compact {
                    DecisionPanel(
                        applyAfterApproval: $model.applyAfterApproval, controls: controls(approval), approve: approve, reject: reject,
                        showStaleExits: hasStaleExits(approval) ? { staleExitsRequest += 1 } : nil
                    )
                }
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .actionHost(inSheet: true)
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(model.inFlight)
        .task(id: model.targetID) {
            // Step 9 compares the recorded decider with this credential's
            // actor, so decisions wait for `/api/me`.
            if session.primaryIdentity == nil { await session.refreshIdentity() }
            await model.load(session: session)
            await nodeDirectory.refreshIfOlder(than: 60)
            await model.loadSSHGuardDeadline(session: session)
            await autoConfirmIfAsked()
        }
        .announcing(model.notice)
    }

    private nonisolated static let contentSpace = "review.content"
    private nonisolated static let dismissCardID = "review.dismiss"
    private nonisolated static let staleCardID = "review.stale"

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.load {
        case .loading:
            InboxCard {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Text("Placeholder plan title").font(.title3.weight(.semibold))
                    Text("Placeholder detail line for the approval").foregroundStyle(.secondary)
                    Text(String(repeating: "placeholder plan line\n", count: 6)).font(TextRole.code.font)
                }
                .redacted(reason: .placeholder)
                .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading the approval")
        case .notFound:
            ContentUnavailableView {
                Label("Not found, or not visible to this token", systemImage: "questionmark.folder")
            } description: {
                Text("The approval may have been removed, or this token cannot read its plugin.")
            } actions: {
                Button("Token scopes") { router.openSettings([.page(.scopes)]) }
                    .buttonStyle(.bordered)
                Button("Open on web") { router.openOnWeb(.approval(id: model.targetID)) }
            }
            .padding(.top, Spacing.xxl)
        case .companionBehind:
            ContentUnavailableView {
                Label("This app is behind the server", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The approval could not be read, so Approve is off.")
            } actions: {
                Button("Reload") { Task { await model.load(session: session) } }
                    .buttonStyle(.bordered)
                Button("Open on web") { router.openOnWeb(.approval(id: model.targetID)) }
            }
            .padding(.top, Spacing.xxl)
        case .failed(let message):
            ContentUnavailableView {
                Label("Could not load the approval", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await model.load(session: session) } }
                    .buttonStyle(.bordered)
            }
            .padding(.top, Spacing.xxl)
        case .loaded:
            if let approval = model.approval {
                loaded(approval)
            }
        }
    }

    @ViewBuilder
    private func loaded(_ approval: Approval) -> some View {
        if let result = model.result {
            InboxResultCard(text: result.text, tone: result.tone)
        }
        if heightClass == .compact {
            DecisionPanel(applyAfterApproval: $model.applyAfterApproval, controls: controls(approval), inline: true, approve: approve, reject: reject)
        }
        InboxReviewHeader(approval: approval, nodeName: nodeName(approval), openNode: openNode, disabled: model.inFlight)
        // A stale row's ways forward sit right under the header, where
        // Review opens, with the dismiss note beside them.
        if hasStaleExits(approval) {
            staleCard(approval)
                .id(Self.staleCardID)
            if model.dismissing {
                dismissCard(approval)
                    .id(Self.dismissCardID)
            }
        }
        if approval.isSSHGuardConfirm {
            InboxCard {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    if let deadline = model.sshGuardDeadline {
                        Label {
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text("Must be approved and applied before \(TimeDisplay.clock(deadline, mode: mode, locale: locale))")
                                    .font(.headline)
                                if deadline > .now {
                                    Text(timerInterval: Date.now...deadline, countsDown: true)
                                        .font(TextRole.metric.font)
                                        .foregroundStyle(Color.statusWarnText)
                                }
                            }
                        } icon: {
                            Image(systemName: "timer").foregroundStyle(Color.statusWarnFill)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Text("This is the SSH Guard confirm plan, the second decision after arm. Applying it cancels the automatic revert; if it does not apply in time, the node restores its previous SSH configuration by itself.")
                        .textRole(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        InboxCard(title: "Proof") {
            ProofStrip(sha256: approval.planSHA256, state: model.sealState, computed: model.sealState == .mismatch ? approval.planHash : nil)
        }
        if let hashError = model.hashError {
            InboxCard {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Label {
                        Text(hashError).foregroundStyle(Color.statusFailText).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "xmark.seal.fill").foregroundStyle(Color.statusFailFill)
                    }
                    Text("Reject stays available: rejecting a plan you cannot verify is safe.").textRole(.footnote)
                    Button("Reload", systemImage: "arrow.clockwise") { Task { await model.load(session: session) } }
                        .frame(minHeight: Spacing.minimumTarget)
                }
            }
        }
        if let notice = model.notice {
            InboxResultCard(text: notice, tone: .warn)
        }
        if !approval.isStale, model.dismissing {
            dismissCard(approval)
                .id(Self.dismissCardID)
        }
        planCard(approval)
        if let waiting = approval.waiting {
            InboxWaitingCard(waiting: waiting, open: { model.retarget($0) }, disabled: model.inFlight)
        }
    }

    // MARK: Plan

    private func planCard(_ approval: Approval) -> some View {
        let matches = PlanTextView.ranges(of: model.findQuery, in: approval.plan)
        let wraps = model.wraps ?? defaultWraps
        let lines = approval.plan.split(separator: "\n", omittingEmptySubsequences: false).count
        return InboxCard(title: "Plan", trailing: lines == 1 ? "1 line" : "\(lines) lines") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if model.findVisible {
                    InboxFindBar(query: $model.findQuery, count: matches.count, current: model.currentMatch, previous: {
                        model.currentMatch = matches.isEmpty ? 0 : (model.currentMatch - 1 + matches.count) % matches.count
                    }, next: {
                        model.currentMatch = matches.isEmpty ? 0 : (model.currentMatch + 1) % matches.count
                    }, done: {
                        model.findVisible = false
                        model.findQuery = ""
                    })
                }
                if approval.plan.isEmpty {
                    Text("No plan body").foregroundStyle(.secondary)
                } else {
                    PlanTextView(
                        text: approval.plan,
                        wraps: wraps,
                        matches: matches,
                        currentMatch: matches.isEmpty ? nil : min(model.currentMatch, matches.count - 1),
                        onCurrentMatchRect: { rect in
                            position.scrollTo(y: max(0, planTop + rect.minY - 160))
                        }
                    )
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.contentSpace)).minY } action: { planTop = $0 }
                }
            }
        }
    }

    /// Lines soft-wrap by default at accessibility sizes and in compact width.
    private var defaultWraps: Bool {
        typeSize.isAccessibilitySize || widthClass != .regular
    }

    // MARK: Dismiss and replan

    private func dismissCard(_ approval: Approval) -> some View {
        InboxCard(title: "Dismiss") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Dismiss retires a plan that will never apply. The note is kept on the approval and in the audit log.")
                    .textRole(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Why it is dismissed", text: $model.note, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($noteFocused)
                    .accessibilityFocused($noteAccessibilityFocused)
                ViewThatFits(in: .horizontal) {
                    HStack { dismissButtons(approval) }
                    VStack(alignment: .leading) { dismissButtons(approval) }
                }
            }
        }
    }

    @ViewBuilder
    private func dismissButtons(_ approval: Approval) -> some View {
        Button("Dismiss \(ApprovalEvents.nodeLabel(approval))", role: .destructive) {
            Task { await decide(.dismiss(note: model.note)) }
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.destructiveFill)
        .disabled(model.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.inFlight || !network.isSatisfied)
        .frame(minHeight: Spacing.minimumTarget)
        Button("Cancel") { model.dismissing = false }
            .frame(minHeight: Spacing.minimumTarget)
    }

    private func hasStaleExits(_ approval: Approval) -> Bool {
        approval.isStale && (ApprovalsDecisionGate.canReplan(approval) || ApprovalsDecisionGate.canDismiss(approval))
    }

    /// The two exits of a stale row: plan again (P tier) and dismiss (D tier).
    private func staleCard(_ approval: Approval) -> some View {
        let replanMissing = session.missing(ScopeRequirement("node:admin", "network:plan")) ?? []
        let dismissMissing = ApprovalsDecisionGate.missingScopes(approval, scopes: session.tokenScopes)
        let canReplan = ApprovalsDecisionGate.canReplan(approval)
        let canDismiss = ApprovalsDecisionGate.canDismiss(approval)
        return InboxCard(title: "Stale") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(canReplan
                     ? "What this plan would change is no longer what the node runs, so it cannot be approved. File a new plan to review, or dismiss this one."
                     : "This plan can no longer be approved. Dismiss it to retire it.")
                    .textRole(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                if canReplan {
                    Button("Plan the agent update again", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await replan(approval) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!replanMissing.isEmpty || model.inFlight || runner.isBusy || !network.isSatisfied)
                    .frame(minHeight: Spacing.minimumTarget)
                    if !replanMissing.isEmpty {
                        Text("Planning again needs \(replanMissing.joined(separator: ", "))").textRole(.footnote)
                    }
                }
                if canDismiss, !model.dismissing {
                    Button("Dismiss this plan", systemImage: "archivebox", role: .destructive) { model.dismissing = true }
                        .buttonStyle(.bordered)
                        .disabled(!dismissMissing.isEmpty || model.inFlight)
                        .frame(minHeight: Spacing.minimumTarget)
                    if !dismissMissing.isEmpty {
                        Text("Dismissing needs \(dismissMissing.joined(separator: ", "))").textRole(.footnote)
                    }
                }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(role: .close) { dismiss() }
                .disabled(model.inFlight)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if let approval = model.approval {
                    Button("Copy plan", systemImage: "doc.on.doc") { UIPasteboard.general.string = approval.plan }
                    Button("Find in plan", systemImage: "magnifyingglass") { model.findVisible = true }
                    Toggle(isOn: Binding(get: { model.wraps ?? defaultWraps }, set: { model.wraps = $0 })) {
                        Label("Wrap lines", systemImage: "arrow.turn.down.left")
                    }
                }
                Button("Copy link", systemImage: "link") {
                    UIPasteboard.general.string = LatticeDeepLink.approval(id: model.targetID).customURL?.absoluteString
                }
                Button("Open on web", systemImage: "safari") { router.openOnWeb(.approval(id: model.targetID)) }
                if let approval = model.approval, ApprovalsDecisionGate.canDismiss(approval) {
                    let missing = ApprovalsDecisionGate.missingScopes(approval, scopes: session.tokenScopes)
                    Section {
                        Button(role: .destructive) { model.dismissing = true } label: {
                            Label("Dismiss", systemImage: "archivebox")
                            if !missing.isEmpty { Text("Needs \(missing.joined(separator: ", "))") }
                        }
                        .disabled(!missing.isEmpty || model.inFlight)
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .disabled(model.inFlight)
        }
        if let approval = model.approval, model.load == .loaded, !typeSize.isAccessibilitySize || heightClass == .compact {
            let controls = controls(approval)
            if !controls.hidesButtons {
                InboxDecisionToolbar(applyAfterApproval: model.applyAfterApproval, controls: controls, compactHeight: heightClass == .compact, approve: approve, reject: reject)
            }
        }
    }

    // MARK: Decisions

    private func controls(_ approval: Approval) -> InboxDecisionControls {
        let scopes = session.tokenScopes
        let offline = !network.isSatisfied
        let identityLoaded = actorID != nil
        let approveBlock = ApprovalsDecisionGate.approveBlock(approval, hashVerified: model.sealState == .verified, companionBehind: false, scopes: scopes, identityLoaded: identityLoaded)
        let rejectBlock = ApprovalsDecisionGate.rejectBlock(approval, companionBehind: false, scopes: scopes, identityLoaded: identityLoaded)
        let missing = ApprovalsDecisionGate.missingScopes(approval, scopes: scopes)
        var controls = InboxDecisionControls(
            showsToggle: approval.isPending && !approval.isStale && missing.isEmpty && model.sealState == .verified && model.result == nil,
            reason: nil,
            canApprove: approveBlock == nil && !offline && !model.inFlight && model.result == nil,
            canReject: rejectBlock == nil && !offline && !model.inFlight && model.result == nil,
            inFlight: model.inFlight
        )
        let reason = offline ? "No connection" : approveBlock
        if model.result == nil, let reason {
            controls.reason = reason
            switch reason {
            case "Stale: inspect only": (controls.reasonSymbol, controls.reasonTone) = ("clock.badge.exclamationmark", .warn)
            case "Plan does not match its hash": (controls.reasonSymbol, controls.reasonTone) = ("xmark.seal.fill", .fail)
            case "No connection": (controls.reasonSymbol, controls.reasonTone) = ("wifi.slash", .warn)
            case "No longer pending": (controls.reasonSymbol, controls.reasonTone) = (StatusStyle.approval(approval.displayState).symbol, .quiet)
            case "Identity not loaded": (controls.reasonSymbol, controls.reasonTone) = ("person.crop.circle.badge.questionmark", .warn)
            default: (controls.reasonSymbol, controls.reasonTone) = ("lock", .quiet)
            }
            if reason == "No longer pending" {
                controls.reason = "No longer pending: \(StatusStyle.approval(approval.displayState).word)"
            }
        }
        // A read-only token sees the reason and no decision buttons.
        if !missing.isEmpty { controls.canReject = false }
        return controls
    }

    private func approve() {
        Task { await decide(.approve(queueApply: model.applyAfterApproval)) }
    }

    private func reject() {
        Task { await decide(.reject) }
    }

    private func decide(_ decision: ApprovalsDecision) async {
        guard let approval = model.approval, let client = session.client else { return }
        guard runner.beginDecision() else {
            model.notice = "Another action is still running. Try again when it finishes."
            return
        }
        model.begin()
        let flow = DecisionFlow(client: client, authenticator: runner.authenticator, mode: mode, locale: locale)
        let name = nodeName(approval)
        let reason = ApprovalsDecisionGate.authReason(decision, approval: approval, nodeName: name)
        let result = await flow.decide(decision, on: approval, actorID: actorID ?? "", reason: reason)
        let haptic = model.finish(result, decision: decision)
        switch result {
        case .finished(let outcome, _):
            changes.record(Self.changeKinds(for: approval))
            banner.show(BannerMessage(text: Self.bannerText(outcome, decision: decision, approval: approval, node: name), tone: Self.tone(outcome)))
        case .cancelled, .authenticationFailed:
            break
        }
        runner.endDecision(haptic: haptic)
    }

    private func replan(_ approval: Approval) async {
        let node = ObjectRef(kind: "node", id: approval.nodeID, name: nodeName(approval))
        let box = InboxFiledBox()
        let intent = WriteIntent(
            tier: .plan, verb: "Replan the agent update on", object: node, scopes: ["node:admin", "network:plan"],
            consequence: "Files a new agent update plan for \(node.name). Nothing changes on the node until that plan is approved.",
            affected: [node], changes: [.approvals, .agentUpdates],
            perform: { client, _ in
                let filed = try await client.planAgentUpdate(nodeID: node.id, force: false)
                await box.set(filed.id)
                return .done("Filed a new plan for \(node.name)")
            }
        )
        let outcome = await runner.run(intent)
        if case .done = outcome, let id = await box.id {
            model.retarget(id)
        }
    }

    // MARK: Helpers

    /// This credential's actor id, or nil until `/api/me` has answered.
    private var actorID: String? {
        guard let id = session.primaryIdentity?.actorID, !id.isEmpty else { return nil }
        return id
    }

    private func nodeName(_ approval: Approval) -> String {
        if approval.plugin == "agentupdate", let name = ApprovalEvents.parseAgentUpdatePlan(approval.plan).nodeName { return name }
        return approval.nodeID.isEmpty ? "" : nodeDirectory.name(for: approval.nodeID)
    }

    private func openNode(_ id: String) {
        router.dismissPresented {
            router.select(tab: .fleet)
            router.push(.fleet(.node(id: id)))
        }
    }

    /// `-AstraAutoConfirm YES` (demo only) approves once after the first
    /// load, so after-states can be captured without a tap.
    private func autoConfirmIfAsked() async {
        guard LaunchOverrides.current.autoConfirm, session.isDemo, !InboxReviewModel.autoConfirmed,
              let approval = model.approval, model.load == .loaded else { return }
        InboxReviewModel.autoConfirmed = true
        if controls(approval).canApprove { await decide(.approve(queueApply: model.applyAfterApproval)) }
    }

    static func changeKinds(for approval: Approval) -> [ChangeKind] {
        var kinds: [ChangeKind] = [.approvals, .tasks, .audit]
        switch approval.plugin {
        case "sshguard": kinds.append(.sshguard)
        case "agentupdate", "agent.mirrors": kinds.append(.agentUpdates)
        case "nftpolicy": kinds.append(.policies)
        case "selfdns": kinds.append(.dns)
        case "cftunnel": kinds.append(.tunnels)
        case "nft": kinds.append(.netguard)
        default: break
        }
        return kinds
    }

    static func bannerText(_ outcome: WriteOutcome, decision: ApprovalsDecision, approval: Approval, node: String) -> String {
        guard case .done = outcome else { return outcome.message }
        let title = ApprovalEvents.title(for: approval)
        let target = node.isEmpty ? "" : " on \(node)"
        switch decision {
        case .approve: return "Approved: \(title)\(target)"
        case .reject: return "Rejected: \(title)\(target)"
        case .dismiss: return "Dismissed: \(title)\(target)"
        }
    }

    static func tone(_ outcome: WriteOutcome) -> StatusTone {
        switch outcome {
        case .done: .quiet
        case .partial, .unknown: .warn
        case .refused, .filed: .fail
        }
    }
}

/// Holds the id of a plan filed from inside a write's perform closure.
actor InboxFiledBox {
    private(set) var id: String?
    func set(_ id: String) { self.id = id }
}

/// Review state (M1-02). View-owned, never registered.
@MainActor @Observable
final class InboxReviewModel {
    enum Load: Equatable {
        case loading, loaded, notFound, companionBehind
        case failed(String)
    }

    /// Process-wide, so `-AstraAutoConfirm` decides once.
    static var autoConfirmed = false

    private(set) var targetID: String
    private(set) var load: Load = .loading
    private(set) var approval: Approval?
    private(set) var sealState: PlanSealState = .unverified
    private(set) var hashError: String?
    private(set) var inFlight = false
    private(set) var result: (text: String, tone: StatusTone)?
    private(set) var sshGuardDeadline: Date?
    var notice: String?
    var applyAfterApproval = true
    var dismissing = false
    var note = "No longer needed"
    /// Nil follows the default (wrap at accessibility sizes and compact width).
    var wraps: Bool?
    var findVisible = false
    var findQuery = "" { didSet { currentMatch = 0 } }
    var currentMatch = 0

    init(targetID: String) {
        self.targetID = targetID
    }

    /// Section 6.1, steps 1 to 3: load by id, fail closed, hash what is on screen.
    func load(session: SessionStore) async {
        guard let client = session.client else { return }
        if approval == nil { load = .loading }
        do {
            let loaded = try await client.fetchApproval(id: targetID)
            approval = loaded
            bindHash(loaded)
            load = .loaded
        } catch {
            switch LatticeAPIError(error) {
            case .notFound:
                load = .notFound
            case .invalidResponse:
                session.markCompanionBehind("Approval")
                approval = nil
                load = .companionBehind
            case let other:
                if approval == nil { load = .failed(other.localizedDescription) } else { notice = "Could not reload: \(other.localizedDescription)" }
            }
        }
    }

    /// The revert deadline an SSH Guard confirm must beat, when the token can read it.
    func loadSSHGuardDeadline(session: SessionStore) async {
        guard let approval, approval.isSSHGuardConfirm, let client = session.client,
              session.missing(ScopeRequirement("sshguard:read", "network:plan"))?.isEmpty != false,
              let status = try? await client.fetchSSHGuardStatus(nodeID: approval.nodeID) else { return }
        sshGuardDeadline = SSHGuardBoard.revertDeadline(status)
    }

    private func bindHash(_ approval: Approval) {
        do {
            _ = try approval.reviewedPlanSHA256()
            sealState = .verified
            hashError = nil
        } catch {
            sealState = .mismatch
            hashError = (error as? LocalizedError)?.errorDescription ?? "The plan does not match its hash."
        }
    }

    /// Opens another approval in this sheet (a replan, a superseding plan).
    func retarget(_ id: String) {
        guard id != targetID else { return }
        targetID = id
        approval = nil
        load = .loading
        result = nil
        notice = nil
        dismissing = false
        sealState = .unverified
        hashError = nil
    }

    func begin() {
        inFlight = true
        notice = nil
    }

    /// Applies a decision's result and returns the haptic it earns.
    func finish(_ outcome: DecisionFlow.Result, decision: ApprovalsDecision) -> HapticEvent? {
        inFlight = false
        switch outcome {
        case .cancelled:
            return nil
        case .authenticationFailed(let message):
            notice = message
            return nil
        case .finished(let result, let reloaded):
            if let reloaded {
                approval = reloaded
                bindHash(reloaded)
            }
            switch result {
            case .done(let message, _):
                self.result = (message, .ok)
                dismissing = false
                if case .approve = decision { return .approveLanded }
                return .rejectOrDismissLanded
            case .refused(.approvalStale, let message), .refused(.notDismissible, let message), .refused(.notSent, let message), .refused(.validation, let message):
                // Back to the undecided state with the reason; never retried.
                notice = message
                return .failure
            case .refused(_, let message):
                self.result = (message, .fail)
                return .failure
            case .unknown(let message):
                self.result = (message, .warn)
                return .partial
            case .partial(_, _, let message):
                self.result = (message, .warn)
                return .partial
            case .filed:
                return nil
            }
        }
    }
}

// MARK: Pieces

/// An opaque inset-grouped section inside the sheet's one scroll view.
struct InboxCard<Content: View>: View {
    var title: String?
    var trailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: Spacing.s)
                    if let trailing {
                        Text(trailing).textRole(.stamp)
                    }
                }
                .padding(.horizontal, Spacing.xs)
            }
            content
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        }
    }
}

/// The outcome of a decision, or a notice, as the first thing in the sheet.
struct InboxResultCard: View {
    let text: String
    let tone: StatusTone

    var body: some View {
        let symbol = switch tone {
        case .ok: "checkmark.circle.fill"
        case .fail: "xmark.octagon.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .quiet, .accent: "info.circle"
        }
        InboxCard {
            Label {
                Text(text)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tone == .ok ? .primary : (tone.isProblem ? tone.word : .primary))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tone == .ok ? Color.statusOKFill : tone.glyph)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Plugin, action, status, targets, author, age, version and artifact.
struct InboxReviewHeader: View {
    let approval: Approval
    let nodeName: String
    let openNode: (String) -> Void
    /// A decision is in flight: the sheet stays put (section 6.1, step 13).
    var disabled = false
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        let style = StatusStyle.approval(approval.displayState)
        InboxCard {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: ApprovalEvents.pluginSymbol(approval.plugin))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(ApprovalVisibility.displayName(plugin: approval.plugin))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(ApprovalEvents.title(for: approval))
                    .textRole(.detailHeader)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Label {
                    Text(style.word).foregroundStyle(style.tone.word == .secondary ? .secondary : style.tone.word)
                } icon: {
                    StatusGlyph(style: style, font: .body)
                }
                .font(.subheadline.weight(.semibold))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Status, \(style.word)")
                if !approval.reason.isEmpty {
                    Text(approval.reason)
                        .font(.subheadline)
                        .foregroundStyle(approval.isStale ? Color.statusWarnText : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(spacing: 0) {
                    ForEach(targets, id: \.self) { target in
                        Button {
                            openNode(target)
                        } label: {
                            HStack {
                                Text(targets.count == 1 ? "Target" : "Target node")
                                Spacer(minLength: Spacing.s)
                                Text(target == approval.nodeID && !nodeName.isEmpty ? nodeName : target)
                                    .foregroundStyle(Color.accentText)
                                Image(systemName: AppTab.fleet.symbol).font(.footnote).foregroundStyle(.secondary)
                            }
                            .frame(minHeight: Spacing.minimumTarget)
                        }
                        .tint(.primary)
                        .disabled(disabled)
                        .accessibilityHint("Closes the review and opens the node in Fleet")
                    }
                    DetailRow(label: "Filed by", value: approval.actorID == ApprovalEvents.systemWriter ? "Lattice" : (approval.actorID.isEmpty ? "agent" : approval.actorID), copyable: false)
                    if let created = approval.createdAt {
                        DetailRow(label: "Filed", value: RelativeDateFormatter.string(from: created), secondary: TimeDisplay.dateTime(created, mode: mode, locale: locale), copyable: false)
                    }
                    DetailRow(label: "Action", value: ApprovalEvents.rawLabel(approval))
                    if !approval.pluginVersion.isEmpty {
                        DetailRow(label: "Plugin version", value: approval.pluginVersion, monospaced: true)
                    }
                    if !approval.artifactDigest.isEmpty {
                        DetailRow(label: "Artifact", value: approval.artifactDigest, monospaced: true)
                    }
                    DetailRow(label: "Approval", value: approval.id, monospaced: true)
                }
            }
        }
    }

    private var targets: [String] {
        let list = approval.targets.isEmpty ? [approval.nodeID] : approval.targets
        return list.filter { !$0.isEmpty }
    }
}

/// Why an approved plan has not applied (`waiting`).
struct InboxWaitingCard: View {
    let waiting: ApprovalWaiting
    let open: (String) -> Void
    var disabled = false
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        let style = waiting.blocked ? StatusStyle.approval(.waiting) : StatusStyle.approval(.applying)
        InboxCard(title: "Waiting") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Label {
                    Text(waiting.reason)
                        .foregroundStyle(waiting.blocked ? Color.statusWarnText : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    StatusGlyph(style: style, font: .body)
                }
                .accessibilityElement(children: .combine)
                VStack(spacing: 0) {
                    DetailRow(label: "State", value: waiting.blocked ? "blocked, will not proceed by itself" : "moving", copyable: false)
                    if !waiting.nodeStatus.isEmpty {
                        DetailRow(label: "Node", value: "\(waiting.nodeName.isEmpty ? waiting.nodeID : waiting.nodeName), \(waiting.nodeStatus)", secondary: waiting.nodeStatusSince.map { "since \(TimeDisplay.dateTime($0, mode: mode, locale: locale))" }, copyable: false)
                    }
                    if !waiting.taskID.isEmpty {
                        DetailRow(label: "Task", value: "\(waiting.taskID), \(waiting.taskStatus)", monospaced: true)
                    }
                    DetailRow(label: "Code", value: waiting.code, monospaced: true)
                }
                if !waiting.supersededBy.isEmpty {
                    Button {
                        open(waiting.supersededBy)
                    } label: {
                        Label("Open the newer plan, \(waiting.supersededBy)", systemImage: "arrow.uturn.right.circle")
                    }
                    .disabled(disabled)
                    .frame(minHeight: Spacing.minimumTarget)
                }
            }
        }
    }
}

/// Find in plan: a field, the match count and previous and next.
struct InboxFindBar: View {
    @Binding var query: String
    let count: Int
    let current: Int
    let previous: () -> Void
    let next: () -> Void
    let done: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.s) { field; counter; buttons }
            VStack(alignment: .leading, spacing: Spacing.s) {
                field
                HStack(spacing: Spacing.s) { counter; Spacer(); buttons }
            }
        }
        .onAppear { focused = true }
    }

    private var field: some View {
        TextField("Find in plan", text: $query)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .focused($focused)
            .onSubmit(next)
    }

    private var counter: some View {
        Text(query.isEmpty ? "" : (count == 0 ? "No matches" : "\(min(current, count - 1) + 1) of \(count)"))
            .textRole(.stamp)
            .accessibilityLabel(count == 0 ? "No matches" : "Match \(min(current, count - 1) + 1) of \(count)")
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Previous match", systemImage: "chevron.up", action: previous)
            .labelStyle(.iconOnly)
            .frame(minWidth: Spacing.minimumTarget, minHeight: Spacing.minimumTarget)
            .disabled(count < 2)
        Button("Next match", systemImage: "chevron.down", action: next)
            .labelStyle(.iconOnly)
            .frame(minWidth: Spacing.minimumTarget, minHeight: Spacing.minimumTarget)
            .disabled(count < 2)
        Button("Done", action: done)
            .frame(minHeight: Spacing.minimumTarget)
    }
}
