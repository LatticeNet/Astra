import SwiftUI
import UIKit

/// F-05: what each credential can and cannot do, from `/api/me` on each client.
struct ScopeSummaryScreen: View {
    var body: some View {
        List { ScopeSummaryContent() }
            .navigationTitle("Token scopes")
    }
}

/// The summary's sections, shared with the welcome flow.
struct ScopeSummaryContent: View {
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router

    /// Scopes that let a token do more than its holder may expect (section 6.12).
    private static let risky: [(scope: String, warning: String)] = [
        ("task:run", "task:run: this token can run scripts as root on every node it can see."),
        ("terminal:open", "terminal:open: this token can open root shells through the API."),
        ("token:admin", "token:admin: this token can mint other tokens that outlive it."),
        ("user:admin", "user:admin: this token can create and change user accounts."),
        ("plugin:admin", "plugin:admin: this token can activate and disable plugins."),
    ]

    var body: some View {
        if let identity = session.primaryIdentity {
            credentialSections(identity, title: session.credentialKind == .session ? "Signed-in session" : "API token")
        } else if let error = session.identityError {
            Section {
                ErrorRow(message: "Could not read this credential's scopes: \(error.localizedDescription)") {
                    Task { await session.refreshIdentity() }
                }
            }
        } else {
            Section { LoadingRows(label: "Loading scopes", count: 2) }
        }
        if session.credentialKind == .token, let identity = session.sessionIdentity {
            credentialSections(identity, title: "Signed-in session (reveals only)")
        }
        presets
    }

    @ViewBuilder
    private func credentialSections(_ identity: LatticeIdentity, title: String) -> some View {
        let scopes = identity.scopeSet
        Section {
            DetailRow(label: "Actor", value: identity.displayName, copyable: false)
            if scopes.isConfined {
                Label("Confined to \(identity.serverAllowlist.count) nodes", systemImage: "scope")
            }
            let hidden = ApprovalVisibility.hiddenPlugins(scopes: scopes)
            if !hidden.isEmpty {
                Label {
                    Text(AccessState.partial(plugins: hidden.joined(separator: ", ")).text)
                } icon: {
                    Image(systemName: "eye.slash").foregroundStyle(Color.statusQuiet)
                }
            }
            ForEach(Self.risky.filter { scopes.scopes.contains($0.scope) }, id: \.scope) { item in
                Label {
                    Text(item.warning).foregroundStyle(Color.statusWarnText)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarnFill)
                }
            }
        } header: {
            Text(title)
        }
        capabilities(scopes)
        Section("Scopes (\(identity.scopes.count))") {
            ForEach(identity.scopes.sorted(), id: \.self) { scope in
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(scope).textRole(.identifierInRow)
                    if let entry = ScopeCatalogue.entry(for: scope) {
                        Text(entry.detail).textRole(.footnote)
                    }
                }
            }
        }
    }

    /// One row per native action of the parity matrix, grouped by page.
    @ViewBuilder
    private func capabilities(_ scopes: ScopeSet) -> some View {
        let rows = ParityMatrix.nativeRows
        if rows.isEmpty {
            Section("Capabilities") {
                Text("The capability list appears once the parity matrix ships in this build.")
                    .foregroundStyle(.secondary)
            }
        } else {
            let pages = Dictionary(grouping: rows, by: \.page)
            ForEach(pages.keys.sorted(), id: \.self) { page in
                Section(page) {
                    ForEach(pages[page] ?? [], id: \.self) { row in
                        let missing = scopes.missing(ScopeRequirement(groups: row.scopes.map { [$0] }))
                        StatusRow(
                            style: missing.isEmpty
                                ? StatusStyle(word: "can", symbol: "checkmark.circle", tone: .ok)
                                : StatusStyle(word: "cannot", symbol: "minus.circle", tone: .quiet),
                            title: row.action,
                            detail: missing.isEmpty ? "Uses \(row.scopes.joined(separator: ", "))" : "Needs \(missing.joined(separator: ", ")), missing"
                        )
                    }
                }
            }
        }
    }

    private var presets: some View {
        Section {
            ForEach(TokenPresets.all) { preset in
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack {
                        Text(preset.title).font(.headline)
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = preset.copyText }
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline)
                    }
                    Text(preset.copyText)
                        .textRole(.identifierInRow)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let warning = preset.warning {
                        Text(warning).textRole(.rowReason(.statusWarnText))
                    }
                }
                .padding(.vertical, Spacing.xs)
            }
            Button("Manage tokens on web") { router.openOnWeb(.tokens) }
        } header: {
            Text("Token presets")
        } footer: {
            Text("Never add secrets:reveal, notify:send or token:admin to a phone token.")
        }
    }
}
