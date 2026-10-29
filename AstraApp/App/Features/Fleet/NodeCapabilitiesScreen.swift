import SwiftUI

/// M2-06 Capabilities: what may act on this node, each with enrolled,
/// excluded, in scope or not decided, and the gate behind it. Swipe to
/// Enroll or Exclude (T3); excluding asks for the reason the server requires.
struct NodeCapabilitiesScreen: View {
    let nodeID: String

    @Environment(SessionStore.self) private var session
    @Environment(FleetStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @State private var state: ResourceState<[NodeCapabilityEffective]> = .idle
    @State private var excluding: NodeCapabilityEffective?
    @State private var reason = ""

    private var node: ObjectRef {
        store.record(id: nodeID).map { FleetIntents.nodeRef($0.node) } ?? ObjectRef(kind: "node", id: nodeID)
    }

    var body: some View {
        FleetListState(state: state, noun: "capabilities", retry: { Task { await load() } }) { capabilities in
            let gated = capabilities.filter { !FleetCapabilityState.isDormant($0) }
            let open = capabilities.filter(FleetCapabilityState.isDormant)
            List {
                FleetRefreshError(state: state, noun: "capabilities") { Task { await load() } }
                if capabilities.isEmpty {
                    ContentUnavailableView("No capability is declared for this node yet", systemImage: "checkmark.shield")
                }
                if !gated.isEmpty {
                    Section {
                        ForEach(gated) { row($0) }
                    } header: {
                        Text("Gated or decided")
                    } footer: {
                        Text("Anything that changes the node is opt-in where its gate is on. An exclusion refuses even while its gate is off.")
                    }
                }
                if !open.isEmpty {
                    Section {
                        ForEach(open) { row($0) }
                    } header: {
                        Text("Not gated yet")
                    } footer: {
                        Text("Nobody has decided about these, and they refuse nothing until their gate is on.")
                    }
                }
                Section {
                    NavigationLink(value: AppRoute.fleet(.capabilityGates)) {
                        FleetRelatedRow(title: "Capability gates", symbol: "slider.horizontal.3", detail: "Which gates are on for the fleet")
                    }
                } footer: {
                    FleetFooter(state: state)
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle(node.name)
        .navigationSubtitle("Capabilities")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .polling(.standard, version: changes.version([.gates, .nodes])) { await load() }
        .alert(excluding.map { "Exclude this node from \($0.capability)" } ?? "", isPresented: Binding(get: { excluding != nil }, set: { if !$0 { excluding = nil } })) {
            TextField("Reason", text: $reason)
            Button("Cancel", role: .cancel) { reason = "" }
            Button("Continue") {
                guard let capability = excluding else { return }
                let text = reason.trimmingCharacters(in: .whitespaces)
                reason = ""
                Task { await runner.run(FleetIntents.decideCapability(node, capability: capability.capability, state: "excluded", reason: text)) }
            }
            .disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("The node stays out of scope until someone enrolls it. Say why, so the next person does not have to guess.")
        }
    }

    private func row(_ capability: NodeCapabilityEffective) -> some View {
        let canAdmin = store.can("node:admin")
        return StatusRow(
            style: Self.style(capability),
            title: capability.capability,
            detail: capability.mutates ? "Changes nodes" : "Reads nodes",
            reason: FleetCapabilityState.detail(capability)
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canAdmin {
                if capability.state != "enrolled" {
                    Button("Enroll", systemImage: "checkmark.circle") {
                        Task { await runner.run(FleetIntents.decideCapability(node, capability: capability.capability, state: "enrolled")) }
                    }
                    .tint(.accentFill)
                }
                if capability.state != "excluded" {
                    Button("Exclude", systemImage: "minus.circle") { excluding = capability }
                        .tint(.destructiveFill)
                }
            }
        }
        .contextMenu {
            FleetGatedButton(title: "Enroll", systemImage: "checkmark.circle", missing: canAdmin ? (capability.state == "enrolled" ? "a decision to change" : nil) : "node:admin") {
                Task { await runner.run(FleetIntents.decideCapability(node, capability: capability.capability, state: "enrolled")) }
            }
            FleetGatedButton(title: "Exclude", systemImage: "minus.circle", missing: canAdmin ? (capability.state == "excluded" ? "a decision to change" : nil) : "node:admin", role: .destructive) {
                excluding = capability
            }
        }
    }

    static func style(_ capability: NodeCapabilityEffective) -> StatusStyle {
        switch capability.state {
        case "enrolled": return StatusStyle(word: "enrolled", symbol: "checkmark.circle.fill", tone: .ok)
        case "excluded": return StatusStyle(word: "excluded", symbol: "minus.circle", tone: .quiet)
        default:
            if !capability.enforced { return StatusStyle(word: "not gated", symbol: "circle.dashed", tone: .quiet) }
            if !capability.allowed { return StatusStyle(word: "refused", symbol: "exclamationmark.triangle.fill", tone: .warn) }
            return capability.source == "derived"
                ? StatusStyle(word: "in scope", symbol: "checkmark.circle", tone: .ok)
                : StatusStyle(word: "allowed", symbol: "checkmark.circle", tone: .ok)
        }
    }

    @discardableResult
    private func load() async -> Bool {
        if let missing = session.missing(ScopeRequirement("node:read")), !missing.isEmpty {
            state = .denied(scope: missing.joined(separator: " and "))
            return true
        }
        guard let client = session.client else { return false }
        state = state.reloading
        do {
            state = .loaded(try await client.fetchNodeCapabilities(nodeID: nodeID), at: Date())
            return true
        } catch {
            state = state.failing(LatticeAPIError(error), surface: "Capabilities", missingScope: "node:read")
            return false
        }
    }
}
