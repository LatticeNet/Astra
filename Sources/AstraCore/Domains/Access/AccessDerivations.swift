import Foundation

// Pure derivations behind M11's screens, ported from the console's
// `views/settings/{TokensView,UsersView,SsoView,SecurityView}.vue` and
// checked in AccessChecks.

// MARK: Scopes

/// One scope as TokenDetail and UserDetail explain it.
public struct AccessScopeLine: Sendable, Hashable, Identifiable {
    public var scope: String
    /// The resource group ("Nodes"), or a phrase for wildcards.
    public var title: String
    public var detail: String
    /// Dangerous out of proportion to its name (`ScopeCatalogue` plus the
    /// scopes ScopeSummary warns about).
    public var sensitive: Bool
    /// False for a scope this app's catalogue does not describe.
    public var known: Bool

    public var id: String { scope }
}

public enum AccessScopes {
    /// The scopes ScopeSummary warns about, each with what it permits
    /// through the API (F-05), plus the two that make a token a superuser.
    public static let warnings: [(scope: String, sentence: String)] = [
        ("*", "This token can do anything an administrator can, including minting tokens and managing users."),
        ("token:admin", "This token can mint other tokens that outlive it, and revoke any token."),
        ("user:admin", "This token can create operator accounts and change their scopes."),
        ("plugin:admin", "This token can install, enable and invoke plugins, which run code on the control plane."),
        ("oidc:admin", "This token can change who signs in through single sign-on."),
        ("task:run", "This token can run scripts as root on every node it can see."),
        ("terminal:open", "This token can open root shells through the API."),
        ("secrets:reveal", "This token can read secrets without a second factor."),
    ]

    public static func describe(_ scope: String) -> AccessScopeLine {
        if scope == "*" {
            return AccessScopeLine(scope: scope, title: "Full administrator", detail: "Every scope, now and in later server versions, except secrets:reveal, which must be named.", sensitive: true, known: true)
        }
        if scope.hasSuffix(":*") {
            let area = String(scope.dropLast(2))
            let title = ScopeCatalogue.entries.first { $0.scope.hasPrefix(area + ":") }?.title ?? area
            return AccessScopeLine(scope: scope, title: title, detail: "Every \(area) scope.", sensitive: true, known: true)
        }
        let warned = warnings.contains { $0.scope == scope }
        if let entry = ScopeCatalogue.entry(for: scope) {
            return AccessScopeLine(scope: scope, title: entry.title, detail: entry.detail, sensitive: entry.sensitive || warned, known: true)
        }
        if let warning = warnings.first(where: { $0.scope == scope }) {
            return AccessScopeLine(scope: scope, title: "Platform and access", detail: warning.sentence, sensitive: true, known: true)
        }
        return AccessScopeLine(scope: scope, title: "Other", detail: "Not described by this app. The server decides what it grants.", sensitive: false, known: false)
    }

    /// Every scope explained, in the catalogue's order; unknown scopes last, by name.
    public static func lines(_ scopes: [String]) -> [AccessScopeLine] {
        let order = Dictionary(ScopeCatalogue.entries.enumerated().map { ($1.scope, $0) }, uniquingKeysWith: { first, _ in first })
        func rank(_ scope: String) -> Int {
            if scope == "*" { return -2 }
            if scope.hasSuffix(":*") { return -1 }
            return order[scope] ?? Int.max
        }
        return Array(Set(scopes)).sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0 < $1 }.map(describe)
    }

    /// "Full administrator", "1 scope", "12 scopes", "No scopes".
    public static func summary(_ scopes: [String]) -> String {
        if scopes.contains("*") { return "Full administrator" }
        switch scopes.count {
        case 0: return "No scopes"
        case 1: return "1 scope"
        default: return "\(scopes.count) scopes"
        }
    }

    /// The warned scopes a set holds, in the order of `warnings`.
    public static func risks(_ scopes: [String]) -> [(scope: String, sentence: String)] {
        warnings.filter { scopes.contains($0.scope) }
    }
}

// MARK: Node allowlists

public enum AccessAllowlist {
    /// "All nodes" or "Confined to 12 nodes". A `*` entry means unconfined.
    public static func summary(_ allowlist: [String]) -> String {
        let ids = allowlist.filter { $0 != "*" }
        if ids.isEmpty || allowlist.contains("*") { return "All nodes" }
        return ids.count == 1 ? "Confined to 1 node" : "Confined to \(ids.count) nodes"
    }

