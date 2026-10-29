import SwiftUI

/// F-11 (demo only): the scenario picker and the demo clock pin.
struct DemoScenarioScreen: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        List {
            Section {
                ForEach(DemoScenario.allCases, id: \.argument) { scenario in
                    Button {
                        session.setDemoScenario(scenario)
                    } label: {
                        HStack {
                            Text(scenario.title)
                            Spacer()
                            if scenario.argument == session.demoScenario.argument {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentText)
                            }
                        }
                    }
                    .tint(.primary)
                    .accessibilityAddTraits(scenario.argument == session.demoScenario.argument ? .isSelected : [])
                }
            } header: {
                Text("Scenario")
            } footer: {
                Text("Every name, address and token in demo data is invented. Writes and reveals go through the real confirmation, Face ID and step-up paths.")
            }
            Section {
                Toggle("Pin demo clock", isOn: Binding(
                    get: { session.demoClock.isPinned },
                    set: { session.setDemoClockPinned($0) }
                ))
            } footer: {
                Text("A pinned clock removes the simulated network delay and keeps times stable for screenshots.")
            }
        }
        .navigationTitle("Demo data")
    }
}
