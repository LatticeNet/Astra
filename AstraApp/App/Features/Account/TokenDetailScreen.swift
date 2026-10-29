import SwiftUI

/// M11-05 Token. Its scopes with what each grants, its node allowlist, when
/// it was created and revoked. Revoke (T4) and Delete (T4, revoked tokens
/// only). The token this iPhone uses says so, and revoking it signs the
/// phone out after the server confirms.
struct TokenDetailScreen: View {
    let id: String

    @Environment(AccessStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(StepUpCoordinator.self) private var stepUp
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ResourceView(state: store.tokens, noun: "the token", retry: refresh) { tokens in
            if let token = tokens.first(where: { $0.id == id }) {
                detail(token)
            } else {
                notFound
            }
        }
        .navigationTitle(store.token(id: id)?.displayName ?? "Token")
        // A link opens the Settings sheet with its path set, so the sheet's
        // root never appears to register itself; this page hosts its own gates.
        .actionHost(inSheet: true)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .polling(.standard, version: changes.version([.tokens, .account])) {
            await store.refreshTokens()
        }
    }

    private var subtitle: String {
        guard let token = store.token(id: id) else { return "" }
        if token.isRevoked { return "Revoked" }
        return store.isOwn(token) ? "Active, this iPhone" : "Active"
    }

    private var missing: String? { store.tokensMissing.map { "Needs \($0)" } }

    private func detail(_ token: LatticeToken) -> some View {
        let isOwn = store.isOwn(token)
        // A revoked token opens nothing, so what it could do is no longer a risk.
        let risks = token.isRevoked ? [] : AccessScopes.risks(token.scopes)
        return List {
            AccountRefreshError(state: store.tokens, noun: "the token", retry: refresh)
            Section {
                if isOwn, !token.isRevoked {
                    AccountNoticeRow(text: "This iPhone uses this token. Revoking it signs this iPhone out.", symbol: "iphone", tone: .warn)
                }
                AccountTokenRow(token: token, isOwn: isOwn)
            }

            if !risks.isEmpty {
                Section {
                    ForEach(risks, id: \.scope) { risk in
                        AccountNoticeRow(text: "\(risk.scope == "*" ? "Full administrator" : risk.scope): \(risk.sentence)")
                    }
                } header: {
                    Text("Sensitive scopes").accessibilityAddTraits(.isHeader)
                }
            }

            // Actions sit above the scope list, which runs to 30 rows, so the
            // leak response is reachable without a long scroll.
            Section {
                if !token.isRevoked {
                    AccountActionButton(
                        title: "Revoke token", systemImage: "xmark.circle",
                        note: isOwn ? AccessIntents.ownTokenWarning : "Anything calling the API with it gets 401 from now on. One-way.",
                        blocker: missing, role: .destructive
                    ) { revoke(token) }
                }
                AccountActionButton(
                    title: "Delete token", systemImage: "trash",
                    note: "Removes it from the list. Audit history is kept.",
                    blocker: missing ?? AccessTokens.deleteBlocker(token), role: .destructive
                ) { delete(token) }
                WebLinkRow(title: "Manage tokens on web", path: .tokens)
            } header: {
                Text("Actions").accessibilityAddTraits(.isHeader)
            }

            Section {
                if token.scopes.isEmpty {
                    Text("No scopes").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget)
                }
                ForEach(AccessScopes.lines(token.scopes)) { line in
                    AccountScopeRow(line: line)
                }
            } header: {
                Text(token.scopes.count == 1 ? "Scope" : "Scopes (\(token.scopes.count))").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("A token holds only scopes its creator held. Scopes are fixed at creation; a different set needs a new token.")
            }

            AccountAllowlistSection(allowlist: token.serverAllowlist, footer: "The allowlist confines node-scoped actions. Fleet-wide writes refuse a confined token outright.")

            Section {
                if let created = token.createdAt { AccountTimeRow(label: "Created", date: created) }
                if let revoked = token.revokedAt { AccountTimeRow(label: "Revoked", date: revoked) }
                DetailRow(label: "Last used", value: "Not recorded by the server", copyable: false)
                DetailRow(label: "Created by", value: token.actorID, monospaced: true)
                DetailRow(label: "Token ID", value: token.id, monospaced: true)
            } header: {
                Text("Details").accessibilityAddTraits(.isHeader)
            } footer: {
                FreshnessFooter(state: store.tokens, interval: Polling.standard.interval(lowPower: false))
            }

        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refreshTokens() }
    }

    private func revoke(_ token: LatticeToken) {
        guard !runner.isBusy else { return }
        Task {
            let ownership = await store.ownershipForWrite(of: token)
            let outcome = await runner.run(AccessIntents.revokeToken(token, ownership: ownership))
            if case .done = outcome, await store.revokedOwnToken(ownership) {
                await AccountSignOut.afterOwnTokenRevoked(session: session, stepUp: stepUp, nodes: nodes)
            }
        }
    }

    private func delete(_ token: LatticeToken) {
        Task {
            let ownership = await store.ownershipForWrite(of: token)
            let outcome = await runner.run(AccessIntents.deleteToken(token, ownership: ownership))
            // The screen closes only once the server confirmed the delete.
            if case .done = outcome { dismiss() }
        }
    }

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Token not found", systemImage: "key")
            } description: {
                Text("It was deleted, or this link names a token this server does not hold or this token cannot list.")
            } actions: {
                Button("Open on web") { router.openOnWeb(.tokens) }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section {
                    Button("Copy link", systemImage: "link") { AccountCopy.copy(AccountCopy.link(.token(id: id))) }
                    Button("Copy ID", systemImage: "number") { AccountCopy.copy(id) }
                    Button("Open on web", systemImage: "safari") { router.openOnWeb(.tokens) }
                }
                if let token = store.token(id: id) {
                    Section {
                        if !token.isRevoked {
                            AccountGatedButton(title: "Revoke token", systemImage: "xmark.circle", blocker: missing, role: .destructive) { revoke(token) }
                        }
                        AccountGatedButton(title: "Delete token", systemImage: "trash", blocker: missing ?? AccessTokens.deleteBlocker(token), role: .destructive) { delete(token) }
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    private func refresh() {
        Task { await store.refreshTokens() }
    }
}
