import SwiftUI

/// The code step of a passkey delete with two-factor on, pushed on the
/// Settings sheet's stack. The code goes through `StepUpCoordinator` (the
/// grant stays in memory only); the delete then runs through ActionRunner,
/// which pushes its T4 ConfirmPage on this same stack and asks for Face ID.
/// Nothing is sent before the operator confirms and authenticates.
struct AccountStepUpPage: View {
    let passkeyID: String

    @Environment(AccessStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(StepUpCoordinator.self) private var stepUp
    @Environment(AppState.self) private var appState
    @Environment(ActionRunner.self) private var runner
    @Environment(ChangeLog.self) private var changes

    @State private var code = ""
    @State private var message: String?
    @State private var waitUntil: Date?
    @State private var isSubmitting = false
    @FocusState private var codeFocused: Bool

    private var passkey: AccessPasskey? { store.passkey(id: passkeyID) }

    /// A held grant that outlasts the confirmation and Face ID still ahead.
    private var heldGrant: StepUpGrant? { AccessPasskeyDeletePlan.reusableGrant(stepUp.grant, now: Date()) }

    var body: some View {
        Group {
            if let passkey, store.hasSession {
                codeStep(passkey)
            } else if store.hasSession, store.passkeys.value == nil {
                List { LoadingRows(label: "Loading the passkey", count: 2) }
            } else {
                WholeScreenState {
                    ContentUnavailableView {
                        Label(store.hasSession ? "Passkey not found" : "Needs a signed-in session", systemImage: "person.badge.key")
                    } description: {
                        Text(store.hasSession ? "It was deleted, here or in the console." : "Passkeys are changed on a signed-in session.")
                    }
                }
            }
        }
        .navigationTitle("Confirm with your code")
        .announcing(message)
        .polling(.standard, version: changes.version([.account, .session])) {
            await store.refreshPasskeys()
        }
    }

    private func codeStep(_ passkey: AccessPasskey) -> some View {
        List {
            Section {
                Text("Delete passkey \(passkey.displayName)")
                    .textRole(.detailHeader)
                    .accessibilityAddTraits(.isHeader)
                if heldGrant != nil {
                    AccountNoticeRow(text: "Code accepted. Continue to confirm the delete.", symbol: "checkmark.shield", tone: .ok)
                } else {
                    TextField("6-digit code", text: $code)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                        .font(.title2.monospacedDigit())
                        .focused($codeFocused)
                        .frame(minHeight: Spacing.minimumTarget)
                        .accessibilityLabel("Authenticator code")
                        .onChange(of: code) { _, new in
                            let digits = String(new.filter(\.isNumber).prefix(6))
                            if digits != new { code = digits }
                            if digits.count == 6 { Task { await submit(passkey) } }
                        }
                }
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    if let message {
                        Text(message).foregroundStyle(Color.statusFailText)
                    }
                    if let wait = waitUntil {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if wait > context.date {
                                HStack(spacing: Spacing.xs) {
                                    Text("Wait for the next code:")
                                    Text(timerInterval: context.date...wait, countsDown: true).monospacedDigit()
                                }
                            }
                        }
                    }
                    Text("Two-factor is on for this account, so the server asks for your authenticator code before a passkey is removed. Next you confirm the delete, then Face ID or your passcode.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .onAppear {
            updateWait()
            codeFocused = heldGrant == nil
        }
        .task {
            // `-AstraAutoConfirm YES` (demo only) enters a demo code once, as
            // the RevealFlow does, so the rest of the flow can be captured.
            guard LaunchOverrides.current.autoConfirm, session.isDemo, heldGrant == nil, code.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(600))
            code = "246810"
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await submit(passkey) }
            } label: {
                HStack(spacing: Spacing.s) {
                    if isSubmitting { ProgressView().tint(.white) }
                    Text(heldGrant != nil ? "Continue" : "Submit").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget - 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentFill)
            .disabled(isSubmitting || runner.isBusy || (heldGrant == nil && code.count != 6))
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .background(Color(uiColor: .systemGroupedBackground))
        }
    }

    private func updateWait() {
        waitUntil = stepUp.waitBeforeSending().map { Date.now.addingTimeInterval(TimeInterval($0)) }
    }

    /// Gets a grant (or reuses the one held), then hands the delete to ActionRunner.
    private func submit(_ passkey: AccessPasskey) async {
        guard !isSubmitting, !runner.isBusy else { return }
        isSubmitting = true
        message = nil
        let grant: StepUpGrant
        if let held = heldGrant {
            grant = held
        } else {
            guard code.count == 6 else {
                // The grant this page showed as accepted ran too short.
                message = "The earlier code is about to expire. Enter a new one."
                codeFocused = true
                isSubmitting = false
                return
            }
            do {
                grant = try await stepUp.submit(code: code)
            } catch let failure as StepUpCoordinator.Failure {
                code = ""
                if case .waitForNextCode = failure { updateWait() }
                message = failure.localizedDescription
                isSubmitting = false
                return
            } catch {
                code = ""
                message = error.localizedDescription
                isSubmitting = false
                return
            }
        }
        code = ""
        isSubmitting = false
        let outcome = await runner.run(AccessIntents.deletePasskey(passkey, grant: grant))
        switch outcome {
        case .done:
            // Back to Security: the passkey and this step are gone.
            appState.settingsPath.removeAll { route in
                switch route {
                case .account(.passkey(let id)), .account(.passkeyDeleteCode(let id)): id == passkeyID
                default: false
                }
            }
        case .refused(.stepUpRequired, let text):
            stepUp.invalidate()
            message = text
            updateWait()
        default:
            break
        }
    }
}
