import SwiftUI

/// M11-04 User. Every field read only: role, sign-in, two-factor, scopes
/// with what each grants, and the node allowlist. Edit and Delete are on
/// the web, where identity administration belongs.
struct UserDetailScreen: View {
    let id: String

    @Environment(AccessStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router

    var body: some View {
        ResourceView(state: store.users, noun: "the user", retry: refresh) { users in
            if let user = users.first(where: { $0.id == id }) {
                detail(user, users: users)
            } else {
                notFound
            }
        }
        .navigationTitle(store.user(id: id)?.displayName ?? "User")
        .navigationSubtitle(store.user(id: id).map { AccessUsers.role($0) } ?? "")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Copy link", systemImage: "link") { AccountCopy.copy(AccountCopy.link(.user(id: id))) }
                    Button("Copy ID", systemImage: "number") { AccountCopy.copy(id) }
                    Button("Open on web", systemImage: "safari") { router.openOnWeb(.users) }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .polling(.standard, version: changes.version([.account])) {
            await store.refreshUsers()
        }
    }

    private func detail(_ user: AccessUser, users: [AccessUser]) -> some View {
        let isSelf = AccessUsers.isSelf(user, actorID: store.actorID)
        let blocker = AccessUsers.deleteBlocker(user, users: users, actorID: store.actorID)
        return List {
            AccountRefreshError(state: store.users, noun: "the user", retry: refresh)
            Section {
                AccountUserRow(user: user, isSelf: isSelf)
                if isSelf {
                    AccountNoticeRow(text: "This is the account you are signed in with.", symbol: "person.crop.circle", tone: .quiet)
                }
                if !user.totpEnabled {
                    AccountNoticeRow(text: user.hasPassword
                        ? "Signs in with a password alone. Ask this operator to set up an authenticator."
                        : "Signs in through single sign-on with no Lattice authenticator code.")
                }
            }

            Section {
                DetailRow(label: "Username", value: user.username, monospaced: user.username.contains("@"))
                DetailRow(label: "Role", value: AccessUsers.role(user), copyable: false)
                DetailRow(label: "Sign-in", value: user.hasPassword ? "Password" : "Single sign-on only, no password", copyable: false)
                DetailRow(label: "Two-factor", value: user.totpEnabled ? "Authenticator on" : "Off", copyable: false)
                if let created = user.createdAt { AccountTimeRow(label: "Created", date: created) }
                DetailRow(label: "User ID", value: user.id, monospaced: true)
            } header: {
                Text("Account").accessibilityAddTraits(.isHeader)
            }

            Section {
                if user.scopes.isEmpty {
                    Text("No scopes").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget)
                }
                ForEach(AccessScopes.lines(user.scopes)) { line in
                    AccountScopeRow(line: line)
                }
            } header: {
                Text(user.scopes.count == 1 ? "Scope" : "Scopes (\(user.scopes.count))").accessibilityAddTraits(.isHeader)
            }

            AccountAllowlistSection(allowlist: user.serverAllowlist, footer: "Narrowing an account signs it out of its current sessions.")

            Section {
                WebLinkRow(title: "Edit on web", path: .users)
                WebLinkRow(title: "Delete on web", path: .users)
            } header: {
                Text("Actions").accessibilityAddTraits(.isHeader)
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(blocker.map { "The console refuses to delete it: \($0.prefix(1).lowercased() + $0.dropFirst())" }
                         ?? "Deleting it ends its sessions and revokes every token it minted.")
                    FreshnessFooter(state: store.users, interval: Polling.standard.interval(lowPower: false))
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refreshUsers() }
    }

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("User not found", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("The account was deleted, or this link names one this server does not hold.")
            } actions: {
                Button("Open on web") { router.openOnWeb(.users) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func refresh() {
        Task { await store.refreshUsers() }
    }
}
