import SwiftUI

/// Maps each AccountRoute case to its screen.
struct AccountDestination: View {
    let route: AccountRoute

    var body: some View {
        switch route {
        case .security: SecurityScreen()
        case .passkey(let id): PasskeyDetailScreen(id: id)
        case .access(let view): AccessScreen(view: view)
        case .user(let id): UserDetailScreen(id: id)
        case .token(let id): TokenDetailScreen(id: id)
        case .ssoProvider(let id): SSOProviderScreen(id: id)
        case .passkeyDeleteCode(let id): AccountStepUpPage(passkeyID: id)
        }
    }
}
