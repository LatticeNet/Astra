import Foundation

/// The VPN writes and reveals, at the tiers of section 3.3: Rotate link T3,
/// Revoke link T4, Reveal subscription link S with Share, Reveal
/// credentials S. They live in AstraCore so checks can drive them through
/// `WriteFlow` and a mock transport.
public enum VPNIntents {
    /// Every link operation re-checks vpncore:admin, which proxy:admin also
    /// satisfies, with an unrestricted allowlist (`requireGlobalProxyScope`).
    public static let linkScope = "vpncore:admin"
    /// `reveal-credentials` checks proxy:admin with an unrestricted allowlist.
    public static let credentialsScope = "proxy:admin"
    public static let readScope = "vpncore:read"

    public static func userRef(id: String, email: String) -> ObjectRef {
        ObjectRef(kind: "vpn identity", id: id, name: email)
    }

    /// A new token for the link. The old URL answers the decoy at once, for
    /// every client that holds it. `rotatedBefore` is the rotation stamp as
    /// last read, so the verify compares server stamps, never the phone clock.
    public static func rotateLink(userID: String, email: String, rotatedBefore: Date?) -> WriteIntent {
        let ref = userRef(id: userID, email: email)
        return WriteIntent(
            tier: .t3,
            verb: "Rotate the subscription link of",
            object: ref,
            scopes: [linkScope],
            consequence: "The old link stops working at once: every client that holds it gets nothing until it is given the new link. Reveal the new link afterwards and send it again.",
            affected: [ref],
            verify: { client in
                let status = try await client.vpnLinkStatus(userID: userID)
                guard let rotated = status.link?.rotatedAt else { return "\(email)'s link shows no rotation." }
                if let rotatedBefore, rotated <= rotatedBefore { return "\(email)'s link was not rotated." }
                return "\(email)'s link was rotated."
            },
            changes: [.vpn],
            perform: { client, _ in
                do {
                    _ = try await client.vpnRotateLink(userID: userID)
                    return .done("Rotated \(email)'s link: the old link no longer works")
                } catch LatticeAPIError.notFound {
                    return .refused(.notFound, "\(email) has no subscription link to rotate. Issue one on the web.")
                }
            }
        )
    }

    /// Removes the link. The token is replaced with one nothing serves, so
    /// the revoked URL answers the decoy at once; a new link has a new URL.
    public static func revokeLink(userID: String, email: String) -> WriteIntent {
        let ref = userRef(id: userID, email: email)
        return WriteIntent(
            tier: .t4,
            verb: "Revoke the subscription link of",
            object: ref,
            scopes: [linkScope],
            consequence: "The link stops answering at once and cannot be brought back: clients holding it get nothing, and a link issued later has a new URL. The identity and its lines stay as they are.",
            affected: [ref],
            verify: { client in
                try await client.vpnLinkStatus(userID: userID).issued ? "\(email) still has a link." : "\(email)'s link is revoked."
            },
            changes: [.vpn],
            perform: { client, _ in
                do {
                    _ = try await client.vpnRevokeLink(userID: userID)
                    return .done("Revoked \(email)'s subscription link")
                } catch LatticeAPIError.notFound {
                    return .refused(.notFound, "\(email) has no subscription link to revoke.")
                }
            }
        )
    }

    /// The link once, after step-up on the session. It is meant to be sent
    /// to the person, so the value step offers Share.
    public static func revealLink(userID: String, email: String, origin: URL?) -> RevealIntent {
        RevealIntent(purpose: .vpnLink, object: userRef(id: userID, email: email), scopes: [linkScope], shareable: true) { client, grant in
            do {
                let reveal = try await client.vpnRevealLink(userID: userID, grant: grant)
                return RevealedSecret(title: "Subscription link for \(email)", value: reveal.fullURL(origin: origin), kind: .shareableLink)
            } catch LatticeAPIError.notFound {
                throw LatticeAPIError.server(status: 404, code: "link_not_issued", message: "\(email) has no subscription link. Issue one on the web.")
            }
        }
    }

    /// The identity's protocol credentials once, after step-up on the session. Copy only.
    public static func revealCredentials(userID: String, email: String) -> RevealIntent {
        RevealIntent(purpose: .vpnCredentials, object: userRef(id: userID, email: email), scopes: [credentialsScope]) { client, grant in
            let reveal = try await client.vpnRevealCredentials(userID: userID, grant: grant)
            let text = reveal.text
            guard !text.isEmpty else {
                throw LatticeAPIError.server(status: 200, code: "no_credentials", message: "\(email) holds no credential with a secret.")
            }
            return RevealedSecret(title: "Credentials for \(email)", value: text)
        }
    }
}
