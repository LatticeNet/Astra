import Foundation

/// Every Fleet write as a `WriteIntent`, with the tier the parity matrix
/// assigns (section 3.2). Built here, not in the views, so the checks can
/// run them against a mock server: bodies, cancel paths and outcomes.
public enum FleetIntents {
    public static func nodeRef(_ node: LatticeNode) -> ObjectRef {
        ObjectRef(kind: "node", id: node.id, name: node.displayName)
    }

    static func describe(_ error: Error) -> String {
        LatticeAPIError(error).localizedDescription
    }

    // MARK: Disable and enable (N-T3, N-T2, verified inverses of each other)

    public static func disable(_ node: ObjectRef) -> WriteIntent {
        WriteIntent(
            tier: .t3, verb: "Disable", object: node, scopes: ["node:admin"],
            consequence: "\(node.name) can no longer authenticate: it stops reporting and receives no plans or tasks. Services on it keep running.",
            affected: [node],
            verify: { client in try await disabledState(node, client: client) },
            inverse: { enable(node) },
            idempotent: true,
            changes: [.nodes],
            perform: { client, _ in
                try await client.setNodeDisabled(nodeID: node.id, disabled: true)
                return .done("Disabled \(node.name)")
            }
        )
    }

    public static func enable(_ node: ObjectRef) -> WriteIntent {
        WriteIntent(
            tier: .t2, verb: "Enable", object: node, scopes: ["node:admin"],
            consequence: "\(node.name) can authenticate again and receives plans and tasks.",
            affected: [node],
            verify: { client in try await disabledState(node, client: client) },
            inverse: { disable(node) },
            idempotent: true,
            changes: [.nodes],
            perform: { client, _ in
                try await client.setNodeDisabled(nodeID: node.id, disabled: false)
                return .done("Enabled \(node.name)")
            }
        )
    }

    static func disabledState(_ node: ObjectRef, client: LatticeClient) async throws -> String {
        let nodes = try await client.fetchNodes()
        guard let current = nodes.first(where: { $0.id == node.id }) else { return "\(node.name) is no longer listed." }
        return current.honesty == .disabled ? "\(node.name) is now disabled." : "\(node.name) is not disabled."
    }

    public static func bulkDisable(_ nodes: [ObjectRef]) -> WriteIntent {
        let count = nodes.count == 1 ? "1 node" : "\(nodes.count) nodes"
        return WriteIntent(
            tier: .t3, verb: "Disable", object: ObjectRef(kind: "nodes", id: "bulk", name: count), scopes: ["node:admin"],
            consequence: "These nodes can no longer authenticate: they stop reporting and receive no plans or tasks. Services on them keep running.",
            affected: nodes, idempotent: true, changes: [.nodes],
            perform: { client, _ in
                await bulk(nodes, done: "disabled", disabled: true, client: client) { try await $0.setNodeDisabled(nodeID: $1.id, disabled: true) }
            }
        )
    }

    public static func bulkEnable(_ nodes: [ObjectRef]) -> WriteIntent {
        let count = nodes.count == 1 ? "1 node" : "\(nodes.count) nodes"
        return WriteIntent(
            tier: .t2, verb: "Enable", object: ObjectRef(kind: "nodes", id: "bulk", name: count), scopes: ["node:admin"],
            consequence: "\(count) can authenticate again and receive plans and tasks.",
            affected: nodes, idempotent: true, changes: [.nodes],
            perform: { client, _ in
                await bulk(nodes, done: "enabled", disabled: false, client: client) { try await $0.setNodeDisabled(nodeID: $1.id, disabled: false) }
            }
        )
    }

