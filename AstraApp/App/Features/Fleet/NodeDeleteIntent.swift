import Foundation

/// The T4 node delete intent with its dry run (M2-09). The ConfirmSheet
/// renders the server's delete plan; this decides, from a first read of that
/// plan, whether the operator must type the node name, because the intent's
/// confirm phrase is fixed before the sheet opens.
enum NodeDeleteIntent {
    /// Reads the plan once, then builds the intent; the sheet reads it again
    /// as its dry run, and the runner reads it a third time right before sending.
    static func make(node: ObjectRef, client: LatticeClient) async throws -> WriteIntent {
        let plan = try await client.fleetPlanNodeDelete(nodeID: node.id)
        return FleetIntents.delete(node, typedName: FleetDeleteReport.requiresTypedName(plan))
    }

    /// The demo variant for `-AstraPresent confirm:fleet.delete:<id>`, which
    /// must be built without a request: the typed name follows the fixture plan.
    static func demo(nodeID: String) -> WriteIntent? {
        guard let node = DemoWorld.node(id: nodeID) else { return nil }
        let plan = FleetNodeDeleteSummary(nodeID: node.id, nodeName: node.name, counters: FleetFixtures.deleteCounters(node))
        return FleetIntents.delete(ObjectRef(kind: "node", id: node.id, name: node.name), typedName: FleetDeleteReport.requiresTypedName(plan))
    }
}
