import SwiftUI

/// The step container for T3, T4 and plan intents (F-15). At the root it is
/// this sheet; inside another sheet the same content is a `ConfirmPage`.
struct ConfirmSheet: View {
    let pending: PendingConfirm
    @State private var model: ConfirmFlowModel
    @State private var detent: PresentationDetent
    @Environment(\.dynamicTypeSize) private var typeSize

    init(pending: PendingConfirm) {
        self.pending = pending
        let model = ConfirmFlowModel(pending: pending)
        _model = State(initialValue: model)
        _detent = State(initialValue: model.prefersLarge ? .large : .medium)
    }

    var body: some View {
        NavigationStack {
            ConfirmFlowView(model: model)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { model.close() }
                            .disabled(model.isSending)
                    }
                }
        }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large], selection: $detent)
        .presentationDragIndicator(typeSize.isAccessibilitySize ? .hidden : .visible)
        .interactiveDismissDisabled(model.isSending || model.step == .result)
    }
}

/// Where the flow is.
enum ConfirmStep: Equatable {
    case confirm
    /// A plan refused with lint findings; acceptance toggles are now shown.
    case findings([String])
    case result
}

/// Drives one intent through confirm, authenticate, findings and result,
/// around AstraCore `WriteFlow` (which owns the order and proves that a
/// cancelled authentication sends nothing).
@MainActor @Observable
final class ConfirmFlowModel {
    enum DryRun {
        case none
        case loading
        case loaded(DryRunReport)
        case failed(String)
    }

    let pending: PendingConfirm
    private(set) var step: ConfirmStep = .confirm
    private(set) var dryRun: DryRun = .none
    private(set) var isSending = false
    private(set) var notice: String?
    private(set) var outcome: WriteOutcome?
    var accepted: Set<String> = []
    var typedPhrase = ""
    @ObservationIgnored private var finished = false

    init(pending: PendingConfirm) {
        self.pending = pending
        if pending.intent.dryRun != nil { dryRun = .loading }
    }

    var intent: WriteIntent { pending.intent }

    /// Text entry, a dry run or toggles open the sheet at the large detent.
    var prefersLarge: Bool {
        intent.confirmPhrase != nil || intent.dryRun != nil || intent.toggles.contains { !$0.revealedByConflict } || intent.affected.count > 1
    }

    var isShowingFindings: Bool {
        if case .findings = step { return true }
        return false
    }

    /// Toggles shown from the start.
    var standingToggles: [ConfirmToggle] {
        intent.toggles.filter { !$0.revealedByConflict }
    }

    /// Acceptance toggles, shown only once the server returned findings.
    var findingsToggles: [ConfirmToggle] {
        guard case .findings = step else { return [] }
        return intent.toggles.filter(\.revealedByConflict)
    }

    /// Whether the intent can file past the findings. Beacon plans cannot: the
    /// server refuses them while findings block, and has no acceptance flag.
    var findingsAcceptable: Bool {
        intent.toggles.contains(where: \.revealedByConflict)
    }

    /// Findings the operator cannot accept here, so only the web can move on.
    var isStuckOnFindings: Bool {
        guard case .findings = step else { return false }
        return !findingsAcceptable
    }

    /// Where the console edits the object a stuck plan was for.
    var webPath: LatticeConsolePath? {
        switch intent.object.kind {
        case "node": .node(id: intent.object.id, view: .settings)
        default: nil
        }
    }

    /// Why the primary action is off, or nil when it may run.
    func blockReason(online: Bool) -> String? {
        if isStuckOnFindings { return "The server refuses this plan until these are fixed" }
        if !online { return "No connection" }
        switch dryRun {
        case .loading: return "Checking what would change"
        case .failed: return "Could not check what would change"
        case .loaded(let report) where report.blocking: return "The server would refuse this change"
        default: break
        }
        if case .findings = step, intent.toggles.contains(where: { $0.revealedByConflict && !accepted.contains($0.id) }) {
            return "Accept the findings to file the plan anyway"
        }
        if let phrase = intent.confirmPhrase, typedPhrase.trimmingCharacters(in: .whitespaces) != phrase {
            return "Type \(phrase) to confirm"
        }
        return nil
    }

    var primaryTitle: String {
        switch intent.tier {
        case .plan: return "File plan"
        case .t4: return "\(intent.verb) \(intent.object.name)"
        default: return intent.title
        }
    }

