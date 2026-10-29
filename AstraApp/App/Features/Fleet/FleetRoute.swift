import SwiftUI

/// M2 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M2 may add cases but must not rename or remove these.
enum FleetRoute: Hashable, Codable, Sendable {
    case node(id: String, tab: NodeDetailTab = .overview)
    case nodeHistory(id: String)
    case nodeNetwork(id: String)
    case nodeCapabilities(id: String)
    case nodeBeacon(id: String)
    case duplicates
    case group(id: String)
    case unlocated
    case capabilityGates
    case gate(id: String)
}

/// M2's demo intents and sheets for `-AstraPresent`:
/// `confirm:fleet.<action>:<id>` with action disable, enable, rotate, delete,
/// identity, debug, geoClear, geoResolve, agentUpdate, beaconPlan,
/// beaconRotate, enroll, groupDelete, gateOn or gateOff; `confirm:fleet.bulkDisable`,
/// `confirm:fleet.bulkEnable`, `confirm:fleet.locateAll`; and the sheets
/// `nodeIdentity:<nodeID>` and `addMembers:<groupID>`.
extension FleetRoute: DemoHooks {
    static func demoIntent(_ id: String, session: SessionStore) -> WriteIntent? {
        guard session.isDemo, id.hasPrefix("fleet.") else { return nil }
        let parts = id.dropFirst("fleet.".count).split(separator: ":", maxSplits: 1).map(String.init)
        let action = parts[0]
        let argument = parts.count > 1 ? parts[1] : ""
        let world = DemoWorld.node(id: argument) ?? DemoWorld.nodes.first { $0.name == argument }
        let node = world.map { ObjectRef(kind: "node", id: $0.id, name: $0.name) }
        switch action {
        case "bulkDisable":
            return FleetIntents.bulkDisable(DemoWorld.nodes.filter { $0.status == "degraded" }.map { ObjectRef(kind: "node", id: $0.id, name: $0.name) })
        case "bulkEnable":
            return FleetIntents.bulkEnable(DemoWorld.nodes.filter { $0.status == "disabled" }.map { ObjectRef(kind: "node", id: $0.id, name: $0.name) })
        case "locateAll":
            return FleetIntents.locateAll(DemoWorld.nodes.filter { $0.region == "home" }.map { ObjectRef(kind: "node", id: $0.id, name: $0.name) })
        case "groupDelete":
            let group = DemoWorld.groups.first { $0.id == argument }
            return group.map { FleetIntents.deleteGroup(ObjectRef(kind: "group", id: $0.id, name: $0.name)) }
        case "gateOn", "gateOff":
            let impact = FleetCapabilityImpact(capability: argument, enforced: action == "gateOff", mutates: true, derived: argument != "sshguard",
                                               allowCount: 1, refuseCount: 3, refused: ["lab-pi-1", "lab-pi-2", "home-router"].map {
                                                   FleetRefusedNode(nodeID: DemoWorld.node($0).id, name: $0, reason: "not enrolled for \(argument)")
                                               })
            return FleetIntents.setGate(impact, enforced: action == "gateOn")
        default:
            break
        }
        guard let node, let world else { return nil }
        switch action {
        case "disable": return FleetIntents.disable(node)
        case "enable": return FleetIntents.enable(node)
        case "rotate": return FleetIntents.rotateToken(node)
        case "delete": return NodeDeleteIntent.demo(nodeID: node.id)
        case "identity":
            return FleetIntents.updateIdentity(node, request: FleetNodeUpdateRequest(nodeID: node.id, name: world.name, role: world.role, comment: "", tags: world.tags + ["phone"]), changed: ["tags"])
        case "debug": return FleetIntents.agentDebug(node, enabled: true)
        case "geoClear": return FleetIntents.clearGeo(node)
        case "geoResolve": return FleetIntents.resolveGeo(node, ip: world.ipv4)
        case "agentUpdate": return FleetIntents.planAgentUpdate(node, force: false)
        case "beaconPlan":
            let enabled = world.role == "relay" || world.name.hasPrefix("edge-tyo")
            let request = enabled ? BeaconPlanRequest(nodeID: node.id, action: .change) : BeaconPlanRequest(nodeID: node.id, action: .enable)
            return FleetIntents.planBeacon(node, request: request, netGuard: world.region != "home")
        case "beaconRotate": return FleetIntents.rotateBeacon(node)
        case "enroll": return FleetIntents.decideCapability(node, capability: "sshguard", state: "enrolled")
        default: return nil
        }
    }

    static func demoSheet(_ name: String, argument: String?) -> AnyView? {
        switch name {
        case "nodeIdentity":
            guard let argument else { return nil }
            return AnyView(NodeIdentitySheet(nodeID: argument))
        case "addMembers":
            guard let argument else { return nil }
            return AnyView(FleetDemoAddMembers(groupID: argument))
        default:
            return nil
        }
    }
}

/// The add-members sheet for a demo launch, once the groups have loaded.
private struct FleetDemoAddMembers: View {
    let groupID: String
    @Environment(GroupsStore.self) private var groups
    @Environment(FleetStore.self) private var fleet

    var body: some View {
        Group {
            if let group = groups.group(id: groupID) {
                FleetAddMembersSheet(group: group)
            } else {
                ProgressView()
            }
        }
        .task {
            if fleet.nodes.value == nil { await fleet.refresh() }
            if groups.groups.value == nil { await groups.refresh() }
        }
    }
}
