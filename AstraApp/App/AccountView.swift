import SwiftUI

/// Account & access surface pushed inside MoreHub's NavigationStack. Surfaces the
/// signed-in identity, server build, and personal access tokens, plus token
/// creation/revocation and sign-out. Not wrapped in its own NavigationStack.
struct AccountView: View {
    @EnvironmentObject private var model: DashboardModel

    @State private var showCreateToken = false
    @State private var tokenPendingRevoke: LatticeToken?

    var body: some View {
        List {
            if model.isLoading("account") || model.error(for: "account") != nil {
                Section {
                    InlineStatusView(isLoading: model.isLoading("account"), error: model.error(for: "account"))
                }
            }

            identitySection
            serverSection
            tokensSection

            Section {
                Button(role: .destructive) {
                    model.signOut()
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Account")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateToken = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!model.configured)
            }
        }
        .task { if model.configured { await model.loadAccount() } }
        .refreshable { await model.loadAccount() }
        .sheet(isPresented: $showCreateToken) {
            CreateTokenView()
        }
        .confirmationDialog(
            "Revoke this token?",
            isPresented: Binding(
                get: { tokenPendingRevoke != nil },
                set: { if !$0 { tokenPendingRevoke = nil } }
            ),
            titleVisibility: .visible,
            presenting: tokenPendingRevoke
        ) { token in
            Button("Revoke", role: .destructive) {
                let id = token.id
                tokenPendingRevoke = nil
                Task { await model.revokeToken(tokenID: id) }
            }
            Button("Cancel", role: .cancel) { tokenPendingRevoke = nil }
        } message: { token in
            Text("\(token.name.isEmpty ? token.id : token.name) will stop working immediately. This cannot be undone.")
        }
    }

    // MARK: - Identity

    @ViewBuilder
    private var identitySection: some View {
        if let identity = model.identity {
            Section {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Theme.brandGradient)
                            .frame(width: 44, height: 44)
                        Text(initials(for: identity.displayName))
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(identity.displayName)
                            .font(.headline)
                        if !identity.actorID.isEmpty {
                            Text(identity.actorID)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 2)

                DetailRow(label: "Actor", value: identity.actorID, monospaced: true, copyable: true)

                if let authKind = identity.authKind, !authKind.isEmpty {
                    DetailRow(label: "Auth", value: authKind)
                }

                DetailRow(label: "2FA", value: identity.totpEnabled ? "Enabled" : "Disabled")

                if !identity.scopes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scopes")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ScopeChips(scopes: identity.scopes)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Identity")
            }
        } else if !model.isLoading("account") {
            Section {
                AstraEmptyStateView(
                    title: "Not signed in",
                    systemImage: "person.crop.circle.badge.questionmark",
                    message: model.configured
                        ? "Pull to refresh to load your Lattice identity."
                        : "Connect to Lattice in More → Settings to view your account."
                )
            } header: {
                Text("Identity")
            }
        }
    }

    // MARK: - Server

    @ViewBuilder
    private var serverSection: some View {
        if let version = model.serverVersion,
           !(version.version.isEmpty && version.shortCommit.isEmpty && version.date.isEmpty) {
            Section {
                if !version.version.isEmpty {
                    DetailRow(label: "Version", value: version.version)
                }
                if !version.shortCommit.isEmpty {
                    DetailRow(label: "Commit", value: version.shortCommit, monospaced: true, copyable: true)
                }
                if !version.date.isEmpty {
                    DetailRow(label: "Built", value: version.date)
                }
            } header: {
                Text("Server")
            }
        }
    }

    // MARK: - Tokens

    @ViewBuilder
    private var tokensSection: some View {
        Section {
            if model.tokens.isEmpty {
                if !model.isLoading("account") {
                    Text("No personal access tokens. Tap + to mint one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.tokens) { token in
                    TokenRow(token: token)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !token.isRevoked {
                                Button(role: .destructive) {
                                    tokenPendingRevoke = token
                                } label: {
                                    Label("Revoke", systemImage: "trash")
                                }
                            }
                        }
                }
            }
        } header: {
            Text("Tokens")
        } footer: {
            if !model.tokens.isEmpty {
                Text("Swipe a token to revoke it. Revoked tokens stop authenticating immediately.")
            }
        }
    }

    private func initials(for name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        let letters = parts.prefix(2).compactMap { $0.first }
        let result = String(letters).uppercased()
        return result.isEmpty ? "?" : result
    }
}

// MARK: - Token row

struct TokenRow: View {
    var token: LatticeToken

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(token.name.isEmpty ? token.id : token.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if token.isRevoked {
                    StatusPill(text: "revoked", systemImage: "nosign", color: Theme.disabled)
                }
            }

            HStack(spacing: 8) {
                Label("\(token.scopes.count) scope\(token.scopes.count == 1 ? "" : "s")", systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let created = token.createdAt {
                    Spacer(minLength: 0)
                    Text(RelativeDateFormatter.string(from: created))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Scope chips (iOS 16 wrapping via adaptive grid)

struct ScopeChips: View {
    var scopes: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(scopes, id: \.self) { scope in
                Text(scope)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
                    .foregroundStyle(Theme.accentDeep)
            }
        }
    }
}

// MARK: - Create token

struct CreateTokenView: View {
    @EnvironmentObject private var model: DashboardModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selectedScopes: Set<String> = []
    @State private var allowlistText = ""
    @State private var created: CreatedTokenResponse?
    @State private var working = false

    private let commonScopes = [
        "node:read", "node:admin",
        "inventory:read", "inventory:admin",
        "monitor:read", "monitor:admin",
        "audit:read", "token:admin",
        "log:read", "notify:send",
        "geo:read", "geo:admin"
    ]

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !selectedScopes.isEmpty && !working
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Token name", text: $name)
                        .autocorrectionDisabled()
                } header: {
                    Text("Name")
                } footer: {
                    Text("A label to recognise this token later, e.g. \"laptop-cli\".")
                }

                Section {
                    ForEach(commonScopes, id: \.self) { scope in
                        Button {
                            toggle(scope)
                        } label: {
                            HStack {
                                Text(scope)
                                    .font(.subheadline.monospaced())
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selectedScopes.contains(scope) {
                                    Image(systemName: "checkmark")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Scopes")
                } footer: {
                    Text("Grant only what this token needs. \(selectedScopes.count) selected.")
                }

                Section {
                    TextField("server allowlist (comma separated)", text: $allowlistText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server allowlist")
                } footer: {
                    Text("Optional. Restrict this token to specific server IDs. Leave empty for no restriction.")
                }

                Section {
                    Button {
                        Task { await create() }
                    } label: {
                        HStack {
                            if working { ProgressView() }
                            Text("Create token")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(!canCreate)
                }
            }
            .navigationTitle("New token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(item: $created, onDismiss: { dismiss() }) { created in
                TokenRevealSheet(title: "New token", token: created.token, command: nil)
            }
        }
    }

    private func toggle(_ scope: String) {
        if selectedScopes.contains(scope) {
            selectedScopes.remove(scope)
        } else {
            selectedScopes.insert(scope)
        }
    }

    private func create() async {
        working = true
        defer { working = false }
        let allowlist = allowlistText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        created = await model.createToken(
            name: name.trimmingCharacters(in: .whitespaces),
            scopes: Array(selectedScopes),
            serverAllowlist: allowlist
        )
    }
}
