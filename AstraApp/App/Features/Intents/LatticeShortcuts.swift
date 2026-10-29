import AppIntents

/// The App Shortcuts for the two intents (M14). Phrases carry no entity
/// parameter on purpose: a parameterized phrase would hand every node name to
/// the system's Siri vocabulary, so Siri asks "Which node?" instead and lists
/// the choices only after the device is unlocked.
struct LatticeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenNodeIntent(),
            phrases: [
                "Open a node in \(.applicationName)",
                "Show a node in \(.applicationName)",
            ],
            shortTitle: "Open Node",
            systemImageName: "server.rack"
        )
        AppShortcut(
            intent: ReviewApprovalIntent(),
            phrases: [
                "Review an approval in \(.applicationName)",
                "Review a \(.applicationName) approval",
            ],
            shortTitle: "Review Approval",
            systemImageName: "hand.raised"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .navy
}