    /// One request per node, in order; each failure is kept with its reason.
    /// A node whose answer was lost after sending may already have changed,
    /// so it is checked against the server and filed by what it now says
    /// (section 6.7), never reported as "not done" on a guess.
    static func bulk(_ nodes: [ObjectRef], done word: String, disabled target: Bool, client: LatticeClient,
                     _ write: @Sendable (LatticeClient, ObjectRef) async throws -> Void) async -> WriteOutcome {
        var succeeded: [ObjectRef] = []
        var failed: [ObjectFailure] = []
        var lost: [ObjectRef] = []
        for node in nodes {
            do {
                try await write(client, node)
                succeeded.append(node)
            } catch {
                let api = LatticeAPIError(error)
                if WriteFlow.answerLostAfterSending(api) {
                    lost.append(node)
                } else {
                    failed.append(ObjectFailure(object: node, reason: api.localizedDescription))
                }
            }
        }
        var unconfirmed = 0
        if !lost.isEmpty {
            let current = try? await client.fetchNodes()
            for node in lost {
                guard let current else {
                    unconfirmed += 1
                    failed.append(ObjectFailure(object: node, reason: "Could not confirm, and its state could not be read. Check it before trying again."))
                    continue
                }
                guard let now = current.first(where: { $0.id == node.id }) else {
                    failed.append(ObjectFailure(object: node, reason: "Could not confirm. \(node.name) is no longer listed."))
                    continue
                }
                if (now.honesty == .disabled) == target {
                    succeeded.append(node)
                } else {
                    failed.append(ObjectFailure(object: node, reason: "Could not confirm. \(node.name) is \(target ? "not disabled" : "still disabled")."))
                }
            }
        }
        if failed.isEmpty {
            return .done(succeeded.count == 1 ? "\(succeeded[0].name) \(word)" : "\(succeeded.count) nodes \(word)")
        }
        let notDone = failed.count - unconfirmed
        var message = "\(succeeded.count) \(word)"
        if notDone > 0 { message += ", \(notDone) not done" }
        if unconfirmed > 0 { message += ", \(unconfirmed) not confirmed" }
        return .partial(succeeded: succeeded, failed: failed, message: message)
    }

    // MARK: Token (N-T3, secret shown once)

    public static func rotateToken(_ node: ObjectRef) -> WriteIntent {
        WriteIntent(
            tier: .t3, verb: "Rotate token for", object: node, scopes: ["node:admin"],
            consequence: "\(node.name) stops reporting and receives no plans until the new token is installed on the host. You cannot do that from this iPhone.",
            affected: [node],
            changes: [.nodes],
            perform: { client, _ in
                let answer = try await client.rotateNodeToken(nodeID: node.id)
                return .done(
                    "Rotated the token for \(node.name). Install it on the host to restore reporting.",
                    secret: RevealedSecret(title: "New node token for \(node.name)", value: answer.token)
                )
            }
        )
    }

    // MARK: Identity (N-T2)

    public static func updateIdentity(_ node: ObjectRef, request: FleetNodeUpdateRequest, changed: [String]) -> WriteIntent {
        let fields = changed.isEmpty ? "nothing" : changed.joined(separator: ", ")
        return WriteIntent(
            tier: .t2, verb: "Save identity of", object: node, scopes: ["node:admin"],
            consequence: "Changes \(fields) on \(node.name). Groups that select by tag or role may gain or lose it.",
            affected: [node],
            idempotent: true,
            changes: [.nodes, .groups],
            perform: { client, _ in
                let answer = try await client.fleetUpdateNode(request)
                return .done("Saved \(answer.name.isEmpty ? node.name : answer.name)")
            }
        )
    }

    // MARK: Delete (N-T4 with a dry run)

    /// The dry run is the server's delete plan; it runs again right before
    /// sending, and a different answer stops the write. `typedName` makes
    /// the operator type the node name (DNS, geo, tunnel or line dependencies).
    public static func delete(_ node: ObjectRef, typedName: Bool) -> WriteIntent {
        WriteIntent(
            tier: .t4, verb: "Delete node", object: node, scopes: ["node:admin"],
            consequence: "Removes \(node.name) and everything below from the control plane. This cannot be undone.",
            affected: [node],
            confirmPhrase: typedName ? node.name : nil,
            dryRun: { client in FleetDeleteReport.report(try await client.fleetPlanNodeDelete(nodeID: node.id)) },
            changes: [.nodes, .groups, .tasks, .approvals, .checks, .machines],
            perform: { client, _ in
                FleetDeleteReport.outcome(try await client.fleetDeleteNode(nodeID: node.id), node: node)
            }
        )
    }

    // MARK: Capabilities (N-T3)