    func loadDryRun() async {
        guard intent.dryRun != nil else { return }
        dryRun = .loading
        do {
            let flow = WriteFlow(intent: intent, client: pending.client, authenticator: IntentAuth.device)
            if let report = try await flow.dryRun() { dryRun = .loaded(report) } else { dryRun = .none }
        } catch {
            dryRun = .failed(LatticeAPIError(error).localizedDescription)
        }
    }

    func submit(runner: ActionRunner) async {
        isSending = true
        notice = nil
        defer { isSending = false }
        var reviewed: DryRunReport?
        if case .loaded(let report) = dryRun { reviewed = report }
        let flow = WriteFlow(intent: intent, client: pending.client, authenticator: runner.authenticator)
        switch await flow.commit(choices: ConfirmChoices(accepted: accepted), reviewed: reviewed) {
        case .cancelled:
            break
        case .authenticationFailed(let message):
            notice = message
        case .dryRunChanged(let fresh):
            dryRun = .loaded(fresh)
            typedPhrase = ""
            notice = "What would change is different now. Review again."
        case .finished(let result):
            handle(result)
        }
    }

    private func handle(_ result: WriteOutcome) {
        if case .refused(.conflict(let findings), _) = result, intent.tier == .plan, !findings.isEmpty {
            step = .findings(findings)
            return
        }
        outcome = result
        switch result {
        case .done(_, let secret) where secret == nil && intent.affected.count <= 1:
            finish(result)
        case .filed(let ids, let refused, _) where ids.count == 1 && refused.isEmpty:
            finish(result)
        default:
            step = .result
        }
    }

    /// Done on the result step.
    func complete() {
        finish(outcome)
    }

    func close() {
        finish(outcome)
    }

    private func finish(_ outcome: WriteOutcome?) {
        guard !finished else { return }
        finished = true
        onFinish?(outcome)
    }

    /// Set by the view to the runner's completion.
    @ObservationIgnored var onFinish: ((WriteOutcome?) -> Void)?
}

/// The content shared by the sheet and the page.
struct ConfirmFlowView: View {
    let model: ConfirmFlowModel
    @Environment(ActionRunner.self) private var runner
    @Environment(SessionStore.self) private var session

    var body: some View {
        Group {
            switch model.step {
            case .confirm, .findings:
                ConfirmStepView(model: model)
            case .result:
                ConfirmResultView(model: model)
            }
        }
        .navigationTitle(model.intent.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.isSending)
        .task {
            await model.loadDryRun()
            await autoConfirmIfAsked()
        }
        .onAppear {
            model.onFinish = { [runner] outcome in runner.finishConfirm(outcome) }
        }
    }

    /// `-AstraAutoConfirm YES` (demo only) runs the primary action once, so
    /// after-states can be captured without a tap. Toggles stay unchecked, so a
    /// plan with findings stops on its Findings step.
    private func autoConfirmIfAsked() async {
        guard LaunchOverrides.current.autoConfirm, session.isDemo else { return }
        if let phrase = model.intent.confirmPhrase { model.typedPhrase = phrase }
        await model.submit(runner: runner)
    }
}

private struct ConfirmStepView: View {
    @Bindable var model: ConfirmFlowModel
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(NetworkMonitor.self) private var network
    @FocusState private var phraseFocused: Bool

