import SwiftUI

/// M13 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M13 may add cases but must not rename or remove these. `line(id:)`
/// takes a line's hash id (from the Lines list) or its uuid (from M3's chains).
enum VPNRoute: Hashable, Codable, Sendable {
    case users
    case user(id: String)
    case lines
    case line(id: String)
}

/// M13's demo hooks for `-AstraPresent`: `confirm:vpn.rotateLink:<userID>`
/// (T3) and `confirm:vpn.revokeLink:<userID>` (T4) open the ConfirmSheet;
/// `reveal:vpn.link:<userID>` and `reveal:vpn.credentials:<userID>` open the
/// RevealFlow. Ids are demo identities (`vu_alice`, `vu_bob`, ...). The
/// module sheet `vpnPush:<screen>` pushes `users`, `lines`, `user:<id>` or
/// `line:<hash or uuid>` onto the selected tab (use with `-AstraTab browse`),
/// since no app link reaches the two lists.
extension VPNRoute: DemoHooks {
    static func demoIntent(_ id: String, session: SessionStore) -> WriteIntent? {
        guard session.isDemo, let (verb, argument) = demoParts(id), let user = VPNFixtures.user(argument) else { return nil }
        switch verb {
        case "rotateLink":
            return VPNIntents.rotateLink(userID: user.id, email: user.email, rotatedBefore: nil,
                                         caveat: user.linkEnabled ? nil : VPNLinkWords.pausedRotateCaveat)
        case "revokeLink": return VPNIntents.revokeLink(userID: user.id, email: user.email)
        default: return nil
        }
    }

    static func demoReveal(_ id: String) -> RevealIntent? {
        guard let (verb, argument) = demoParts(id), let user = VPNFixtures.user(argument) else { return nil }
        switch verb {
        case "link": return VPNIntents.revealLink(userID: user.id, email: user.email, origin: DemoWorld.baseURL)
        case "credentials": return VPNIntents.revealCredentials(userID: user.id, email: user.email)
        default: return nil
        }
    }

    static func demoSheet(_ name: String, argument: String?) -> AnyView? {
        guard name == "vpnPush", let argument else { return nil }
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        let rest = parts.count > 1 ? parts[1] : ""
        let route: VPNRoute? = switch parts.first {
        case "users": .users
        case "lines": .lines
        case "user": rest.isEmpty ? nil : .user(id: rest)
        case "line": rest.isEmpty ? nil : .line(id: rest)
        default: nil
        }
        return route.map { AnyView(VPNDemoPusher(route: $0)) }
    }

    private static func demoParts(_ id: String) -> (String, String)? {
        guard id.hasPrefix("vpn.") else { return nil }
        let parts = id.dropFirst("vpn.".count).split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }
}
