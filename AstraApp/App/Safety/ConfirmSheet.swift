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
        intent.confirmPhrase != nil || intent.dryRun != nil || !intent.toggles.isEmpty || intent.affected.count > 1
    }

    var isShowingFindings: Bool {
        if case .findings = step { return true }
        return false
    }

    var visibleToggles: [ConfirmToggle] {
        if case .findings = step { return intent.toggles }
        return intent.toggles.filter { !$0.revealedByConflict }
    }

    /// Why the primary action is off, or nil when it may run.
    func blockReason(online: Bool) -> String? {
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
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        let intent = model.intent
        ScrollViewReader { proxy in
            List {
                Section {
                    Text(intent.consequence)
                        .fixedSize(horizontal: false, vertical: true)
                    Label("\(intent.scopes.count == 1 ? "Uses scope" : "Uses scopes") \(intent.scopes.joined(separator: ", "))", systemImage: "key")
                        .foregroundStyle(.secondary)
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
                        Text("Nothing was filed. Accept the findings below to file the plan anyway.")
                    }
                }
                blastRadius(intent)
                dryRunSection
                if !model.visibleToggles.isEmpty {
                    Section {
                        ForEach(model.visibleToggles, id: \.id) { toggle in
                            Toggle(isOn: binding(for: toggle.id)) {
                                VStack(alignment: .leading, spacing: Spacing.xxs) {
                                    Text(toggle.label)
                                    Text(toggle.consequence).textRole(.footnote)
                                }
                            }
                        }
                    }
                    .id(Self.togglesID)
                }
                if let phrase = intent.confirmPhrase {
                    Section {
                        TextField("Type \(phrase)", text: $model.typedPhrase)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(TextRole.identifierInDetail.font)
                    } header: {
                        Text("Type \(phrase) to confirm")
                    }
                }
                if let notice = model.notice {
                    Section {
                        Label {
                            Text(notice).foregroundStyle(Color.statusWarnText)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarnFill)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { primaryAction }
            // The findings push the acceptance toggle below the pinned button;
            // bring it into view, since it is the only way forward.
            .onChange(of: model.isShowingFindings) { _, showing in
                guard showing else { return }
                withAnimation { proxy.scrollTo(Self.togglesID, anchor: .bottom) }
            }
        }
    }

    private static let togglesID = "confirm.toggles"

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

    private var primaryAction: some View {
        let reason = model.blockReason(online: network.isSatisfied)
        let destructive = model.intent.tier == .t4
        return VStack(spacing: Spacing.s) {
            if let reason {
                Text(reason).textRole(.footnote).multilineTextAlignment(.center)
            }
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
            .tint(destructive ? nil : Color.accentFill)
            .disabled(reason != nil || model.isSending)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        // The pinned action must leave room for the content above it at AX5.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .background(Color(uiColor: .systemGroupedBackground))
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
            Section { headline(outcome.message, tone: refused.isEmpty ? .quiet : .warn) }
            Section("Filed for approval") {
                ForEach(ids, id: \.self) { id in
                    Text(id).textRole(.identifierInRow)
                }
            }
            failures(refused)
            if !notes.isEmpty {
                Section("Notes") { ForEach(notes, id: \.self) { Text($0) } }
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
