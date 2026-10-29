import SwiftUI

/// F-12: app and server versions and the compatibility verdict.
struct AboutScreen: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        List {
            Section("This app") {
                DetailRow(label: "Version", value: AppVersion.display, copyable: false)
            }
            Section("Server") {
                if let version = session.serverVersion {
                    DetailRow(label: "Build", value: version.version.isEmpty ? "unknown" : version.version)
                    DetailRow(label: "Commit", value: version.shortCommit, monospaced: true)
                    if let ref = version.dashboardRef, !ref.isEmpty {
                        DetailRow(label: "Dashboard", value: ref, monospaced: true)
                    }
                } else {
                    Text("Not read yet").foregroundStyle(.secondary)
                }
            }
            Section("Compatibility") {
                Label {
                    Text(compatibility.text)
                } icon: {
                    Image(systemName: compatibility.symbol).foregroundStyle(compatibility.tone.glyph)
                }
            }
            Section {
                Link("Lattice website", destination: URL(string: "https://latticenet.github.io")!)
                Link("Source code", destination: URL(string: "https://github.com/LatticeNet/Astra")!)
            }
        }
        .navigationTitle("About")
        .task { await session.refreshIdentity() }
    }

    /// The app is behind when any surface failed to decode.
    private var compatibility: (text: String, symbol: String, tone: StatusTone) {
        if session.serverVersion == nil {
            return ("Unknown until the server version is read.", "questionmark.circle", .quiet)
        }
        if !session.companionBehind.isEmpty {
            return ("This app is behind the server: \(session.companionBehind.sorted().joined(separator: ", ")) could not be read.", "exclamationmark.triangle.fill", .warn)
        }
        return ("No decoding problems so far.", "checkmark.circle", .ok)
    }
}

enum AppVersion {
    static var display: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
