import SwiftUI
import UIKit

/// The privacy cover and app lock (F-18): a window above alerts, owned by the
/// window scene. On resign active it covers everything at once, so the
/// app-switcher snapshot never shows plan bodies, addresses or a revealed
/// value, whatever sheet is up. On becoming active it lifts, unless "Require
/// Face ID to open" is on and the lock interval has passed; then it stays
/// until Face ID or the passcode succeeds. No SwiftUI presentation is used.
@MainActor
final class ShieldController {
    private let window: UIWindow
    private let model = ShieldModel()
    private var resignedAt: Date?
    private var unlocking = false
    private let authenticator: () -> IntentAuth

    init(scene: UIWindowScene, authenticator: @escaping () -> IntentAuth) {
        self.authenticator = authenticator
        window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: ShieldView(model: model))
        window.rootViewController = host
        window.isHidden = true
        model.unlock = { [weak self] in self?.unlock() }
        // A cold launch with the lock on starts locked.
        if DeviceLockSettings.requireFaceID {
            model.locked = true
            window.isHidden = false
        }
    }

    func sceneWillResignActive() {
        window.isHidden = false
        // The Face ID prompt itself resigns the app; that is not leaving it.
        if !unlocking, resignedAt == nil { resignedAt = Date() }
    }

    func sceneDidBecomeActive() {
        guard !unlocking else { return }
        let away = resignedAt.map { Date().timeIntervalSince($0) }
        resignedAt = nil
        let intervalPassed = away.map { $0 >= DeviceLockSettings.lockAfter } ?? false
        if model.locked || (DeviceLockSettings.requireFaceID && intervalPassed) {
            model.locked = true
            window.isHidden = false
            unlock()
        } else {
            window.isHidden = true
        }
    }

    private func unlock() {
        guard !unlocking else { return }
        unlocking = true
        Task {
            let outcome = await authenticator().authenticate(reason: "Unlock Lattice")
            unlocking = false
            switch outcome {
            case .confirmed:
                model.locked = false
                model.message = nil
                window.isHidden = true
            case .cancelled:
                model.message = nil
            case .failed(let message):
                model.message = message
            }
        }
    }
}

@MainActor @Observable
final class ShieldModel {
    var locked = false
    var message: String?
    @ObservationIgnored var unlock: () -> Void = {}
}

/// The cover: the app symbol and no data. Locked, it offers Unlock.
private struct ShieldView: View {
    let model: ShieldModel

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: Spacing.l) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(Color.accentText)
                    .accessibilityHidden(true)
                Text("Lattice").font(.title2.weight(.semibold))
                if model.locked {
                    Button {
                        model.unlock()
                    } label: {
                        Label("Unlock", systemImage: "faceid")
                            .frame(minWidth: 160, minHeight: Spacing.minimumTarget - 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentFill)
                    if let message = model.message {
                        Text(message)
                            .foregroundStyle(Color.statusFailText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Spacing.xl)
                    }
                }
            }
        }
    }
}
