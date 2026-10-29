import SwiftUI
import UIKit

// Views and styles the M11 screens share. Shared rows come from Design/;
// these only add the account vocabulary on top of them.

enum AccountCopy {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    static func link(_ link: LatticeDeepLink) -> String {
        link.customURL?.absoluteString ?? ""
    }
}

extension LatticeConsolePath {
    /// The console's single sign-on layer of Access (it reads no `open`).
    static let accountSSO = LatticeConsolePath(path: "/settings/access", query: [URLQueryItem(name: "view", value: "sso")])
}

extension StatusStyle {
    /// Neither state earns a status color: an active token is what a token
    /// is, and a revoked one opens nothing (the console's reading).
    static func accountToken(_ token: LatticeToken) -> StatusStyle {
        token.isRevoked
            ? StatusStyle(word: "revoked", symbol: "xmark.circle", tone: .quiet)
            : StatusStyle(word: "active", symbol: "key", tone: .quiet)
    }

    static func accountUser(_ user: AccessUser) -> StatusStyle {
        user.totpEnabled
            ? StatusStyle(word: "two-factor on", symbol: "checkmark.shield", tone: .ok)
            : StatusStyle(word: "no two-factor", symbol: "exclamationmark.shield", tone: .warn)
    }

    static func accountProvider(_ provider: AccessSSOProvider) -> StatusStyle {
        guard provider.enabled else { return StatusStyle(word: "off", symbol: "minus.circle", tone: .quiet) }
        if provider.skipLocalTOTP {
            return StatusStyle(word: "skips the code", symbol: "exclamationmark.triangle.fill", tone: .warn)
        }
        if !provider.hasSecret {
            return StatusStyle(word: "no secret", symbol: "exclamationmark.triangle.fill", tone: .warn)
        }
        return StatusStyle(word: "enabled", symbol: "checkmark.circle.fill", tone: .ok)
    }

    static func accountPasskey(_ passkey: AccessPasskey) -> StatusStyle {
        passkey.backedUp
            ? StatusStyle(word: "synced", symbol: "icloud", tone: .quiet)
            : StatusStyle(word: "this device only", symbol: "key", tone: .quiet)
    }

    static func accountTwoFactor(enabled: Bool, required: Bool) -> StatusStyle {
        if required { return StatusStyle(word: "enrollment required", symbol: "xmark.shield", tone: .fail) }
        return enabled
            ? StatusStyle(word: "on", symbol: "checkmark.shield", tone: .ok)
            : StatusStyle(word: "off", symbol: "exclamationmark.shield", tone: .warn)
    }
}

/// A token in a list: state word, scopes and allowlist, and whether it is this iPhone's.
struct AccountTokenRow: View {
    let token: LatticeToken
    let isOwn: Bool

    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        let style = StatusStyle.accountToken(token)
        var parts = [AccessTokens.detail(token)]
        let risks = AccessScopes.risks(token.scopes).map(\.scope).filter { $0 != "*" }
        if !risks.isEmpty, !token.isRevoked { parts.append("holds \(risks.joined(separator: " and "))") }
        if let revoked = token.revokedAt {
            parts.append("revoked \(TimeDisplay.relative(revoked, now: Date(), locale: locale))")
        } else if let created = token.createdAt {
            parts.append("created \(TimeDisplay.relative(created, now: Date(), locale: locale))")
        }
        // VoiceOver hears what the detail line shows, since StatusRow speaks only the phrase.
        let spoken = ["Token \(token.displayName)", style.word] + (isOwn ? ["used by this iPhone"] : []) + parts
        return StatusRow(
            style: style,
            title: token.displayName,
            detail: ((isOwn ? ["This iPhone"] : []) + parts).joined(separator: ", "),
            accessibilityPhrase: spoken.joined(separator: ", ")
        )
    }
}

/// An operator account: two-factor state, role, sign-in and confinement.
struct AccountUserRow: View {
    let user: AccessUser
    let isSelf: Bool

    var body: some View {
        let style = StatusStyle.accountUser(user)
        var parts = [AccessUsers.role(user), user.hasPassword ? "password" : "SSO only"]
        if AccessAllowlist.isConfined(user.serverAllowlist) { parts.append(AccessAllowlist.summary(user.serverAllowlist).lowercased()) }
        let spoken = ["User \(user.displayName)", style.word] + (isSelf ? ["your account"] : []) + parts
        return StatusRow(
            style: style,
            title: user.displayName,
            detail: ((isSelf ? ["You"] : []) + parts).joined(separator: ", "),
            titleIsIdentifier: user.displayName.contains("@"),
            accessibilityPhrase: spoken.joined(separator: ", ")
        )
    }
}

/// An identity provider: its state, issuer host and what to know about it.
struct AccountProviderRow: View {
    let provider: AccessSSOProvider

    var body: some View {
        let style = StatusStyle.accountProvider(provider)
        let host = URL(string: provider.issuer)?.host() ?? provider.issuer
        return StatusRow(
            style: style,
            title: provider.title,
            detail: host,
            reason: style.tone.isProblem ? AccessSSO.notices(provider).first : nil,
            accessibilityPhrase: "Provider \(provider.title), \(style.word), \(host)"
        )
    }
}