    public static func decideCapability(_ node: ObjectRef, capability: String, state: String, reason: String = "") -> WriteIntent {
        let excluding = state == "excluded"
        return WriteIntent(
            tier: .t3, verb: excluding ? "Exclude \(capability) on" : "Enroll \(capability) on", object: node, scopes: ["node:admin"],
            consequence: excluding
                ? "\(capability) can no longer act on \(node.name). Reason recorded: \(reason)"
                : "\(capability) may act on \(node.name), including plans that change it.",
            affected: [node],
            idempotent: true,
            changes: [.nodes, .gates],
            perform: { client, _ in
                _ = try await client.fleetDecideCapability(FleetCapabilityDecisionRequest(nodeID: node.id, capability: capability, state: state, reason: reason))
                return .done(excluding ? "Excluded \(node.name) from \(capability)" : "Enrolled \(node.name) in \(capability)")
            }
        )
    }

    // MARK: Geo (N-T2)

    public static func clearGeo(_ node: ObjectRef) -> WriteIntent {
        WriteIntent(
            tier: .t2, verb: "Clear location of", object: node, scopes: ["node:admin"],
            consequence: "Removes the location of \(node.name); the map lists it under No location.",
            affected: [node], idempotent: true, changes: [.nodes],
            perform: { client, _ in
                _ = try await client.fleetClearNodeGeo(nodeID: node.id)
                return .done("Cleared the location of \(node.name)")
            }
        )
    }

    public static func resolveGeo(_ node: ObjectRef, ip: String) -> WriteIntent {
        WriteIntent(
            tier: .t2, verb: "Resolve location of", object: node, scopes: ["node:admin"],
            consequence: "Looks up \(node.name) from its public IP \(ip.isEmpty ? "address" : ip) and replaces its location.",
            affected: [node], idempotent: true, changes: [.nodes],
            perform: { client, _ in
                let results = try await client.resolveNodeGeo(nodeID: node.id, all: false, missingOnly: false, overwrite: true)
                guard let result = results.first else { return .refused(.validation("No answer"), "The server resolved nothing for \(node.name).") }
                return geoOutcome(result, node: node)
            }
        )
    }

    public static func locateAll(_ nodes: [ObjectRef]) -> WriteIntent {
        let count = nodes.count == 1 ? "1 node" : "\(nodes.count) nodes"
        return WriteIntent(
            tier: .t2, verb: "Resolve location for", object: ObjectRef(kind: "nodes", id: "missing", name: count), scopes: ["node:admin"],
            consequence: "Looks up each node without a location from its public IP.",
            affected: nodes, idempotent: true, changes: [.nodes],
            perform: { client, _ in
                let results = try await client.resolveNodeGeo(nodeID: nil, all: true, missingOnly: true, overwrite: false)
                let names = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let located = results.filter { $0.status == "updated" }
                let failures = results.filter { $0.status != "updated" && $0.status != "skipped_existing" }.map {
                    ObjectFailure(object: names[$0.nodeID] ?? ObjectRef(kind: "node", id: $0.nodeID), reason: geoReason($0))
                }
                let succeeded = located.map { names[$0.nodeID] ?? ObjectRef(kind: "node", id: $0.nodeID) }
                if failures.isEmpty { return .done(succeeded.count == 1 ? "Located 1 node" : "Located \(succeeded.count) nodes") }
                return .partial(succeeded: succeeded, failed: failures, message: "Located \(succeeded.count), \(failures.count) not located")
            }
        )
    }

    static func geoReason(_ result: NodeGeoResolveResult) -> String {
        switch result.status {
        case "no_public_ip": "No public IP reported"
        case "resolver_disabled": "The server has no GeoIP resolver"
        case "lookup_failed": result.message.isEmpty ? "Lookup failed" : "Lookup failed: \(result.message)"
        default: result.message.isEmpty ? result.status : result.message
        }
    }

