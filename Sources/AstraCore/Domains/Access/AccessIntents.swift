import Foundation

/// Every account write the phone makes, at the tier the parity matrix gives
/// it (section 3.2): token revoke T4, token delete T4, passkey rename T2,
/// passkey delete T4 with session step-up. Each runs through `ActionRunner`;
/// none is ever sent from a deep link, a launch or a poll. Users, SSO
/// providers, token creation, password, TOTP and passkey enrollment are
/// web-only and have no intent.
/// Whether a token is the one this iPhone's primary client carries.
public enum AccessTokenOwnership: Sendable, Hashable {
    case own, other
    /// A token credential whose `/api/me` could not be read: treated as
    /// possibly this iPhone's, so the confirmation warns and asks for the name.
    case unknown
}

public enum AccessIntents {
    public static let tokenScope = "token:admin"
    public static let userScope = "user:admin"
    public static let ssoScope = "oidc:admin"

    public static func object(_ token: LatticeToken) -> ObjectRef {
        ObjectRef(kind: "token", id: token.id, name: token.displayName)
    }

    public static func object(_ passkey: AccessPasskey) -> ObjectRef {
        ObjectRef(kind: "passkey", id: passkey.id, name: passkey.displayName)
    }

    /// The sentence the confirmation adds when the token is this iPhone's.
    public static let ownTokenWarning = "This is the token this iPhone uses. You will be signed out."

    /// The sentence when `/api/me` could not be read, so this iPhone cannot
    /// rule out that the token is its own.
    public static let maybeOwnTokenWarning = "This iPhone could not confirm which token it uses. If it is this one, you will be signed out."

    /// The sign-out warning leads, so it is the first line the confirmation
    /// shows even at the largest text size.
    private static func lead(_ ownership: AccessTokenOwnership, _ consequence: String) -> String {
        switch ownership {
        case .own: ownTokenWarning + " " + consequence
        case .unknown: maybeOwnTokenWarning + " " + consequence
        case .other: consequence
        }
    }

    // MARK: Tokens

    /// T4, the leak response. Revoking is one-way. Revoking the token this
    /// iPhone uses asks for its name to be typed and signs the phone out
    /// after the server confirms (the screen does that on `.done`).
    public static func revokeToken(_ token: LatticeToken, ownership: AccessTokenOwnership) -> WriteIntent {
        let object = object(token)
        let consequence = lead(ownership, "Anything calling the API with \(object.name) gets 401 from now on. This is one-way: nothing brings a revoked token back.")
        return WriteIntent(
            tier: .t4, verb: "Revoke token", object: object, scopes: [tokenScope],
            consequence: consequence,
            confirmPhrase: ownership == .other ? nil : object.name,
            verify: { client in
                guard let fresh = try await client.listTokens().first(where: { $0.id == token.id }) else { return "\(object.name) is no longer listed." }
                return fresh.isRevoked ? "\(object.name) is revoked." : "\(object.name) is still active."
            },
            // The server keeps the first revocation time and answers the same view again.
            idempotent: true, changes: [.tokens, .account],
            perform: { client, _ in
                let view = try await client.accessRevokeToken(id: token.id)
                guard view.isRevoked else {
                    let message = "The server answered, but \(object.name) is not revoked. Check it on the web."
                    return .unknown(message)
                }
                return .done(ownership == .own ? "Revoked \(object.name). Signing out." : "Revoked \(object.name)")
            }
        )
    }

    /// T4. Removes a revoked token from the list; the audit trail keeps it.
    public static func deleteToken(_ token: LatticeToken, ownership: AccessTokenOwnership) -> WriteIntent {
        let object = object(token)
        let consequence = lead(ownership, "Removes \(object.name) from the token list. This cannot be undone. Audit history is kept.")
        return WriteIntent(
            tier: .t4, verb: "Delete token", object: object, scopes: [tokenScope],
            consequence: consequence,
            verify: { client in
                try await client.listTokens().contains { $0.id == token.id } ? "\(object.name) is still listed." : "\(object.name) is no longer listed."
            },
            changes: [.tokens, .account],
            perform: { client, _ in
                try await client.accessDeleteToken(id: token.id)
                return .done("Deleted token \(object.name)")
            }
        )
    }

    // MARK: Passkeys

    /// T2, on the signed-in session. Renaming grants no access, so the
    /// server asks for no step-up.
    public static func renamePasskey(_ passkey: AccessPasskey, to name: String) -> WriteIntent {
        let object = object(passkey)
        return WriteIntent(
            tier: .t2, client: .session, verb: "Rename passkey", object: object, scopes: [],
            consequence: "Renames \(object.name) to \(name). It signs in exactly as before.",
            verify: { client in
                let fresh = try await client.accessListPasskeys().first { $0.id == passkey.id }
                return fresh.map { "The passkey is now named \($0.displayName)." } ?? "\(object.name) is no longer listed."
            },
            idempotent: true, changes: [.account],
            perform: { client, _ in
                let renamed = try await client.accessRenamePasskey(id: passkey.id, name: name)
                return .done("Renamed passkey to \(renamed.displayName)")
            }
        )
    }

    /// T4 on the signed-in session. With two-factor on, `grant` is the
    /// step-up grant the code step obtained; the server checks it again at
    /// send time, so a grant that expired while the operator read the
    /// confirmation is refused, and the screen returns to the code step.
    public static func deletePasskey(_ passkey: AccessPasskey, grant: StepUpGrant?) -> WriteIntent {
        let object = object(passkey)
        var consequence = "\(object.name) will no longer be able to sign in to this account. This cannot be undone."
        if grant != nil {
            consequence += " Your authenticator code was checked."
        }
        return WriteIntent(
            tier: .t4, client: .session, verb: "Delete passkey", object: object, scopes: [],
            consequence: consequence,
            verify: { client in
                try await client.accessListPasskeys().contains { $0.id == passkey.id } ? "\(object.name) is still listed." : "\(object.name) is no longer listed."
            },
            changes: [.account],
            perform: { client, _ in
                do {
                    try await client.accessDeletePasskey(id: passkey.id, stepUpGrant: grant?.grant)
                } catch let error where LatticeAPIError(error).isStepUpRequired {
                    return .refused(.stepUpRequired, stepUpExpired(object))
                }
                return .done("Deleted passkey \(object.name)")
            }
        )
    }

    public static func stepUpExpired(_ object: ObjectRef) -> String {
        "Not deleted: the server asked for a fresh authenticator code. Enter a new code to delete \(object.name)."
    }
}
