import SwiftUI

/// M11-02 Passkey. Name, created, last used, where it lives. Rename (T2) and
/// Delete (T4). With two-factor on, the delete runs as one flow inside the
/// Settings sheet: the authenticator code (pushed here), the confirmation
/// page and Face ID, then the request carrying the step-up grant.
struct PasskeyDetailScreen: View {
    let id: String

    @Environment(AccessStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(StepUpCoordinator.self) private var stepUp
    @Environment(AppState.self) private var appState
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        Group {
            if !store.hasSession {
                WholeScreenState {
                    ContentUnavailableView {
                        Label("Needs a signed-in session", systemImage: "person.badge.key")
                    } description: {
                        Text("Passkeys are read and changed on a signed-in session, never with an API token.")
                    } actions: {
                        NavigationLink("Sign in for reveals", value: SettingsRoute.page(.session))
                            .buttonStyle(.bordered)
                    }
                }
            } else {
                ResourceView(state: store.passkeys, noun: "the passkey", retry: refresh) { passkeys in
                    if let passkey = passkeys.first(where: { $0.id == id }) {
                        detail(passkey)
                    } else {
                        notFound
                    }
                }
            }
        }
        .navigationTitle(store.passkey(id: id)?.displayName ?? "Passkey")
        .navigationSubtitle(store.passkey(id: id).map { AccessPasskeys.storage($0) } ?? "")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Copy ID", systemImage: "number") { AccountCopy.copy(id) }
                    Button("Open on web", systemImage: "safari") { router.openOnWeb(.settingsSecurity) }
                    if let passkey = store.passkey(id: id) {
                        Section {
                            Button("Delete passkey", systemImage: "trash", role: .destructive) { startDelete(passkey) }
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .polling(.standard, version: changes.version([.account, .session])) {
            await store.refreshPasskeys()
        }
    }

    private func detail(_ passkey: AccessPasskey) -> some View {
        let renamed = AccessPasskeys.renameValue(name, current: passkey.name)
        let totp = store.sessionIdentity?.totpEnabled
        return List {
            AccountRefreshError(state: store.passkeys, noun: "the passkey", retry: refresh)
            Section {
                AccountPasskeyRow(passkey: passkey)
            }

            Section {
                if let created = passkey.createdAt { AccountTimeRow(label: "Added", date: created) }
                if let used = passkey.lastUsedAt {
                    AccountTimeRow(label: "Last used", date: used)
                } else {
                    DetailRow(label: "Last used", value: "Never", copyable: false)
                }
                DetailRow(label: "Stored", value: passkey.backedUp ? "Synced by a passkey provider" : "On this one device or key only", copyable: false)
                DetailRow(label: "Connects by", value: AccessPasskeys.transports(passkey), copyable: false)
                if !passkey.aaguid.isEmpty {
                    DetailRow(label: "Authenticator model", value: passkey.aaguid, monospaced: true)
                }
                DetailRow(label: "Passkey ID", value: passkey.id, monospaced: true)
            } header: {
                Text("Passkey").accessibilityAddTraits(.isHeader)
            }

            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .frame(minHeight: Spacing.minimumTarget)
                    .onSubmit { if let renamed { rename(passkey, to: renamed) } }
                AccountActionButton(title: "Rename passkey", systemImage: "pencil", note: renamed.map { "Renames it to \($0)." }, blocker: renamed == nil ? "Type a new name first." : nil) {
                    if let renamed { rename(passkey, to: renamed) }
                }
            } header: {
                Text("Name").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Renaming grants no access, so no code is asked.")
            }

            Section {
                AccountActionButton(
                    title: "Delete passkey", systemImage: "trash",
                    note: totp == true
                        ? "It can no longer sign in to this account. Your authenticator code, then Face ID, confirm it."
                        : "It can no longer sign in to this account. Face ID confirms it.",
                    blocker: nil, role: .destructive
                ) { startDelete(passkey) }
            } header: {
                Text("Delete").accessibilityAddTraits(.isHeader)
            } footer: {
                FreshnessFooter(state: store.passkeys, interval: Polling.standard.interval(lowPower: false))
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refreshPasskeys() }
        .onAppear { if name.isEmpty { name = passkey.name } }
    }

    private func rename(_ passkey: AccessPasskey, to newName: String) {
        nameFocused = false
        Task { await runner.run(AccessIntents.renamePasskey(passkey, to: newName)) }
    }

    /// Two-factor on and no grant that outlasts the confirmation: the code
    /// step first, as a page on this sheet's stack. Otherwise straight to the
    /// confirmation. A `step_up_required` refusal clears the grant and
    /// returns to the code step once (section 6.4).
    private func startDelete(_ passkey: AccessPasskey) {
        guard !runner.isBusy else { return }
        Task {
            if store.sessionIdentity == nil { await store.refreshIdentity() }
            let totp = store.sessionIdentity?.totpEnabled
            let held = AccessPasskeyDeletePlan.reusableGrant(stepUp.grant, now: Date())
            if AccessPasskeyDeletePlan.steps(totpEnabled: totp, grantUsable: held != nil).first == .code {
                pushCodeStep(passkey)
                return
            }
            let grant = AccessPasskeyDeletePlan.sendsGrant(totpEnabled: totp) ? held : nil
            let outcome = await runner.run(AccessIntents.deletePasskey(passkey, grant: grant))
            switch outcome {
            case .done:
                dismiss()
            case .refused(.stepUpRequired, _):
                stepUp.invalidate()
                pushCodeStep(passkey)
            default:
                break
            }
        }
    }

    private func pushCodeStep(_ passkey: AccessPasskey) {
        appState.settingsPath.append(.account(.passkeyDeleteCode(id: passkey.id)))
    }

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Passkey not found", systemImage: "person.badge.key")
            } description: {
                Text("It was deleted, here or in the console.")
            }
        }
    }

    private func refresh() {
        Task { await store.refreshPasskeys() }
    }
}
