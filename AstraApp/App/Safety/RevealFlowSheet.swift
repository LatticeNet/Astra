import SwiftUI

/// One sheet for every S action (F-13), advancing in place: sign in when
/// there is no session, the code step when no grant is held, then the value.
struct RevealFlowSheet: View {
    let pending: PendingReveal

    var body: some View {
        NavigationStack {
            RevealFlowContent(pending: pending)
        }
        .presentationDetents([.large])
    }
}

/// The same steps pushed on another sheet's stack.
struct RevealFlowPage: View {
    let pending: PendingReveal

    var body: some View {
        RevealFlowContent(pending: pending)
    }
}

@MainActor @Observable
final class RevealFlowModel {
    enum Step: Equatable {
        case starting
        case needsSession
        case code
        case value(RevealedSecret)
        case failed(String)
    }

    let intent: RevealIntent
    private(set) var step: Step = .starting
    private(set) var isSubmitting = false
    private(set) var codeMessage: String?
    private(set) var waitUntil: Date?
    var code = ""
    @ObservationIgnored private var retriedAfterStepUpRequired = false

    init(intent: RevealIntent) {
        self.intent = intent
    }

    func start(session: SessionStore, stepUp: StepUpCoordinator) async {
        await session.loadKeptSessionIfNeeded()
        guard session.revealClient != nil else {
            step = .needsSession
            return
        }
        if let missing = session.missing(ScopeRequirement(groups: intent.scopes.map { [$0] }), on: .session), !missing.isEmpty {
            step = .failed("This session lacks \(missing.joined(separator: ", ")).")
            return
        }
        if stepUp.holdsUsableGrant, let grant = try? await stepUp.grant(for: intent.purpose) {
            await perform(grant: grant, session: session, stepUp: stepUp)
        } else {
            step = .code
            updateWait(stepUp)
        }
    }

    func updateWait(_ stepUp: StepUpCoordinator) {
        waitUntil = stepUp.waitBeforeSending().map { Date.now.addingTimeInterval(TimeInterval($0)) }
    }

    func submitCode(session: SessionStore, stepUp: StepUpCoordinator) async {
        guard !isSubmitting, code.count == 6 else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let grant = try await stepUp.submit(code: code)
            codeMessage = nil
            await perform(grant: grant, session: session, stepUp: stepUp)
        } catch let failure as StepUpCoordinator.Failure {
            code = ""
            switch failure {
            case .waitForNextCode: updateWait(stepUp)
            case .noSession: step = .needsSession
            default: break
            }
            codeMessage = failure.localizedDescription
        } catch {
            codeMessage = error.localizedDescription
        }
    }

    private func perform(grant: StepUpGrant, session: SessionStore, stepUp: StepUpCoordinator) async {
        guard let client = session.revealClient else {
            step = .needsSession
            return
        }
        do {
            step = .value(try await intent.perform(client, grant))
        } catch {
            switch LatticeAPIError(error) {
            case .forbidden(code: "step_up_required", _) where !retriedAfterStepUpRequired:
                retriedAfterStepUpRequired = true
                stepUp.invalidate()
                code = ""
                codeMessage = "Confirm with a new code."
                step = .code
            case .forbidden(code: "secret_reveal_scope_required", let scope):
                step = .failed("This session lacks \(scope ?? "the scope for this secret").")
            case let other:
                step = .failed(other.localizedDescription)
            }
        }
    }
}

private struct RevealFlowContent: View {
    let pending: PendingReveal
    @State private var model: RevealFlowModel
    @Environment(ActionRunner.self) private var runner
    @Environment(SessionStore.self) private var session
    @Environment(StepUpCoordinator.self) private var stepUp
    @FocusState private var codeFocused: Bool

    init(pending: PendingReveal) {
        self.pending = pending
        _model = State(initialValue: RevealFlowModel(intent: pending.intent))
    }

    var body: some View {
        content
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { close() }
                }
            }
            .task {
                await model.start(session: session, stepUp: stepUp)
                await autoConfirmIfAsked()
            }
            .onDisappear { close() }
    }

    /// `-AstraAutoConfirm YES` (demo only) enters a demo code once, so the
    /// value step can be captured without typing. The demo step-up accepts any
    /// six digits except its wrong code.
    private func autoConfirmIfAsked() async {
        guard LaunchOverrides.current.autoConfirm, session.isDemo, model.step == .code else { return }
        model.code = "246810"
        await model.submitCode(session: session, stepUp: stepUp)
    }

    private var navigationTitle: String {
        switch model.step {
        case .value: return pending.intent.title
        case .needsSession: return "Sign in for reveals"
        default: return "Confirm with your code"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .starting:
            List { LoadingRows(label: "Checking the session", count: 1) }
        case .needsSession:
            List {
                Section {
                    Text(pending.intent.title).font(TextRole.detailHeader.font)
                    Text("Reveals need a signed-in session, because the server refuses step-up for API tokens. Sign in, then confirm with your authenticator code.")
                        .foregroundStyle(.secondary)
                }
                Section("Sign in for reveals") {
                    SessionSignInForm {
                        Task { await model.start(session: session, stepUp: stepUp) }
                    }
                }
            }
        case .code:
            codeStep
        case .value(let secret):
            SecretRevealStep(secret: secret, shareable: pending.intent.shareable, onClose: close)
        case .failed(let message):
            ContentUnavailableView {
                Label("Not revealed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        }
    }

    private var codeStep: some View {
        @Bindable var model = model
        return List {
            Section {
                Text(pending.intent.title).font(TextRole.detailHeader.font)
                TextField("6-digit code", text: $model.code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .font(.title2.monospacedDigit())
                    .focused($codeFocused)
                    .onChange(of: model.code) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(6))
                        if digits != new { model.code = digits }
                        if digits.count == 6 { Task { await model.submitCode(session: session, stepUp: stepUp) } }
                    }
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    if let wait = model.waitUntil, wait > .now {
                        HStack(spacing: Spacing.xs) {
                            Text("Wait for the next code:")
                            Text(timerInterval: Date.now...wait, countsDown: true).monospacedDigit()
                        }
                    }
                    if let message = model.codeMessage {
                        Text(message).foregroundStyle(Color.statusFailText)
                    }
                }
            }
        }
        .onAppear { codeFocused = true }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await model.submitCode(session: session, stepUp: stepUp) }
            } label: {
                HStack(spacing: Spacing.s) {
                    if model.isSubmitting { ProgressView().tint(.white) }
                    Text("Submit").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget - 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentFill)
            .disabled(model.code.count != 6 || model.isSubmitting)
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .background(Color(uiColor: .systemGroupedBackground))
        }
    }

    private func close() {
        guard runner.pendingReveal?.id == pending.id else { return }
        runner.finishReveal()
        if session.endSessionAfterReveal, !session.keepSession, session.credentialKind == .token, !session.isDemo {
            stepUp.reset()
            Task { await session.endRevealSession() }
        }
    }
}
