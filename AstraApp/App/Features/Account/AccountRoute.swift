import SwiftUI

/// M11 routes, hosted only in the Settings sheet's stack (section 2.4). The
/// cases declared in M0 are frozen; M11 may add cases but must not rename or
/// remove these.
enum AccountRoute: Hashable, Codable, Sendable {
    case security
    case passkey(id: String)
    case access(view: String?)
    case user(id: String)
    case token(id: String)
    case ssoProvider(id: String)
    /// The code step of a passkey delete, pushed from PasskeyDetail when two-factor is on.
    case passkeyDeleteCode(id: String)
}

/// Demo hooks (section 9.2), honored only in demo mode:
///
/// - `-AstraPresent account:<page>` opens the Settings sheet at an account
///   page: `security`, `passkey:<id>`, `passkeyCode:<id>`, `access`,
///   `access:users|tokens|sso`, `token:<id>`, `user:<id>`, `sso:<id>`;
///   `token:<id>:revoke` and `token:<id>:delete` then start that write
///   inside the sheet, so its ConfirmPage can be captured.
/// - `-AstraPresent confirm:account.revokeToken.<id>` and
///   `confirm:account.deleteToken.<id>` start those writes on a demo token,
///   with the own-token warning when it is the phone's.
extension AccountRoute: DemoHooks {
    static func demoIntent(_ id: String, session: SessionStore) -> WriteIntent? {
        guard session.isDemo else { return nil }
        let parts = id.split(separator: ".", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "account",
              let fixture = AccessFixtures.tokens.first(where: { $0.id == parts[2] }) else { return nil }
        let token = LatticeToken(id: fixture.id, name: fixture.name, actorID: fixture.actorID, scopes: fixture.scopes,
                                 serverAllowlist: fixture.allowlist, revokedAt: fixture.revoked == nil ? nil : Date())
        let ownership = AccessTokens.ownership(token, credentialIsToken: session.credentialKind == .token, identity: session.primaryIdentity)
        switch parts[1] {
        case "revokeToken": return AccessIntents.revokeToken(token, ownership: ownership)
        case "deleteToken": return AccessIntents.deleteToken(token, ownership: ownership)
        default: return nil
        }
    }

    static func demoSheet(_ name: String, argument: String?) -> AnyView? {
        guard name == "account" else { return nil }
        let parts = (argument ?? "security").split(separator: ":", maxSplits: 1).map(String.init)
        let id = parts.count > 1 ? parts[1] : ""
        let path: [SettingsRoute]
        switch parts[0] {
        case "security": path = [.account(.security)]
        case "passkey": path = [.account(.security), .account(.passkey(id: id))]
        case "passkeyCode": path = [.account(.security), .account(.passkey(id: id)), .account(.passkeyDeleteCode(id: id))]
        case "access": path = [.account(.access(view: id.isEmpty ? nil : id))]
        case "token":
            // "token:<id>:revoke" also starts the revoke once the sheet is up,
            // so its ConfirmPage is pushed inside the Settings sheet.
            let pieces = id.split(separator: ":").map(String.init)
            path = [.account(.access(view: "tokens")), .account(.token(id: pieces.first ?? id))]
            if pieces.count == 2 {
                return AnyView(AccountDemoOpener(path: path, intentID: "account.\(pieces[1])Token.\(pieces[0])"))
            }
        case "user": path = [.account(.access(view: "users")), .account(.user(id: id))]
        case "sso": path = [.account(.access(view: "sso")), .account(.ssoProvider(id: id))]
        default: return nil
        }
        return AnyView(AccountDemoOpener(path: path))
    }
}

/// Hands a demo launch over to the real Settings sheet: `openSettings`
/// dismisses this placeholder first, so the pages appear where they live.
private struct AccountDemoOpener: View {
    let path: [SettingsRoute]
    var intentID: String?
    @Environment(Router.self) private var router
    @Environment(ActionRunner.self) private var runner
    @Environment(SessionStore.self) private var session
    @Environment(StepUpCoordinator.self) private var stepUp
    @Environment(NodeDirectory.self) private var nodes

    var body: some View {
        Color.clear
            .task {
                router.openSettings(path)
                guard let intentID else { return }
                // Not tied to this view, which the Settings sheet replaces.
                Task { @MainActor [runner, session, stepUp, nodes] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let intent = AccountRoute.demoIntent(intentID, session: session) else { return }
                    let outcome = await runner.run(intent)
                    // The same follow-up TokenDetail runs after revoking this iPhone's token.
                    if case .done = outcome, intent.verb == "Revoke token", intent.object.id == session.primaryIdentity?.tokenID {
                        await AccountSignOut.afterOwnTokenRevoked(session: session, stepUp: stepUp, nodes: nodes)
                    }
                }
            }
    }
}
