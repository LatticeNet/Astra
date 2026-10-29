import SwiftUI

/// What one node's SSH Guard screen reads: its status row, what the
/// control plane knows about its knock, its capability record and its SSH
/// Guard approvals. View-owned (section 8.1).
@MainActor @Observable
final class SSHGuardNodeModel {
    let nodeID: String
    private(set) var status: ResourceState<SSHGuardNodeStatus> = .idle
    private(set) var knock: ResourceState<SSHGuardKnockState> = .idle
    private(set) var capability: NodeCapabilityEffective?
    private(set) var history: ResourceState<[Approval]> = .idle

    init(nodeID: String) {
        self.nodeID = nodeID
    }

    @discardableResult
    func refresh(session: SessionStore) async -> Bool {
        if let missing = session.missing(SSHGuardStore.readRequirement), !missing.isEmpty {
            status = .denied(scope: missing.joined(separator: " and "))
            return true
        }
        guard let client = session.client else { return false }
        status = status.reloading
        do {
            status = .loaded(try await client.fetchSSHGuardStatus(nodeID: nodeID), at: Date())
        } catch {
            let apiError = LatticeAPIError(error)
            if case .forbidden = apiError { session.noteForbidden() }
            // An undecodable body is the app behind the server; a node this token
            // cannot see is the server's 404, shown as "Not visible to this token".
            if apiError == .invalidResponse { session.markCompanionBehind("SSH Guard") }
            status = status.failing(apiError, surface: "SSH Guard", missingScope: SSHGuardStore.readRequirement.summary)
            return false
        }
        async let knockOK = loadKnock(client)
        async let historyOK = loadHistory(client)
        async let capabilityRead: Void = loadCapability(client, session: session)
        let results = await [knockOK, historyOK]
        await capabilityRead
        return !results.contains(false)
    }

    private func loadKnock(_ client: LatticeClient) async -> Bool {
        knock = knock.reloading
        do {
            knock = .loaded(try await client.sshGuardKnockState(nodeID: nodeID), at: Date())
            return true
        } catch {
            knock = knock.failing(LatticeAPIError(error), surface: "Knock state", missingScope: SSHGuardStore.readRequirement.summary)
            return false
        }
    }

    private func loadHistory(_ client: LatticeClient) async -> Bool {
        history = history.reloading
        do {
            let rows = try await client.listApprovals(includeDismissed: true, nodeID: nodeID, plugin: "sshguard", limit: 20)
            history = .loaded(rows.sorted { ($0.updatedAt ?? $0.createdAt ?? .distantPast) > ($1.updatedAt ?? $1.createdAt ?? .distantPast) }, at: Date())
            return true
        } catch {
            history = history.failing(LatticeAPIError(error), surface: "SSH Guard approvals", missingScope: "network:plan")
            return false
        }
    }

    private func loadCapability(_ client: LatticeClient, session: SessionStore) async {
        guard session.missing(ScopeRequirement("node:read"))?.isEmpty ?? true else { return }
        capability = (try? await client.fetchNodeCapabilities(nodeID: nodeID))?.first { $0.capability == "sshguard" }
    }
}

/// M7-02 SSH Guard for one node: posture facts, the knock, history, and the
/// revert countdown with Confirm while the timer runs.
struct SSHGuardNodeScreen: View {
    let nodeID: String

    @State private var model: SSHGuardNodeModel
    @State private var armTarget: SSHGuardArmTarget?
    @State private var excluding = false
    @State private var excludeReason = ""
    /// Bumped at the revert deadline so the screen is derived again.
    @State private var clockTick = 0
    @Environment(BannerCenter.self) private var banner
    @Environment(SessionStore.self) private var session
    @Environment(SSHGuardStore.self) private var store
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(ActionRunner.self) private var runner
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    init(nodeID: String) {
        self.nodeID = nodeID
        _model = State(initialValue: SSHGuardNodeModel(nodeID: nodeID))
    }

