import SwiftUI

/// M2-15 Gate: its facts and what it would refuse, as if enforced now.
/// Turning it on or off is T3; the ConfirmSheet repeats the would-refuse list.
struct GateDetailScreen: View {
    let id: String

    @Environment(SessionStore.self) private var session
    @Environment(FleetStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @State private var model = FleetGatesModel()

    var body: some View {
        FleetListState(state: model.state, noun: "the gate", retry: { Task { await model.refresh(session: session) } }) { gates in
            if let gate = gates.first(where: { $0.capability == id }) {
                content(gate)
            } else {
                WholeScreenState {
                    ContentUnavailableView("No capability \(id)", systemImage: "questionmark.circle",
                                           description: Text("This server declares no gate by that name."))
                }
            }
        }
        .navigationTitle(id)
        .navigationSubtitle(model.state.value?.first { $0.capability == id }.map { $0.enforced ? "enforced" : "open" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh(session: session) }
        .polling(.standard, version: changes.version([.gates, .nodes])) { await model.refresh(session: session) }
    }

    private func content(_ gate: FleetCapabilityImpact) -> some View {
        let reason: String? = store.missing("node:admin") ?? (store.isConfined ? "a token without a node allowlist" : nil)
        return List {
            FleetRefreshError(state: model.state, noun: "the gate") { Task { await model.refresh(session: session) } }
            Section {
                StatusRow(style: CapabilityGatesScreen.style(gate), title: gate.capability, detail: gate.kindSentence)
                DetailRow(label: "In scope", value: String(gate.allowCount), copyable: false)
                DetailRow(label: gate.enforced ? "Refused" : "Would be refused", value: String(gate.refuseCount), copyable: false)
                if !gate.derived {
                    Label("Nothing to infer scope from, so every node needs enrolling.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.statusWarnText)
                        .font(.subheadline)
                }
            } header: {
                Text("Gate")
            }
            Section {
                if gate.refused.isEmpty {
                    Text(gate.enforced ? "Refuses no node." : "Turning it on would refuse no node.").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                }
                ForEach(gate.refused) { node in
                    NavigationLink(value: AppRoute.fleet(.nodeCapabilities(id: node.nodeID))) {
                        StatusRow(style: StatusStyle(word: gate.enforced ? "refused" : "would be refused", symbol: "hand.raised", tone: gate.enforced ? .warn : .quiet),
                                  title: node.displayName, reason: node.reason.isEmpty ? nil : node.reason)
                    }
                }
            } header: {
                Text(gate.enforced ? "Refused now" : "Would refuse")
            } footer: {
                if gate.refuseCount > gate.refused.count {
                    Text("Showing \(gate.refused.count) of \(gate.refuseCount). The server names the first ten.")
                }
            }
            Section {
                FleetActionRow(title: gate.enforced ? "Turn off \(gate.capability)" : "Turn on \(gate.capability)",
                               systemImage: gate.enforced ? "lock.open" : "lock", missing: reason, destructive: !gate.enforced && gate.refuseCount > 0) {
                    Task { await runner.run(FleetIntents.setGate(gate, enforced: !gate.enforced)) }
                }
                WebLinkRow(path: LatticeConsolePath(path: "/settings/capabilities"))
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(gate.enforced
                         ? "\(gate.capability) would act on every node nobody has decided about. Excluded nodes stay refused. The change is recorded in the audit log."
                         : "\(gate.capability) would refuse \(gate.refuseCount == 1 ? "1 node" : "\(gate.refuseCount) nodes") immediately. Anything running against a refused node stops until it is enrolled.")
                    FleetFooter(state: model.state)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