    public static func isConfined(_ allowlist: [String]) -> Bool {
        !allowlist.isEmpty && !allowlist.contains("*")
    }
}

// MARK: Tokens

public enum AccessTokenState: String, Sendable, Hashable, CaseIterable {
    case active, revoked
}

public enum AccessTokens {
    public static func state(_ token: LatticeToken) -> AccessTokenState {
        token.isRevoked ? .revoked : .active
    }

    /// Active first, then newest first (`sortedTokens` in TokensView).
    public static func sorted(_ tokens: [LatticeToken]) -> [LatticeToken] {
        tokens.sorted { a, b in
            if a.isRevoked != b.isRevoked { return !a.isRevoked }
            let ad = a.createdAt ?? .distantPast
            let bd = b.createdAt ?? .distantPast
            if ad != bd { return ad > bd }
            return a.displayName.localizedCompare(b.displayName) == .orderedAscending
        }
    }

    /// Whether `token` is the credential this iPhone's primary client carries.
    /// `/api/me` names it in `token_id`; a session has none.
    public static func isOwn(_ token: LatticeToken, identity: LatticeIdentity?) -> Bool {
        guard let identity, !identity.tokenID.isEmpty else { return false }
        return identity.tokenID == token.id
    }

    /// Own, another's, or unknown when the credential is a token whose
    /// `/api/me` has not been read: a session carries no token at all.
    public static func ownership(_ token: LatticeToken, credentialIsToken: Bool, identity: LatticeIdentity?) -> AccessTokenOwnership {
        guard credentialIsToken else { return .other }
        guard let identity else { return .unknown }
        return isOwn(token, identity: identity) ? .own : .other
    }

    /// "7 tokens, 5 active" (the console's proof line).
    public static func summary(_ tokens: [LatticeToken]) -> String {
        let active = tokens.filter { !$0.isRevoked }.count
        let total = tokens.count == 1 ? "1 token" : "\(tokens.count) tokens"
        return tokens.isEmpty ? total : "\(total), \(active) active"
    }

    /// Why Delete is unavailable, or nil when it is: only a revoked token can
    /// be deleted (`handleDeleteToken` answers 409 otherwise).
    public static func deleteBlocker(_ token: LatticeToken) -> String? {
        token.isRevoked ? nil : "Revoke it first. Only a revoked token can be deleted."
    }

    /// The second line of a token row: scopes and allowlist.
    public static func detail(_ token: LatticeToken) -> String {
        "\(AccessScopes.summary(token.scopes)), \(AccessAllowlist.summary(token.serverAllowlist).lowercasedFirst)"
    }
}

/// Query fields for the token list (section 6.14): `state:revoked`,
/// `scope:task:run`, `is:confined`, `created<30d`.
public enum AccessTokenQueryFields: QueryFieldProvider {
    public static var fields: [LatticeQueryField<LatticeToken>] {
        [
            LatticeQueryField(key: "state", aliases: ["status"], type: .enumeration, values: AccessTokenState.allCases.map(\.rawValue)) {
                .string(AccessTokens.state($0).rawValue)
            },
            LatticeQueryField(key: "name", type: .string) { .string($0.displayName) },
            LatticeQueryField(key: "scope", aliases: ["scopes"], type: .list) { .strings($0.scopes) },
            LatticeQueryField(key: "actor", type: .string) { .string($0.actorID) },
            LatticeQueryField(key: "node", aliases: ["allowlist"], type: .list) { .strings($0.serverAllowlist) },
            LatticeQueryField(key: "confined", type: .bool, flag: true) { .bool(AccessAllowlist.isConfined($0.serverAllowlist)) },
            LatticeQueryField(key: "revoked", type: .bool, flag: true) { .bool($0.isRevoked) },
            LatticeQueryField(key: "admin", type: .bool, flag: true) { .bool($0.scopes.contains("*")) },
            LatticeQueryField(key: "created", type: .time) { $0.createdAt.map { .time($0) } ?? .none },
        ]
    }

    public static func text(_ row: LatticeToken) -> [String] {
        [row.displayName, row.id, row.actorID] + row.scopes
    }
}

// MARK: Users

public enum AccessUsers {
    public static func isFullAdmin(_ user: AccessUser) -> Bool {
        user.scopes.contains("*")
    }

