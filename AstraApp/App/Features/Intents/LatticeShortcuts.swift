import AppIntents
import UIKit

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

@MainActor
enum IntentsGate {
    /// Routes `link` once the app has a scene on screen. On a cold launch App
    /// Intents may call perform() before the root view restores scene storage,
    /// and that restore would overwrite the tab and path the link chose. The
    /// root view appears while its window becomes key, so waiting for a
    /// foreground scene with a key window and one more main-queue turn puts
    /// the link after the restore. A warm app routes at once. Siri over the
    /// app leaves the scene inactive, not backgrounded, so it does not wait.
    static func open(_ link: LatticeDeepLink) async {
        if !sceneOnScreen {
            let deadline = ContinuousClock.now + .seconds(5)
            while !sceneOnScreen, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        AppServices.shared.deepLinks.handle(link)
    }

    private static var sceneOnScreen: Bool {
        UIApplication.shared.connectedScenes.contains { scene in
            guard let scene = scene as? UIWindowScene else { return false }
            let foreground = scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
            return foreground && scene.keyWindow != nil
        }
    }
}
