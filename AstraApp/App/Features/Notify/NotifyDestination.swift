import SwiftUI

/// Maps each NotifyRoute case to its screen.
struct NotifyDestination: View {
    let route: NotifyRoute

    var body: some View {
        switch route {
        case .notifications(let view): NotificationsScreen(view: view)
        case .delivery(let id): DeliveryDetailScreen(id: id)
        case .channel(let id): ChannelDetailScreen(id: id)
        case .rule(let id): RuleDetailScreen(id: id)
        case .webhooks: WebhooksScreen()
        case .webhook(let id): WebhookDetailScreen(id: id)
        }
    }
}