    private var name: String {
        if let status = model.status.value, !status.nodeName.isEmpty { return status.nodeName }
        return nodes.name(for: nodeID)
    }

    private var ref: ObjectRef { ObjectRef(kind: "node", id: nodeID, name: name) }

    var body: some View {
        content
            .navigationTitle(name)
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { menu }
            }
            .sheet(item: $armTarget) { target in
                SSHGuardArmSheet(nodeID: target.nodeID, rotate: target.rotate)
            }
            .alert("Exclude \(name) from SSH Guard", isPresented: $excluding) {
                TextField("Reason", text: $excludeReason)
                Button("Cancel", role: .cancel) { excludeReason = "" }
                Button("Continue") {
                    let reason = excludeReason.trimmingCharacters(in: .whitespacesAndNewlines)
                    excludeReason = ""
                    Task { await runner.run(SSHGuardIntents.exclude(ref, reason: reason)) }
                }
                .disabled(excludeReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("New SSH Guard plans for this node are refused until someone enrolls it. Say why, so the next person does not have to guess.")
            }
            .polling(.standard, version: changes.version([.sshguard, .approvals, .nodes])) {
                await nodes.refreshIfOlder(than: 60)
                return await model.refresh(session: session)
            }
            .task(id: model.status.value.flatMap(SSHGuardBoard.revertDeadline)) {
                guard let deadline = model.status.value.flatMap(SSHGuardBoard.revertDeadline), deadline > .now else { return }
                try? await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow + 0.5))
                if !Task.isCancelled { clockTick += 1 }
            }
    }

    private var subtitle: String {
        _ = clockTick
        guard let row = row(now: .now) else { return "" }
        return row.isReverting ? "Confirm needed" : StatusStyle.posture(row.posture).word.capitalizedFirst
    }

    private func row(now: Date) -> SSHGuardBoardRow? {
        model.status.value.map { SSHGuardBoardRow(status: $0, node: nodes.nodes[nodeID], now: now, record: model.capability?.state) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.status {
        case .denied(let scope):
            SSHGuardNeedsScopesView(missing: scope)
        case .failed(.notFound, nil, _):
            WholeScreenState {
                ContentUnavailableView {
                    Label("Not visible to this token", systemImage: "eye.slash")
                } description: {
                    Text("The server shows SSH Guard only for nodes this token holds sshguard:read and network:plan on.")
                } actions: {
                    Button("Open on web") { router.openOnWeb(.sshGuardNode(nodeID: nodeID)) }
                }
            }
        case .idle where !network.isSatisfied:
            SSHGuardOfflineState(noun: "SSH Guard")
        default:
            ResourceView(state: model.status, noun: "SSH Guard", retry: retry) { status in
                list(status)
            }
        }
    }

    private func retry() {
        Task { await model.refresh(session: session) }
    }

    // MARK: List

    private func list(_ status: SSHGuardNodeStatus) -> some View {
        let row = SSHGuardBoardRow(status: status, node: nodes.nodes[nodeID], now: .now, record: model.capability?.state)
        return ScrollViewReader { proxy in
            List {
                if case .failed(let error, _, _) = model.status {
                    ErrorRow(message: "Could not refresh SSH Guard: \(error.localizedDescription)", retry: retry)
                }
                // The revert deadline is the 2am job: it leads, so Confirm is on screen first at every text size.
                if row.isReverting { confirmSection(row) }
                stateSection(row)
                postureSection(status).id("sshd")
                knockSection(row).id("knock")
                coverageSection(row).id("enrollment")
                historySection(status).id("history")
                actionsSection(row).id("actions")
                Section {
                    WebLinkRow(path: .sshGuardNode(nodeID: nodeID))
                } footer: {
                    FreshnessFooter(state: model.status, interval: Polling.standard.interval(lowPower: false))
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await model.refresh(session: session) }
            .modifier(SSHGuardDemoScroll(proxy: proxy, ready: model.knock.value != nil && model.history.value != nil))
        }
    }

    private func stateSection(_ row: SSHGuardBoardRow) -> some View {
        let posture = StatusStyle.posture(row.posture)
        let coverage = StatusStyle.coverage(row.coverage, deadline: row.deadline.map { TimeDisplay.clock($0, mode: mode, locale: locale) })
        return Section {
            StatusRow(style: posture, title: "Posture", detail: nil, reason: row.status.posture.reason.isEmpty ? nil : row.status.posture.reason.capitalizedFirst,
                      accessibilityPhrase: "Posture, \(posture.word)")
            let stage = SSHGuardNodeWords.stage(row)
            let word = SSHGuardRowWords.coverage(row, word: coverage.word)
            // History and a window awaiting the server's word are not failures yet.
            let style = row.stageIsHistory ? StatusStyle(word: word, symbol: "clock.arrow.circlepath", tone: .quiet)
                : row.awaitingRevertReport ? StatusStyle(word: word, symbol: "hourglass", tone: .warn)
                : StatusStyle(word: word, symbol: coverage.symbol, tone: coverage.tone)
            StatusRow(style: style,
                      title: "Coverage", detail: stage,
                      accessibilityPhrase: "Coverage, \(word), \(stage)")
        }
    }

    private func confirmSection(_ row: SSHGuardBoardRow) -> some View {
        let target = SSHGuardConfirmTarget.of(row.status)
        return Section {
            Group {
                if let deadline = row.deadline {
                    SSHGuardCountdown(deadline: deadline, prominent: true)
                } else {
                    Text("The revert timer is armed. Confirm before it runs out.")
                        .foregroundStyle(Color.statusWarnText)
                }
            }
            .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
            // Text only: in a list the label icon takes the fill's tint and
            // vanishes, yet still pushes the title off center.
            Button {
                confirm(row)
            } label: {
                Text(target == .file ? "Confirm" : "Open confirm approval")
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget - 8)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle)
            .tint(Color.accentFill)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            // Opening a waiting approval only presents Review, which gates the decision itself.
            .disabled(target == .file && !store.canPlan)
            .listRowInsets(EdgeInsets(top: Spacing.s, leading: Spacing.l, bottom: Spacing.s, trailing: Spacing.l))
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if let deadline = row.deadline {
                    Text("At \(TimeDisplay.clock(deadline, mode: mode, locale: locale)) the node restores its previous sshd settings and removes the SSH gate by itself.")
                }
                if let reason = store.planBlockReason() {
                    Text(reason)
                } else if case .review = target {
                    Text("A confirm plan is already waiting. It must be approved and applied before the deadline.")
                } else {
                    Text("Files the confirm plan. Open a new SSH connection over the hardened path first: the confirm is the evidence that you still can.")
                }
            }
        }
    }

    @ViewBuilder
    private func postureSection(_ status: SSHGuardNodeStatus) -> some View {
        Section {
            if let sshd = status.sshd {
                DetailRow(label: "Password login", value: sshd.passwordAuthentication ? "On" : "Off", copyable: false)
                DetailRow(label: "Public key login", value: sshd.pubkeyAuthentication ? "On" : "Off", copyable: false)
                DetailRow(label: "Root login", value: sshd.permitRootLogin.isEmpty ? "Not reported" : sshd.permitRootLogin, monospaced: true, copyable: false)
                DetailRow(label: "sshd listens on", value: sshd.ports.isEmpty ? "Not reported" : sshd.ports.map(String.init).joined(separator: ", "), monospaced: true, copyable: false)
                if let observed = sshd.observedAt ?? status.realityCollectedAt {
                    DetailRow(label: "Observed", value: TimeDisplay.relative(observed, now: .now, locale: locale),
                              secondary: TimeDisplay.dateTime(observed, mode: mode, locale: locale), copyable: false)
                }
            } else {
                Label(status.sshdNote.isEmpty ? "This node has not reported its sshd configuration." : status.sshdNote, systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: Spacing.minimumTarget)
            }
            if !status.posture.keyEvidence.isEmpty {
                DetailRow(label: "Key access", value: status.posture.keyEvidence)
            }
        } header: {
            Text("sshd").accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func knockSection(_ row: SSHGuardBoardRow) -> some View {
        Section {
            switch model.knock {
            case .denied(let scope):
                ScopeDeniedRow(scope: scope)
            case .failed(let error, nil, _):
                ErrorRow(message: "Could not read the knock: \(error.localizedDescription)", retry: retry)
            default:
                if let knock = model.knock.value {
                    knockRows(knock)
                } else {
                    LoadingRows(label: "Loading the knock", count: 2)
                }
            }
        } header: {
            Text("Knock").accessibilityAddTraits(.isHeader)
        } footer: {
            if let note = model.knock.value?.note, !note.isEmpty {
                Text(note)
            }
        }
    }

    @ViewBuilder
    private func knockRows(_ knock: SSHGuardKnockState) -> some View {
        let style = StatusStyle(word: SSHGuardKnockWords.word(knock.knowledge), symbol: SSHGuardKnockWords.symbol(knock.knowledge), tone: .quiet)
        let gate = knock.gatePresent.map { $0 ? "gate on the node now" : "no gate on the node" }
        StatusRow(style: style, title: "Sequence", detail: gate,
                  accessibilityPhrase: ["Sequence, \(style.word)", gate].compactMap { $0 }.joined(separator: ", "))
        if let count = knock.portCount {
            DetailRow(label: "Shape", value: "\(count) ports within \(knock.seqTimeoutSec ?? 15) s, opens for \(knock.openFor.isEmpty ? "12h" : knock.openFor)", copyable: false)
        }
        if let port = knock.sshPort {
            DetailRow(label: "SSH port", value: String(port), monospaced: true, copyable: false)
        }
        if let applied = knock.appliedAt {
            DetailRow(label: "Applied", value: TimeDisplay.relative(applied, now: .now, locale: locale),
                      secondary: TimeDisplay.dateTime(applied, mode: mode, locale: locale), copyable: false)
        }
        if knock.previousHonoured {
            Label("Mid-rotation: the previous sequence still opens this node until the confirm applies.", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(Color.statusWarnText)
                .frame(minHeight: Spacing.minimumTarget)
        }
        if !knock.planUnreadable.isEmpty {
            Label("The plan could not be read: \(knock.planUnreadable)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Color.statusWarnText)
        }
        Button {
            Task { await runner.reveal(SSHGuardIntents.knockReveal(ref)) }
        } label: {
            SSHGuardActionLabel(title: "Reveal knock sequence", symbol: "eye", note: revealNote(knock))
        }
        .disabled(!knock.revealable || revealBlocked)
        Button {
            armTarget = SSHGuardArmTarget(nodeID: nodeID, rotate: true)
        } label: {
            SSHGuardActionLabel(title: "Rotate knock sequence", symbol: "arrow.triangle.2.circlepath", note: rotateNote(knock))
        }
        .disabled(!store.canPlan || ["planned", "no_knock"].contains(knock.knowledge))
    }

    private var revealBlocked: Bool {
        guard let missing = session.missing(ScopeRequirement("sshguard:read", "network:plan"), on: .session) else { return false }
        return !missing.isEmpty
    }

    private func revealNote(_ knock: SSHGuardKnockState) -> String {
        if !knock.revealable { return "Nothing to reveal: \(SSHGuardKnockWords.word(knock.knowledge))." }
        if session.revealClient == nil { return "Needs a signed-in session and a fresh authenticator code." }
        if revealBlocked { return "This session lacks sshguard:read or network:plan." }
        return "Needs a fresh authenticator code. The sequence shows once and is not stored."
    }

    private func rotateNote(_ knock: SSHGuardKnockState) -> String {
        if let reason = store.planBlockReason() { return reason }
        switch knock.knowledge {
        case "planned": return SSHGuardRotation.RotateRefusal.planned.sentence
        case "no_knock": return SSHGuardRotation.RotateRefusal.noKnock.sentence
        default: return "Files a plan that draws a new sequence. The current one keeps working until the confirm applies."
        }
    }

    private func coverageSection(_ row: SSHGuardBoardRow) -> some View {
        Section {
            if let capability = model.capability {
                DetailRow(label: "Capability", value: SSHGuardNodeWords.capability(capability), copyable: false)
                if !capability.recordReason.isEmpty {
                    DetailRow(label: "Recorded reason", value: capability.recordReason, copyable: false)
                }
            } else {
                DetailRow(label: "Capability", value: row.status.enrolled ? "Admitted" : "Not admitted", copyable: false)
            }
            DetailRow(label: "Knock gate", value: row.status.knockGate ? "Present on the node" : "Absent", copyable: false)
            NavigationLink(value: AppRoute.fleet(.nodeCapabilities(id: nodeID))) {
                Label("Node capabilities", systemImage: "checklist")
                    .frame(minHeight: Spacing.minimumTarget)
            }
        } header: {
            Text("Enrollment").accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func historySection(_ status: SSHGuardNodeStatus) -> some View {
        Section {
            switch model.history {
            case .denied(let scope):
                ScopeDeniedRow(scope: scope)
            case .failed(let error, nil, _):
                ErrorRow(message: "Could not load the approvals: \(error.localizedDescription)", retry: retry)
            default:
                if let approvals = model.history.value {
                    if approvals.isEmpty {
                        Text("No SSH Guard plan has been filed for this node.")
                            .foregroundStyle(.secondary)
                            .frame(minHeight: Spacing.minimumTarget)
                    }
                    ForEach(approvals) { approval in
                        Button {
                            router.present(.review(.single(approval.id)))
                        } label: {
                            ApprovalRow(approval: approval, nodeName: name)
                        }
                        .tint(.primary)
                    }
                } else {
                    LoadingRows(label: "Loading the approvals", count: 2)
                }
            }
        } header: {
            Text("Arm and confirm history").accessibilityAddTraits(.isHeader)
        } footer: {
            if let arm = status.lastArm {
                Text(SSHGuardNodeWords.lastArm(arm, mode: mode, locale: locale))
            }
        }
    }

    @ViewBuilder
    private func actionsSection(_ row: SSHGuardBoardRow) -> some View {
        Section {
            Button {
                armTarget = SSHGuardArmTarget(nodeID: nodeID, rotate: false)
            } label: {
                SSHGuardActionLabel(title: "Arm SSH Guard", symbol: "lock.shield", note: armNote(row))
            }
            .disabled(!store.canPlan || !row.isArmable)
            Button {
                excluding = true
            } label: {
                SSHGuardActionLabel(title: "Exclude from SSH Guard", symbol: "minus.circle", note: excludeNote(row))
            }
            .disabled(!store.canExclude || row.scope == .excluded)
        } header: {
            Text("Actions").accessibilityAddTraits(.isHeader)
        }
    }

    private func armNote(_ row: SSHGuardBoardRow) -> String {
        if let reason = store.planBlockReason() { return reason }
        if row.scope == .excluded { return "Excluded from SSH Guard: enroll it under node capabilities first." }
        if row.scope == .undecided {
            if model.capability == nil, !(session.missing(ScopeRequirement("node:read"))?.isEmpty ?? true) {
                return "Needs node:read to see whether this node is enrolled for SSH Guard."
            }
            return "Not enrolled for SSH Guard: enroll it under node capabilities first."
        }
        if row.isReverting { return "A revert timer is running. Confirm it, or let it run out, before arming again." }
        if !row.isArmable { return "Already \(StatusStyle.coverage(row.coverage).word). Arm again once nothing is live on the node." }
        return "Hardens sshd and starts a revert timer once approved."
    }

    private func excludeNote(_ row: SSHGuardBoardRow) -> String {
        if !store.canExclude { return "Needs node:admin" }
        if row.scope == .excluded {
            let reason = model.capability?.recordReason ?? ""
            return reason.isEmpty ? "Already excluded." : "Already excluded: \(reason)"
        }
        return "Refuses new SSH Guard plans for this node. Asks for a reason."
    }

    private func confirm(_ row: SSHGuardBoardRow) {
        if row.revertWindowPassed(now: Date()) {
            banner.show(BannerMessage(text: "The revert window passed. Nothing was filed; the node's next report says whether it reverted.", tone: .warn))
            clockTick += 1
            return
        }
        switch SSHGuardConfirmTarget.of(row.status) {
        case .review(let approvalID):
            router.present(.review(.single(approvalID)))
        case .file:
            let clock = row.deadline.map { TimeDisplay.clock($0, mode: mode, locale: locale) }
            Task { await runner.run(SSHGuardIntents.confirm(ref, deadlineText: clock)) }
        }
    }

    private var menu: some View {
        Menu {
            Button("Open on web", systemImage: "safari") { router.openOnWeb(.sshGuardNode(nodeID: nodeID)) }
            Button("Copy link", systemImage: "link") { SSHGuardCopy.copy(SSHGuardCopy.nodeLink(nodeID)) }
            Button("Copy ID", systemImage: "number") { SSHGuardCopy.copy(nodeID) }
            Divider()
            Button("Node details", systemImage: "server.rack") { router.push(.fleet(.node(id: nodeID))) }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }
}

/// An action row with its consequence or its reason for being off.
struct SSHGuardActionLabel: View {
    let title: String
    let symbol: String
    let note: String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title).foregroundStyle(isEnabled ? Color.accentText : Color.secondary)
                Text(note).textRole(.footnote)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(isEnabled ? Color.accentText : Color.secondary)
        }
        .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
    }
}

enum SSHGuardNodeWords {
    static func stage(_ row: SSHGuardBoardRow) -> String {
        if row.stageIsHistory { return "a past attempt; the node is secured anyway" }
        if row.awaitingRevertReport { return "revert window passed, waiting for the node's next report" }
        return stage(row.stage)
    }

    static func stage(_ stage: SSHGuardBoardStage) -> String {
        switch stage {
        case .idle: "no plan yet"
        case .armPending: "arm plan waiting for approval"
        case .armApproved: "arm approved, not applied yet"
        case .armFailed: "last arm did not survive"
        case .awaitingConfirm: "arm applied, no confirm filed"
        case .confirmPending: "confirm plan waiting for approval"
        case .confirmApproved: "confirm approved, applying"
        case .confirmed: "confirmed"
        case .hardened: "hardened without a firewall, nothing to confirm"
        case .reverted: "reverted after the window closed"
        case .inForce: "in force"
        }
    }

    static func capability(_ capability: NodeCapabilityEffective) -> String {
        switch capability.state {
        case "enrolled": "Enrolled"
        case "excluded": "Excluded"
        default: capability.allowed ? "Admitted, no record" : "Not enrolled"
        }
    }

    static func lastArm(_ arm: SSHGuardApprovalRef, mode: TimeZoneMode, locale: Locale) -> String {
        var parts = ["Last arm \(arm.outcome.isEmpty ? arm.status : arm.outcome)"]
        if let at = arm.updatedAt ?? arm.createdAt { parts.append(TimeDisplay.dateTime(at, mode: mode, locale: locale)) }
        if arm.confirmWindowSec > 0 { parts.append("window \(SSHGuardIntents.windowWords(arm.confirmWindowSec))") }
        if arm.knock { parts.append("with knocking") }
        return parts.joined(separator: ", ") + "."
    }
}

extension String {
    /// "Password login open" from "password login open".
    fileprivate var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