    static func geoOutcome(_ result: NodeGeoResolveResult, node: ObjectRef) -> WriteOutcome {
        switch result.status {
        case "updated":
            let place = [result.geo?.city, result.geo?.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            return .done(place.isEmpty ? "Located \(node.name)" : "Located \(node.name) in \(place)")
        case "skipped_existing":
            return .done("\(node.name) already has a location")
        default:
            let reason = geoReason(result)
            return .refused(.validation(reason), "\(node.name) not located: \(reason)")
        }
    }

    // MARK: Agent debug (N-T2)

    public static func agentDebug(_ node: ObjectRef, enabled: Bool) -> WriteIntent {
        WriteIntent(
            tier: .t2, verb: enabled ? "Turn on agent debug for" : "Turn off agent debug for", object: node, scopes: ["node:admin"],
            consequence: enabled
                ? "The agent on \(node.name) writes verbose, non-secret diagnostics, and Lattice collects them in Logs."
                : "The agent on \(node.name) stops writing verbose diagnostics.",
            affected: [node], idempotent: true, changes: [.nodes, .evidence],
            perform: { client, _ in
                let facts = try await client.fleetSetAgentDebug(nodeID: node.id, enabled: enabled, collect: enabled)
                return .done(facts.agentDebug.enabled ? "Agent debug is on for \(node.name)" : "Agent debug is off for \(node.name)")
            }
        )
    }

    // MARK: Plans (N-P)

    public static func planAgentUpdate(_ node: ObjectRef, force: Bool) -> WriteIntent {
        WriteIntent(
            tier: .plan, verb: force ? "Force agent update for" : "Plan agent update for", object: node,
            scopes: ["node:admin", "network:plan"],
            consequence: force
                ? "Files an agent update plan for \(node.name) even when it already runs the target. Nothing changes until the plan is approved."
                : "Files an agent update plan for \(node.name). Nothing changes until the plan is approved.",
            affected: [node],
            changes: [.approvals, .agentUpdates],
            perform: { client, _ in
                let approval = try await client.planAgentUpdate(nodeID: node.id, force: force)
                return .filed(approvalIDs: [approval.id], refused: [], notes: ["Filed an agent update plan for \(node.name)"])
            }
        )
    }

    /// Enable, change or disable the beacon. The server has no acceptance
    /// flag: blocking findings come back as the findings list and the plan
    /// is not filed.
    public static func planBeacon(_ node: ObjectRef, request: BeaconPlanRequest, netGuard: Bool) -> WriteIntent {
        let consequence: String = switch request.action {
        case .enable: "Files a plan that turns on the UDP beacon on \(node.name) so other nodes can probe it. Nothing changes until the plan is approved."
        case .change:
            "Files a plan that keeps the beacon on \(node.name) and updates its sources\(request.port.map { " on port \($0)" } ?? ""). Nothing changes until the plan is approved."
        case .disable: "Files a plan that turns off the beacon on \(node.name); paths probed by beacon fall back or stop. Nothing changes until the plan is approved."
        }
        var scopes = ["monitor:admin", "node:admin", "network:plan"]
        if netGuard { scopes.append("netguard:admin") }
        return WriteIntent(
            tier: .plan,
            verb: request.action == .disable ? "Plan beacon off for" : (request.action == .enable ? "Plan beacon for" : "Replan beacon for"),
            object: node, scopes: scopes, consequence: consequence, affected: [node],
            changes: [.approvals, .paths],
            perform: { client, _ in
                let answer = try await client.planBeacon(request)
                let notes = answer.findings.filter { !$0.isBlocking }.map(\.message)
                return .filed(approvalIDs: answer.filedApprovalIDs, refused: [], notes: notes.isEmpty ? ["Filed a beacon plan for \(node.name)"] : notes)
            }
        )
    }

    // MARK: Beacon key (N-T3)

    public static func rotateBeacon(_ node: ObjectRef) -> WriteIntent {
        WriteIntent(
            tier: .t3, verb: "Rotate beacon key for", object: node, scopes: ["monitor:admin", "node:admin"],
            consequence: "Gives the beacon on \(node.name) a new key epoch. Sources move to it at their next config pull; until then their probes may fail.",
            affected: [node],
            changes: [.paths, .nodes],
            perform: { client, _ in
                let answer = try await client.fleetRotateBeacon(nodeID: node.id)
                return .done("Rotated the beacon key for \(node.name) to epoch \(answer.epoch)")
            }
        )
    }

    // MARK: Groups

    /// N-T4. The dry run lists what still names the group; the server
    /// refuses the delete while anything does, so that blocks the button.
    public static func deleteGroup(_ group: ObjectRef) -> WriteIntent {
        WriteIntent(
            tier: .t4, verb: "Delete group", object: group, scopes: ["group:admin"],
            consequence: "Deletes the node group \(group.name). Its nodes stay; checks and policies cannot target it any more. This cannot be undone.",
            affected: [group],
            dryRun: { client in
                // The server also refuses a group that still has child groups, which used-by does not report.
                async let children = client.fleetGroups().groups.filter { $0.parentID == group.id }
                return usedByReport(try await client.fleetGroupUsedBy(groupID: group.id), children: try await children)
            },
            changes: [.groups, .policies, .checks],
            perform: { client, _ in
                try await client.fleetDeleteGroup(groupID: group.id)
                return .done("Deleted group \(group.name)")
            }
        )
    }

    public static func usedByReport(_ usedBy: FleetGroupUsedBy, children: [FleetGroupView] = []) -> DryRunReport {
        var lines = usedBy.usedBy.map { DetailLine(label: $0.label, value: "\($0.kindTitle), \($0.roleWord)", group: "Used by") }
        if usedBy.hidden > 0 {
            lines.append(DetailLine(label: "Hidden from this token", value: usedBy.hidden == 1 ? "1 more use" : "\(usedBy.hidden) more uses", group: "Used by"))
        }
        lines += children.map { DetailLine(label: $0.displayName, value: "Child group", group: "Used by") }
        let blocked = usedBy.blocksDelete || !children.isEmpty
        if lines.isEmpty {
            lines.append(DetailLine(label: "Used by", value: "Nothing names this group", group: "Used by"))
        } else {
            lines.append(DetailLine(label: "Before deleting", value: children.isEmpty ? "Remove these references on web" : "Remove these references and move its child groups on web", group: "Blocked"))
        }
        let fingerprint = (usedBy.usedBy.map { "\($0.kind):\($0.id)" } + children.map { "child:\($0.id)" } + ["hidden=\(usedBy.hidden)"]).joined(separator: ",")
        return DryRunReport(lines: lines, blocking: blocked, fingerprint: fingerprint)
    }

    /// N-T2: static members only; the dialog names the group and the nodes.
    public static func setGroupMembers(_ group: ObjectRef, add: [ObjectRef] = [], remove: [ObjectRef] = []) -> WriteIntent {
        let adding = !add.isEmpty
        let nodes = (adding ? add : remove).map(\.name)
        let list = nodes.count <= 3 ? nodes.joined(separator: ", ") : "\(nodes.prefix(2).joined(separator: ", ")) and \(nodes.count - 2) more"
        return WriteIntent(
            tier: .t2, verb: adding ? "Add to" : "Remove from", object: group, scopes: ["group:admin"],
            consequence: adding
                ? "Adds \(list) to \(group.name). Policies and checks that target the group start applying to them."
                : "Removes \(list) from \(group.name). Policies and checks that target the group stop applying to them.",
            affected: adding ? add : remove,
            idempotent: true,
            changes: [.groups, .nodes],
            perform: { client, _ in
                let view = try await client.fleetSetGroupMembers(FleetGroupMembersRequest(groupID: group.id, add: add.map(\.id), remove: remove.map(\.id)))
                let count = (adding ? add : remove).count
                let noun = count == 1 ? "1 node" : "\(count) nodes"
                return .done(adding ? "Added \(noun) to \(view.displayName)" : "Removed \(noun) from \(view.displayName)")
            }
        )
    }

    // MARK: Capability gates (N-T3)

    public static func setGate(_ impact: FleetCapabilityImpact, enforced: Bool) -> WriteIntent {
        let gate = ObjectRef(kind: "capability gate", id: impact.capability, name: impact.capability)
        let refused = impact.refused.map { ObjectRef(kind: "node", id: $0.nodeID, name: $0.displayName) }
        return WriteIntent(
            tier: .t3, verb: enforced ? "Turn on gate" : "Turn off gate", object: gate, scopes: ["node:admin"],
            consequence: enforced
                ? "\(impact.capability) will refuse \(impact.refuseCount) of your nodes immediately and allow \(impact.allowCount). Anything already running against a refused node stops working until it is enrolled."
                : "\(impact.capability) will be able to act on every node nobody has decided about. Nodes you excluded stay refused. The change is recorded in the audit log.",
            affected: enforced ? refused : [gate],
            idempotent: true,
            changes: [.gates, .nodes],
            perform: { client, _ in
                let answer = try await client.fleetSetGateEnforced(capability: impact.capability, enforced: enforced)
                return .done(answer.enforced ? "\(impact.capability) is enforced" : "\(impact.capability) is open")
            }
        )
    }
}