/// A passkey: where it lives and when it last signed in.
struct AccountPasskeyRow: View {
    let passkey: AccessPasskey

    @Environment(\.locale) private var locale

    var body: some View {
        let style = StatusStyle.accountPasskey(passkey)
        let used = passkey.lastUsedAt.map { "used \(TimeDisplay.relative($0, now: Date(), locale: locale))" } ?? "never used"
        return StatusRow(
            style: style,
            title: passkey.displayName,
            detail: used,
            accessibilityPhrase: "Passkey \(passkey.displayName), \(style.word), \(used)"
        )
    }
}

/// One scope: its id, the resource group and what it grants.
struct AccountScopeRow: View {
    let line: AccessScopeLine

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(DetailRow.breakable(line.scope))
                    .font(TextRole.identifierInDetail.font)
                if line.sensitive {
                    Label("sensitive", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(AccountInlineLabelStyle())
                        .font(.footnote)
                        .foregroundStyle(Color.statusWarnText)
                }
            }
            Text(line.known ? "\(line.title): \(line.detail)" : line.detail)
                .textRole(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(line.scope)\(line.sensitive ? ", sensitive" : ""). \(line.title). \(line.detail)")
    }
}

/// Glyph and word on one baseline, the glyph tinted by its own style.
struct AccountInlineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            configuration.icon.foregroundStyle(Color.statusWarnFill)
            configuration.title
        }
    }
}

/// A notice inside a section: a glyph and a wrapping sentence in the tone's color.
struct AccountNoticeRow: View {
    let text: String
    var symbol = "exclamationmark.triangle.fill"
    var tone: StatusTone = .warn

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(tone.isProblem ? tone.word : .primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tone.glyph)
        }
        .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
    }
}

/// An absolute time with the other zone underneath (section 6.16).
struct AccountTimeRow: View {
    let label: String
    let date: Date

    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        DetailRow(label: label, value: TimeDisplay.dateTime(date, mode: mode, locale: locale),
                  secondary: TimeDisplay.otherZone(date, mode: mode, locale: locale), copyable: false)
    }
}

/// The node allowlist of a token or account, by name where the fleet is known.
struct AccountAllowlistSection: View {
    let allowlist: [String]
    var footer: String

    @Environment(NodeDirectory.self) private var nodes

    var body: some View {
        let ids = allowlist.filter { $0 != "*" }
        Section {
            if ids.isEmpty || allowlist.contains("*") {
                DetailRow(label: "Reach", value: "All nodes", copyable: false)
            } else {
                ForEach(ids, id: \.self) { id in
                    let name = nodes.name(for: id)
                    DetailRow(label: name == id ? "Unknown node" : name, value: id, monospaced: true)
                }
            }
        } header: {
            Text(ids.isEmpty ? "Nodes" : "Nodes (\(ids.count))").accessibilityAddTraits(.isHeader)
        } footer: {
            Text(footer)
        }
        .task { await nodes.refreshIfOlder(than: 15) }
    }
}

/// A menu button for a write: disabled with the reason as its subtitle when
/// the write is unavailable (section 4.5).
struct AccountGatedButton: View {
    let title: String
    let systemImage: String
    let blocker: String?
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            if let blocker {
                Label {
                    Text(title)
                    Text(blocker)
                } icon: {
                    Image(systemName: systemImage)
                }
            } else {
                Label(title, systemImage: systemImage)
            }
        }
        .disabled(blocker != nil)
    }
}

/// A write in a detail screen's Actions section: verb, consequence or the
/// reason it is unavailable, at least 44 pt tall.
struct AccountActionButton: View {
    let title: String
    let systemImage: String
    let note: String?
    let blocker: String?
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title)
                    if let line = blocker ?? note {
                        Text(line).textRole(.footnote).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } icon: {
                Image(systemName: systemImage)
            }
            .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
        }
        .disabled(blocker != nil)
    }
}

/// A failed refresh above data that is kept (section 5.0).
struct AccountRefreshError<Value: Sendable>: View {
    let state: ResourceState<Value>
    let noun: String
    let retry: () -> Void

    var body: some View {
        if case .failed(let error, .some, _) = state {
            Section { ErrorRow(message: "Could not refresh \(noun): \(error.localizedDescription)", retry: retry) }
        }
    }
}

/// The search field's grammar problem, in words, with the fields to use.
struct AccountQueryProblemRow: View {
    let error: LatticeQueryError
    let fields: String

    var body: some View {
        Section {
            let field = error.params["field"].map { "\($0): is not a field here, so the search shows every row." } ?? "The search could not be read, so it shows every row."
            AccountNoticeRow(text: "\(field) Fields: \(fields).", symbol: "exclamationmark.triangle")
        }
    }
}

extension String {
    /// "skips the code" to "Skips the code", for a subtitle.
    var accountCapitalized: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