    /// "Full administrator" or the scope count.
    public static func role(_ user: AccessUser) -> String {
        AccessScopes.summary(user.scopes)
    }

    /// "Password" or "SSO only".
    public static func signIn(_ user: AccessUser) -> String {
        user.hasPassword ? "Password" : "SSO only"
    }

    /// The account the credential on this iPhone belongs to.
    public static func isSelf(_ user: AccessUser, actorID: String?) -> Bool {
        guard let actorID, !actorID.isEmpty else { return false }
        return user.id == actorID
    }

    /// Why the console refuses to delete this account, if it does.
    public static func deleteBlocker(_ user: AccessUser, users: [AccessUser], actorID: String?) -> String? {
        if isSelf(user, actorID: actorID) { return "This is the account you are signed in with." }
        if isFullAdmin(user), users.filter(isFullAdmin).count <= 1 { return "The last full administrator cannot be deleted." }
        return nil
    }

    /// "4 users, 1 full administrator, 2 of 4 with two-factor".
    public static func summary(_ users: [AccessUser]) -> String {
        let total = users.count == 1 ? "1 user" : "\(users.count) users"
        guard !users.isEmpty else { return total }
        let admins = users.filter(isFullAdmin).count
        let adminText = admins == 1 ? "1 full administrator" : "\(admins) full administrators"
        let totp = users.filter(\.totpEnabled).count
        return "\(total), \(adminText), \(totp) of \(users.count) with two-factor"
    }

    /// Accounts without two-factor first, then full administrators, then by name.
    public static func sorted(_ users: [AccessUser]) -> [AccessUser] {
        users.sorted { a, b in
            if a.totpEnabled != b.totpEnabled { return !a.totpEnabled }
            if isFullAdmin(a) != isFullAdmin(b) { return isFullAdmin(a) }
            return a.displayName.localizedCompare(b.displayName) == .orderedAscending
        }
    }
}

public enum AccessUserQueryFields: QueryFieldProvider {
    public static var fields: [LatticeQueryField<AccessUser>] {
        [
            LatticeQueryField(key: "name", aliases: ["username", "user"], type: .string) { .string($0.username) },
            LatticeQueryField(key: "scope", aliases: ["scopes"], type: .list) { .strings($0.scopes) },
            LatticeQueryField(key: "login", type: .enumeration, values: ["password", "sso"]) { .string($0.hasPassword ? "password" : "sso") },
            LatticeQueryField(key: "totp", aliases: ["2fa", "mfa"], type: .bool, flag: true) { .bool($0.totpEnabled) },
            LatticeQueryField(key: "admin", type: .bool, flag: true) { .bool(AccessUsers.isFullAdmin($0)) },
            LatticeQueryField(key: "confined", type: .bool, flag: true) { .bool(AccessAllowlist.isConfined($0.serverAllowlist)) },
            LatticeQueryField(key: "created", type: .time) { $0.createdAt.map { .time($0) } ?? .none },
        ]
    }

    public static func text(_ row: AccessUser) -> [String] {
        [row.username, row.id]
    }
}

// MARK: SSO providers

public enum AccessSSO {
    /// "2 providers, 1 enabled, 1 skips the authenticator code".
    public static func summary(_ providers: [AccessSSOProvider]) -> String {
        let total = providers.count == 1 ? "1 provider" : "\(providers.count) providers"
        guard !providers.isEmpty else { return total }
        var parts = [total, "\(providers.filter(\.enabled).count) enabled"]
        let skipping = providers.filter { $0.enabled && $0.skipLocalTOTP }.count
        if skipping > 0 {
            parts.append(skipping == 1 ? "1 skips the authenticator code" : "\(skipping) skip the authenticator code")
        }
        return parts.joined(separator: ", ")
    }

    /// What an operator should know about a provider, worst first.
    public static func notices(_ provider: AccessSSOProvider) -> [String] {
        var notices: [String] = []
        if provider.skipLocalTOTP {
            notices.append(provider.enabled
                ? "Skips the authenticator code: anyone signed in to an operator's account at this provider can open the console without it."
                : "Skips the authenticator code once enabled.")
        }
        if !provider.hasSecret {
            notices.append("No client secret is stored. Sign-in works only if the provider accepts Lattice as a public client.")
        }
        return notices
    }

