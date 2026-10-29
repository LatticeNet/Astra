import SwiftUI

/// Capability gates as one list both gate screens read (M2-14, M2-15).
@MainActor @Observable
final class FleetGatesModel {
    var state: ResourceState<[FleetCapabilityImpact]> = .idle

    @discardableResult
    func refresh(session: SessionStore) async -> Bool {
        if let missing = session.missing(ScopeRequirement("node:read")), !missing.isEmpty {
            state = .denied(scope: missing.joined(separator: " and "))
            return true
        }
        guard let client = session.client else { return false }
        state = state.reloading
        do {
            state = .loaded(try await client.fleetCapabilityGates(), at: Date())
            return true
        } catch {
            state = state.failing(LatticeAPIError(error), surface: "Capability gates", missingScope: "node:read")
            return false
        }
    }
}

/// M2-14 Capability gates: which capabilities may act on the fleet's nodes,
/// each with whether it is enforced and what turning it on would refuse.
struct CapabilityGatesScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @State private var model = FleetGatesModel()

    var body: some View {
        FleetListState(state: model.state, noun: "capability gates", retry: { Task { await model.refresh(session: session) } }) { gates in
            let enforced = gates.filter(\.enforced)
            let open = gates.filter { !$0.enforced }
            List {
                FleetRefreshError(state: model.state, noun: "capability gates") { Task { await model.refresh(session: session) } }
                Section {
                    Text("Anything that changes a node is opt-in. A gate that is open behaves as it always has; turning one on starts refusing every node that is not in scope for it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if gates.isEmpty {
                    ContentUnavailableView("No capabilities are declared", systemImage: "slider.horizontal.3")
                }
                if !enforced.isEmpty {
                    Section("Enforced (\(enforced.count))") { ForEach(enforced) { row($0) } }
                }
                if !open.isEmpty {
                    Section("Open (\(open.count))") { ForEach(open) { row($0) } }
                }
                Section {
                } footer: {
                    FleetFooter(state: model.state)
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Capability Gates")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh(session: session) }
        .polling(.standard, version: changes.version(.gates)) { await model.refresh(session: session) }
    }

    private func row(_ gate: FleetCapabilityImpact) -> some View {
        NavigationLink(value: AppRoute.fleet(.gate(id: gate.capability))) {
            StatusRow(style: Self.style(gate), title: gate.capability, detail: gate.kindSentence,
                      reason: gate.enforced && gate.refuseCount > 0 ? "Refuses \(gate.refuseCount) of \(gate.allowCount + gate.refuseCount) nodes" : nil,
                      trailing: gate.enforced ? nil : "\(gate.refuseCount) if on")
        }
    }

    static func style(_ gate: FleetCapabilityImpact) -> StatusStyle {
        gate.enforced
            ? StatusStyle(word: "enforced", symbol: "lock.fill", tone: gate.refuseCount > 0 ? .warn : .ok)
            : StatusStyle(word: "open", symbol: "lock.open", tone: .quiet)
    }
}
