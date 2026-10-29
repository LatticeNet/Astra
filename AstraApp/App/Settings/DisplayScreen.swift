import SwiftUI

enum DisplaySettings {
    static let utcKey = "display.showUTC"
}

extension EnvironmentValues {
    /// Local time or UTC, set at the root from Settings > Display (section 6.16).
    @Entry var timeZoneMode: TimeZoneMode = .local
}

/// F-09: "Show times in UTC", with a preview both ways.
struct DisplayScreen: View {
    @AppStorage(DisplaySettings.utcKey) private var showUTC = false
    @Environment(\.locale) private var locale

    var body: some View {
        let mode: TimeZoneMode = showUTC ? .utc : .local
        let now = Date()
        List {
            Section {
                Toggle("Show times in UTC", isOn: $showUTC)
            } footer: {
                Text("Detail screens show the other zone on a second line.")
            }
            Section("Preview") {
                DetailRow(label: "Shown as", value: TimeDisplay.dateTime(now, mode: mode, locale: locale),
                          secondary: TimeDisplay.otherZone(now, mode: mode, locale: locale), copyable: false)
            }
            Section {
                Text("Lattice follows the system appearance, Increase Contrast and the text size you set in iOS Settings.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Display")
    }
}