    var body: some View {
        let intent = model.intent
        ScrollViewReader { proxy in
            List {
                // A notice follows an action the operator just took, so it
                // sits first, where it is seen without scrolling.
                if let notice = model.notice {
                    Section {
                        Label {
                            Text(notice).foregroundStyle(Color.statusWarnText)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarnFill)
                        }
                    }
                    .id(Self.noticeID)
                }
                Section {
                    Text(intent.consequence)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = intent.authorityNote {
                        Label(note, systemImage: "key")
                            .foregroundStyle(.secondary)
                    }
                    if intent.affected.count == 1, intent.tier != .plan {
                        Label("Affects 1 \(intent.affected[0].kind): \(intent.affected[0].name)", systemImage: "scope")
                            .foregroundStyle(.secondary)
                    }
                    if WriteFlow.requiresAuthentication(intent.tier) {
                        Label("Face ID or your passcode confirms it", systemImage: "faceid")
                            .foregroundStyle(.secondary)
                    }
                }
                if case .findings(let findings) = model.step {
                    Section {
                        ForEach(findings, id: \.self) { finding in
                            Label {
                                Text(finding).foregroundStyle(Color.statusWarnText)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarnFill)
                            }
                        }
                    } header: {
                        Text("The server found problems")
                    } footer: {
                        if model.findingsAcceptable {
                            Text("Nothing was filed. Accept the findings below to file the plan anyway.")
                        } else {
                            Text("Nothing was filed. The server refuses this plan until these are fixed. Change it on web.")
                        }
                    }
                    .id(Self.findingsID)
                    // The acceptance sits right under what it accepts, so the
                    // findings and the only way forward read as one step.
                    toggleSection(model.findingsToggles)
                }
                blastRadius(intent)
                dryRunSection
                toggleSection(model.standingToggles)
                if let phrase = intent.confirmPhrase {
                    Section {
                        TextField("Type \(phrase)", text: $model.typedPhrase)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(TextRole.identifierInDetail.font)
                            .focused($phraseFocused)
                            .submitLabel(.done)
                    } header: {
                        Text("Type \(phrase) to confirm")
                    }
                    .id(Self.phraseID)
                }
            }
            .safeAreaInset(edge: .bottom) {
                primaryAction {
                    withAnimation { proxy.scrollTo(Self.phraseID, anchor: .center) }
                    phraseFocused = true
                }
            }
            .onChange(of: model.notice) { _, notice in
                guard let notice else { return }
                withAnimation { proxy.scrollTo(Self.noticeID, anchor: .top) }
                AccessibilityNotification.Announcement(notice).post()
            }
            // Findings arrive after a tap on the pinned button, usually with
            // the list scrolled down; start the operator at the first finding.
            .onChange(of: model.isShowingFindings) { _, showing in
                guard showing else { return }
                withAnimation { proxy.scrollTo(Self.findingsID, anchor: .top) }
            }
        }
    }

    private static let findingsID = "confirm.findings"
    private static let phraseID = "confirm.phrase"
    private static let noticeID = "confirm.notice"

    @ViewBuilder
    private func toggleSection(_ toggles: [ConfirmToggle]) -> some View {
        if !toggles.isEmpty {
            Section {
                ForEach(toggles, id: \.id) { toggle in
                    Toggle(isOn: binding(for: toggle.id)) {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(toggle.label)
                            Text(toggle.consequence).textRole(.footnote)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func blastRadius(_ intent: WriteIntent) -> some View {
        if intent.tier == .plan ? !intent.affected.isEmpty : intent.affected.count > 1 {
            Section(intent.tier == .plan ? "Will try" : "Affects \(intent.affected.count)") {
                ForEach(intent.affected) { object in
                    Text(object.name)
                }
            }
        }
    }

    @ViewBuilder
    private var dryRunSection: some View {
        switch model.dryRun {
        case .none:
            EmptyView()
        case .loading:
            Section("What would change") {
                HStack(spacing: Spacing.m) {
                    ProgressView()
                    Text("Checking what would change").foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Section("What would change") {
                ErrorRow(message: "Could not check what would change: \(message)") {
                    Task { await model.loadDryRun() }
                }
            }
        case .loaded(let report):
            let groups = Dictionary(grouping: report.lines, by: { $0.group ?? "What would change" })
            let order = report.lines.reduce(into: [String]()) { names, line in
                let name = line.group ?? "What would change"
                if !names.contains(name) { names.append(name) }
            }
            ForEach(order, id: \.self) { group in
                Section(group) {
                    ForEach(groups[group] ?? [], id: \.self) { line in
                        DetailRow(label: line.label, value: line.value, copyable: false)
                    }
                }
            }
        }
    }

    /// The pinned primary button. When the only thing missing is the typed
    /// name, the reason above it is a button that brings the field into view
    /// and focuses it, since the field sits below the dry run.
    private func primaryAction(showPhraseField: @escaping () -> Void) -> some View {
        let reason = model.blockReason(online: network.isSatisfied)
        let destructive = model.intent.tier == .t4
        let phraseReason = model.intent.confirmPhrase.map { "Type \($0) to confirm" }
        return VStack(spacing: Spacing.s) {
            if let reason, reason == phraseReason {
                Button(action: showPhraseField) {
                    Text(reason).font(TextRole.footnote.font).multilineTextAlignment(.center)
                }
                .tint(Color.accentText)
                .accessibilityHint("Moves to the text field")
            } else if let reason, !(model.isStuckOnFindings && model.webPath != nil) {
                // A stuck plan's footer already says why; Open on web is the way on.
                Text(reason).textRole(.footnote).multilineTextAlignment(.center)
            }
            if model.isStuckOnFindings, let path = model.webPath {
                // Re-sending the same plan would only earn the same refusal.
                Button {
                    router.openOnWeb(path)
                } label: {
                    Label("Open on web", systemImage: "safari")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget - 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentFill)
                .accessibilityHint("Opens the console in your browser")
            } else {
                filePrimary(reason: reason, destructive: destructive)
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        // The pinned action must leave room for the content above it at AX5.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func filePrimary(reason: String?, destructive: Bool) -> some View {
        Button(role: destructive ? .destructive : nil) {
            Task { await model.submit(runner: runner) }
        } label: {
            HStack(spacing: Spacing.s) {
                if model.isSending { ProgressView().tint(.white) }
                Text(model.primaryTitle).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget - 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(destructive ? Color.destructiveFill : Color.accentFill)
        .disabled(reason != nil || model.isSending)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { model.accepted.contains(id) },
            set: { on in if on { model.accepted.insert(id) } else { model.accepted.remove(id) } }
        )
    }
}

/// Per-object outcomes for bulk and plan intents, or the one-time value.
private struct ConfirmResultView: View {
    let model: ConfirmFlowModel

    var body: some View {
        Group {
            if case .done(_, let secret?) = model.outcome {
                SecretRevealStep(secret: secret, shareable: false, onClose: model.complete)
            } else {
                List {
                    if let outcome = model.outcome { sections(outcome) }
                }
                .safeAreaInset(edge: .bottom) {
                    Button {
                        model.complete()
                    } label: {
                        Text("Done").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget - 8)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.s)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .background(Color(uiColor: .systemGroupedBackground))
                }
            }
        }
    }

    @ViewBuilder
    private func sections(_ outcome: WriteOutcome) -> some View {
        switch outcome {
        case .done(let message, _):
            Section { Label(message, systemImage: "checkmark.circle").foregroundStyle(.primary) }
        case .partial(let succeeded, let failed, let message):
            Section { headline(message, tone: .warn) }
            if !succeeded.isEmpty {
                Section("Done") {
                    ForEach(succeeded) { StatusRow(style: StatusStyle(word: "done", symbol: "checkmark.circle", tone: .ok), title: $0.name) }
                }
            }
            failures(failed)
        case .filed(let ids, let refused, let notes):
            // What needs the operator comes first: the refusals, then the
            // server's notes, then one row for everything that was filed,
            // which Done opens in Review. The headline already shows notes[0].
            Section { headline(outcome.message, tone: refused.isEmpty ? .quiet : .warn) }
            failures(refused)
            if notes.count > 1 {
                Section("Notes") { ForEach(notes.dropFirst(), id: \.self) { Text($0) } }
            }
            if !ids.isEmpty {
                Section {
                    Button(action: model.complete) {
                        Label(ids.count == 1 ? "Review the filed plan" : "Review the \(ids.count) filed plans", systemImage: "doc.text.magnifyingglass")
                    }
                    .tint(Color.accentText)
                } header: {
                    Text("Filed for approval")
                } footer: {
                    Text(ids.count == 1 ? "1 plan waits for approval." : "\(ids.count) plans wait for approval.")
                }
            }
        case .refused(_, let message):
            Section { headline(message, tone: .fail) }
        case .unknown(let message):
            Section { headline(message, tone: .warn) }
        }
    }

    private func headline(_ text: String, tone: StatusTone) -> some View {
        Label {
            Text(text).foregroundStyle(tone.isProblem ? tone.word : .primary)
        } icon: {
            Image(systemName: tone == .fail ? "xmark.octagon.fill" : (tone == .warn ? "exclamationmark.triangle.fill" : "checkmark.circle"))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tone.glyph)
        }
    }

    @ViewBuilder
    private func failures(_ failed: [ObjectFailure]) -> some View {
        if !failed.isEmpty {
            Section("Not done") {
                ForEach(failed, id: \.self) { failure in
                    StatusRow(style: StatusStyle(word: "not done", symbol: "xmark.circle.fill", tone: .fail),
                              title: failure.object.name, reason: failure.reason)
                }
            }
        }
    }
}
