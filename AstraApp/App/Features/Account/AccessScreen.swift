import SwiftUI

/// M11-03 Access, pushed inside the Settings sheet. Users (user:admin),
/// Tokens (token:admin) and SSO (oidc:admin). Revoking a token is the one
/// native write (T4, the leak response); creating a user, a token or a
/// provider, and editing them, stay on the web.
struct AccessScreen: View {
    var view: String?

    enum Segment: String, CaseIterable, Hashable {
        case users, tokens, sso

        var title: String {
            switch self {
            case .users: "Users"
            case .tokens: "Tokens"
            case .sso: "SSO"
            }
        }
    }

    static let tokensQueryKey = "account.access.tokensQuery"
    static let usersQueryKey = "account.access.usersQuery"

    @Environment(AccessStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(StepUpCoordinator.self) private var stepUp
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var segment: Segment?
    @State private var width: CGFloat?
    @SceneStorage(AccessScreen.tokensQueryKey) private var tokensQuery = ""
    @SceneStorage(AccessScreen.usersQueryKey) private var usersQuery = ""
    @State private var ssoQuery = ""

    init(view: String? = nil) {
        self.view = view
        _segment = State(initialValue: view.flatMap(Segment.init(rawValue:)))
    }

    /// A link's view wins; otherwise the first layer this token can read, as the console opens it.
    private var shown: Segment {
        if let segment { return segment }
        if store.usersMissing == nil { return .users }
        if store.tokensMissing == nil { return .tokens }
        if store.ssoMissing == nil { return .sso }
        return .tokens
    }

    var body: some View {
        let selection = Binding(get: { shown }, set: { segment = $0 })
        let picker = AdaptiveSegmentedPicker(title: "Access layers", options: Segment.allCases.map { ($0, $0.title) }, selection: selection, containerWidth: width)
        Group {
            switch shown {
            case .users: usersLayer
            case .tokens: tokensLayer
            case .sso: ssoLayer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle("Access")
        .navigationSubtitle(activeQuery.map { "Matching \($0)" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaBar(edge: .top) {
            if verticalSizeClass != .compact {
                picker.padding(.horizontal, Spacing.l).padding(.bottom, Spacing.s)
            }
        }
        .toolbar {
            if verticalSizeClass == .compact {
                ToolbarItem(placement: .principal) { picker.frame(maxWidth: 420) }
            }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
        }
    }

    /// The query filtering the shown layer, which a restored scene can carry
    /// over from an earlier day, so the screen names it (section 2.6).
    private var activeQuery: String? {
        let query: String = switch shown {
        case .users: store.users.value == nil ? "" : usersQuery
        case .tokens: store.tokens.value == nil ? "" : tokensQuery
        case .sso: store.providers.value == nil ? "" : ssoQuery
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var moreMenu: some View {
        Menu {
            switch shown {
            case .users:
                Button("New user on web", systemImage: "person.badge.plus") { router.openOnWeb(.users) }
                Button("Open on web", systemImage: "safari") { router.openOnWeb(.users) }
            case .tokens:
                Button("New token on web", systemImage: "plus.circle") { router.openOnWeb(.tokens) }
                Button("Open on web", systemImage: "safari") { router.openOnWeb(.tokens) }
            case .sso:
                Button("New provider on web", systemImage: "plus.circle") { router.openOnWeb(.accountSSO) }
                Button("Open on web", systemImage: "safari") { router.openOnWeb(.accountSSO) }
            }
            NavigationLink(value: SettingsRoute.page(.scopes)) {
                Label("This token's scopes", systemImage: "key")
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    // MARK: Tokens

    private var tokensLayer: some View {
        ResourceView(state: store.tokens, noun: "tokens", retry: refreshTokens) { tokens in
            tokensList(tokens)
        }
        .accountSearchable($tokensQuery, prompt: "Search, scope:, state:", when: store.tokens.value != nil)
        .polling(.standard, version: changes.version([.tokens, .account])) {
            await store.refreshTokens()
        }
    }

    private var tokensCompiled: Result<LatticeCompiledQuery<LatticeToken>, LatticeQueryError> {
        LatticeQueryEngine.compile(tokensQuery, provider: AccessTokenQueryFields.self)
    }

    private func tokensList(_ tokens: [LatticeToken]) -> some View {
        let sorted = AccessTokens.sorted(tokens)
        let filtered: [LatticeToken] = switch tokensCompiled {
        case .success(let query): LatticeQueryEngine.apply(query, to: sorted, now: Date())
        case .failure: sorted
        }
        // The token this iPhone uses leads, since revoking it signs the phone out.
        let active = filtered.filter { !$0.isRevoked && store.isOwn($0) } + filtered.filter { !$0.isRevoked && !store.isOwn($0) }
        let revoked = filtered.filter(\.isRevoked)
        return List {
            AccountRefreshError(state: store.tokens, noun: "tokens", retry: refreshTokens)
            if let query = activeQuery {
                Section {
                    FilterStateRow(text: "Showing tokens matching \(query)") { tokensQuery = "" }
                }
            }
            if case .failure(let error) = tokensCompiled, !tokensQuery.isEmpty {
                AccountQueryProblemRow(error: error, fields: "state, name, scope, actor, node, created, is:confined, is:revoked, is:admin")
            }
            if filtered.isEmpty {
                Section {
                    if tokens.isEmpty {
                        ContentUnavailableView("No access tokens", systemImage: "key", description: Text("Create a scoped token on the web; its secret is shown once there."))
                    } else {
                        ContentUnavailableView.search(text: tokensQuery)
                    }
                }
            }
            if !active.isEmpty {
                Section {
                    ForEach(active) { tokenRow($0) }
                } header: {
                    Text(activeQuery == nil ? AccessTokens.summary(tokens) : "\(filtered.count) of \(tokens.count == 1 ? "1 token" : "\(tokens.count) tokens")").accessibilityAddTraits(.isHeader)
                }
            }
            if !revoked.isEmpty {
                Section {
                    ForEach(revoked) { tokenRow($0) }
                } header: {
                    Text(revoked.count == 1 ? "Revoked (1)" : "Revoked (\(revoked.count))").accessibilityAddTraits(.isHeader)
                } footer: {
                    Text("A revoked token opens nothing. Delete removes it from this list; the audit log keeps it.")
                }
            }
            Section {
                WebLinkRow(title: "New token on web", path: .tokens)
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("A new token's secret is shown once, so tokens are created on the web. The server records no last use.")
                    FreshnessFooter(state: store.tokens, interval: Polling.standard.interval(lowPower: false))
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refreshTokens() }
    }

    private func tokenRow(_ token: LatticeToken) -> some View {
        let isOwn = store.isOwn(token)
        let missing = store.tokensMissing.map { "Needs \($0)" }
        return NavigationLink(value: SettingsRoute.account(.token(id: token.id))) {
            AccountTokenRow(token: token, isOwn: isOwn)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !token.isRevoked, missing == nil {
                Button("Revoke", systemImage: "xmark.circle") { revoke(token) }
                    .tint(Color.destructiveFill)
            }
        }
        .contextMenu {
            NavigationLink(value: SettingsRoute.account(.token(id: token.id))) {
                Label("Open", systemImage: "arrow.right.circle")
            }
            Button("Copy link", systemImage: "link") { AccountCopy.copy(AccountCopy.link(.token(id: token.id))) }
            Button("Copy ID", systemImage: "number") { AccountCopy.copy(token.id) }
            Button("Open on web", systemImage: "safari") { router.openOnWeb(.tokens) }
            Divider()
            if !token.isRevoked {
                AccountGatedButton(title: "Revoke token", systemImage: "xmark.circle", blocker: missing, role: .destructive) { revoke(token) }
            }
            AccountGatedButton(title: "Delete token", systemImage: "trash", blocker: missing ?? AccessTokens.deleteBlocker(token), role: .destructive) { delete(token) }
        }
        .accessibilityActions {
            Button("Copy link") { AccountCopy.copy(AccountCopy.link(.token(id: token.id))) }
            if token.isRevoked, missing == nil {
                Button("Delete token") { delete(token) }
            }
        }
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
            await runner.run(AccessIntents.deleteToken(token, ownership: ownership))
        }
    }

    private func refreshTokens() {
        Task { await store.refreshTokens() }
    }

    // MARK: Users

    private var usersLayer: some View {
        ResourceView(state: store.users, noun: "users", retry: refreshUsers) { users in
            usersList(users)
        }
        .accountSearchable($usersQuery, prompt: "Search, login:, scope:", when: store.users.value != nil)
        .polling(.standard, version: changes.version([.account])) {
            await store.refreshUsers()
        }
    }

    private var usersCompiled: Result<LatticeCompiledQuery<AccessUser>, LatticeQueryError> {
        LatticeQueryEngine.compile(usersQuery, provider: AccessUserQueryFields.self)
    }

    private func usersList(_ users: [AccessUser]) -> some View {
        let sorted = AccessUsers.sorted(users)
        let filtered: [AccessUser] = switch usersCompiled {
        case .success(let query): LatticeQueryEngine.apply(query, to: sorted, now: Date())
        case .failure: sorted
        }
        return List {
            AccountRefreshError(state: store.users, noun: "users", retry: refreshUsers)
            if let query = activeQuery {
                Section {
                    FilterStateRow(text: "Showing users matching \(query)") { usersQuery = "" }
                }
            }
            if case .failure(let error) = usersCompiled, !usersQuery.isEmpty {
                AccountQueryProblemRow(error: error, fields: "name, scope, login, created, is:totp, is:admin, is:confined")
            }
            if filtered.isEmpty {
                Section {
                    if users.isEmpty {
                        ContentUnavailableView("No users", systemImage: "person.2", description: Text("Create an operator account on the web."))
                    } else {
                        ContentUnavailableView.search(text: usersQuery)
                    }
                }
            } else {
                Section {
                    ForEach(filtered) { user in
                        NavigationLink(value: SettingsRoute.account(.user(id: user.id))) {
                            AccountUserRow(user: user, isSelf: AccessUsers.isSelf(user, actorID: store.actorID))
                        }
                        .contextMenu {
                            NavigationLink(value: SettingsRoute.account(.user(id: user.id))) {
                                Label("Open", systemImage: "arrow.right.circle")
                            }
                            Button("Copy link", systemImage: "link") { AccountCopy.copy(AccountCopy.link(.user(id: user.id))) }
                            Button("Copy ID", systemImage: "number") { AccountCopy.copy(user.id) }
                            Button("Edit on web", systemImage: "safari") { router.openOnWeb(.users) }
                        }
                    }
                } header: {
                    Text(activeQuery == nil ? AccessUsers.summary(users) : "\(filtered.count) of \(users.count == 1 ? "1 user" : "\(users.count) users")").accessibilityAddTraits(.isHeader)
                }
            }
            Section {
                WebLinkRow(title: "New user on web", path: .users)
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Creating, editing and deleting accounts is desk work, so it stays on the web.")
                    FreshnessFooter(state: store.users, interval: Polling.standard.interval(lowPower: false))
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refreshUsers() }
    }

    private func refreshUsers() {
        Task { await store.refreshUsers() }
    }

    // MARK: SSO

    private var ssoLayer: some View {
        ResourceView(state: store.providers, noun: "identity providers", retry: refreshProviders) { providers in
            ssoList(providers)
        }
        .accountSearchable($ssoQuery, prompt: "Search identity providers", when: store.providers.value != nil)
        .polling(.standard, version: changes.version([.account])) {
            await store.refreshProviders()
        }
    }

    private func ssoList(_ providers: [AccessSSOProvider]) -> some View {
        let words = ssoQuery.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let filtered = AccessSSO.sorted(providers).filter { provider in
            let text = [provider.title, provider.issuer, provider.clientID].joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        return List {
            AccountRefreshError(state: store.providers, noun: "identity providers", retry: refreshProviders)
            if let query = activeQuery {
                Section {
                    FilterStateRow(text: "Showing providers matching \(query)") { ssoQuery = "" }
                }
            }
            if filtered.isEmpty {
                Section {
                    if providers.isEmpty {
                        ContentUnavailableView("No identity providers", systemImage: "person.badge.key", description: Text("Operators sign in with a password or a passkey. Add an OIDC provider on the web."))
                    } else {
                        ContentUnavailableView.search(text: ssoQuery)
                    }
                }
            } else {
                Section {
                    ForEach(filtered) { provider in
                        NavigationLink(value: SettingsRoute.account(.ssoProvider(id: provider.id))) {
                            AccountProviderRow(provider: provider)
                        }
                        .contextMenu {
                            NavigationLink(value: SettingsRoute.account(.ssoProvider(id: provider.id))) {
                                Label("Open", systemImage: "arrow.right.circle")
                            }
                            Button("Copy ID", systemImage: "number") { AccountCopy.copy(provider.id) }
                            Button("Edit on web", systemImage: "safari") { router.openOnWeb(.accountSSO) }
                        }
                    }
                } header: {
                    Text(AccessSSO.summary(providers)).accessibilityAddTraits(.isHeader)
                }
            }
            Section {
                WebLinkRow(title: "New provider on web", path: .accountSSO)
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("The server keeps no test result. Edit, delete and test providers on the web, where the client secret is entered.")
                    FreshnessFooter(state: store.providers, interval: Polling.standard.interval(lowPower: false))
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refreshProviders() }
    }

    private func refreshProviders() {
        Task { await store.refreshProviders() }
    }
}

extension View {
    /// The search field only over a list that can be read: searching a
    /// denied or companion-behind layer would do nothing and read as broken.
    @ViewBuilder
    func accountSearchable(_ text: Binding<String>, prompt: String, when readable: Bool) -> some View {
        if readable {
            searchable(text: text, prompt: prompt)
        } else {
            self
        }
    }
}

/// Revoking the token this iPhone uses ends its access, so the phone signs
/// out the way Settings > Connection does once the server confirmed it.
@MainActor
enum AccountSignOut {
    static func afterOwnTokenRevoked(session: SessionStore, stepUp: StepUpCoordinator, nodes: NodeDirectory) async {
        stepUp.reset()
        nodes.reset()
        await session.signOut()
    }
}
