import SwiftUI

/// The app lock settings, read by the privacy cover (F-18).
enum DeviceLockSettings {
    static let requireKey = "deviceSecurity.requireFaceID"
    static let lockAfterKey = "deviceSecurity.lockAfter"

    static var requireFaceID: Bool { UserDefaults.standard.bool(forKey: requireKey) }
    /// Seconds away before the lock engages; 0 is immediately.
    static var lockAfter: TimeInterval { UserDefaults.standard.double(forKey: lockAfterKey) }

    static let choices: [(seconds: Double, title: String)] = [
        (0, "Immediately"), (60, "After 1 minute"), (300, "After 5 minutes"), (900, "After 15 minutes"),
    ]
}

/// F-07: "Require Face ID to open" and "Lock after".
struct DeviceSecurityScreen: View {
    @AppStorage(DeviceLockSettings.requireKey) private var requireFaceID = false
    @AppStorage(DeviceLockSettings.lockAfterKey) private var lockAfter: Double = 0
    @Environment(ActionRunner.self) private var runner
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Toggle("Require Face ID to open", isOn: requireBinding)
                if requireFaceID {
                    Picker("Lock", selection: $lockAfter) {
                        ForEach(DeviceLockSettings.choices, id: \.seconds) { Text($0.title).tag($0.seconds) }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    if let message {
                        Text(message).foregroundStyle(Color.statusFailText)
                    }
                    Text("Face ID or the passcode always confirms decisions and privileged changes, whatever this setting says.")
                }
            }
        }
        .navigationTitle("Device security")
    }

    /// Turning the lock on proves device authentication works first, so the
    /// operator cannot lock themselves out of an app with no way back in.
    private var requireBinding: Binding<Bool> {
        Binding(
            get: { requireFaceID },
            set: { on in
                guard on else {
                    requireFaceID = false
                    return
                }
                Task {
                    switch await runner.authenticator.authenticate(reason: "Require Face ID to open Lattice") {
                    case .confirmed:
                        requireFaceID = true
                        message = nil
                    case .cancelled:
                        break
                    case .failed(let text):
                        message = text
                    }
                }
            }
        )
    }
}