    /// "Any verified email domain" or the list.
    public static func domains(_ provider: AccessSSOProvider) -> String {
        provider.allowedDomains.isEmpty ? "Any verified email domain" : provider.allowedDomains.joined(separator: ", ")
    }

    /// Enabled first, then by title.
    public static func sorted(_ providers: [AccessSSOProvider]) -> [AccessSSOProvider] {
        providers.sorted { a, b in
            if a.enabled != b.enabled { return a.enabled }
            return a.title.localizedCompare(b.title) == .orderedAscending
        }
    }
}

// MARK: Passkeys

public enum AccessPasskeys {
    /// Most recently used first; never-used passkeys after, newest first.
    public static func sorted(_ passkeys: [AccessPasskey]) -> [AccessPasskey] {
        passkeys.sorted { a, b in
            switch (a.lastUsedAt, b.lastUsedAt) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return (a.createdAt ?? .distantPast) > (b.createdAt ?? .distantPast)
            }
        }
    }

    /// "Synced" for a passkey a provider syncs, else "This device only".
    public static func storage(_ passkey: AccessPasskey) -> String {
        passkey.backedUp ? "Synced" : "This device only"
    }

    /// How it connects, in words: "built in, nearby device".
    public static func transports(_ passkey: AccessPasskey) -> String {
        let words: [String: String] = ["internal": "built in", "hybrid": "nearby device", "usb": "USB", "nfc": "NFC", "ble": "Bluetooth", "smart-card": "smart card"]
        let named = passkey.transports.map { words[$0] ?? $0 }
        return named.isEmpty ? "Not reported" : named.joined(separator: ", ")
    }

    /// A rename the server would accept: trimmed, non-empty, changed.
    /// The server clamps the length itself.
    public static func renameValue(_ text: String, current: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != current else { return nil }
        return trimmed
    }
}

public enum AccessTime {
    /// `TimeDisplay.dateTime` with the year added when the date falls in
    /// another year, since token and account age is a security judgment and
    /// "Sep 22" alone reads as last month.
    public static func dateTime(_ date: Date, now: Date, mode: TimeZoneMode, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = mode.timeZone
        guard calendar.component(.year, from: date) != calendar.component(.year, from: now) else {
            return TimeDisplay.dateTime(date, mode: mode, locale: locale)
        }
        var style = Date.FormatStyle.dateTime.locale(locale)
        style.timeZone = mode.timeZone
        let text = date.formatted(style.year().month(.abbreviated).day().hour().minute())
        return mode == .utc ? text + " UTC" : text
    }
}

/// The steps of a passkey delete inside the Settings sheet (section 5.12).
public enum AccessPasskeyDeleteStep: String, Sendable, Hashable {
    /// The authenticator code, through `StepUpCoordinator`.
    case code
    /// The T4 ConfirmPage naming the passkey.
    case confirm
    /// Face ID or the passcode.
    case authenticate
    /// `POST /credentials/delete`.
    case send
}

public enum AccessPasskeyDeletePlan {
    /// The confirmation and Face ID sit between choosing the steps and the
    /// send, and the server's grant lives 60 s, so a held grant is reused
    /// only with this much left. Section 6.4's 5 s margin fits a reveal,
    /// which sends at once.
    public static let heldGrantMargin: TimeInterval = 40

    /// The held grant when it can outlast the confirmation, else nil.
    public static func reusableGrant(_ grant: StepUpGrant?, now: Date) -> StepUpGrant? {
        guard let grant, grant.isUsable(now: now, margin: heldGrantMargin) else { return nil }
        return grant
    }

    /// With two-factor on the server needs a step-up grant; the code step
    /// runs first unless a reusable grant is held. With the two-factor state
    /// unknown the code is not asked up front: step-up answers 403 for an
    /// account without TOTP, and the server deletes without a grant then.
    /// A `step_up_required` refusal brings the code step back once.
    public static func steps(totpEnabled: Bool?, grantUsable: Bool) -> [AccessPasskeyDeleteStep] {
        let needsCode = totpEnabled == true && !grantUsable
        return (needsCode ? [.code] : []) + [.confirm, .authenticate, .send]
    }

    /// Whether the delete request carries a held grant. Only an account
    /// known to have two-factor off sends none.
    public static func sendsGrant(totpEnabled: Bool?) -> Bool {
        totpEnabled != false
    }
}

fileprivate extension String {
    /// "All nodes" to "all nodes", for the middle of a sentence.
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
