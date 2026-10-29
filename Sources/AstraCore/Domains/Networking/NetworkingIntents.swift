import Foundation

/// Every Networking write, with the tier the parity matrix gives it
/// (section 3.2): outbound policy plans P, convert T3 then P, DNS plan P
/// with the lockout findings loop, Publish IPs T3, Measure certificate T2,
/// DDNS Run now T3 and Delete T4, geo routing Delete T4, tunnel Plan P and
/// Delete T4. Nothing here sends a request until ActionRunner gates it.
public enum NetworkingIntents {
    public static let policyAdmin = "netpolicy:admin"
    public static let dnsPlanScopes = ["dns:admin", "network:plan"]
    public static let dnsAdmin = "dns:admin"
    public static let measureScopes = ["dns:admin", "monitor:admin"]
    public static let ddnsAdmin = "ddns:admin"
    /// Publish IPs and Run now read GET /api/nodes (node:read) for their dry run.
    public static let publishScopes = ["dns:admin", "node:read"]
    public static let ddnsRunScopes = ["ddns:admin", "node:read"]
    public static let geoAdmin = "geo:admin"
    public static let tunnelAdmin = "tunnel:admin"
    public static let acceptLockoutID = "accept_lockout_risk"

    static let acceptLockout = ConfirmToggle(
        id: acceptLockoutID,
        label: "Accept lockout risk",
        consequence: "Files the plan even though the lint says it may cut off inbound access to the node, including your shell. The acceptance is recorded in the audit log.",
        revealedByConflict: true
    )

    // MARK: Outbound policy

    /// `POST /api/group-policies/plan {}` plans every node any enabled
    /// outbound policy covers, whichever screen it starts from. The server
    /// decides per node, so the covered nodes are listed as "will try".
    public static func planAllGroupPolicies(covered: [ObjectRef]) -> WriteIntent {
        let names = Dictionary(covered.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let count = covered.count == 1 ? "1 node" : "\(covered.count) nodes"
        return WriteIntent(
            tier: .plan,
            verb: "Plan",
            object: ObjectRef(kind: "outbound policies", id: "all", name: "all outbound policies"),
            scopes: [policyAdmin],
            consequence: "Plans every node any enabled outbound policy covers, whichever policy you start from: \(count) now. Each node gets its own approval. A node with a manual policy is reported as a conflict and left alone, and nothing changes on any node until its plan is approved.",
            affected: covered,
            verify: { client in
                let pending = try await client.listApprovals(query: ApprovalQuery(status: "pending", plugin: "nftpolicy", limit: 100))
                return pending.approvals.isEmpty ? "No outbound policy plan is pending." : "\(pending.approvals.count) outbound policy plans are pending in Approvals."
            },
            changes: [.approvals, .policies],
            perform: { client, _ in
                let result = try await client.networkingPlanGroupPolicies()
                return result.outcome { names[$0] ?? $0 }
            }
        )
    }

    /// Files the plan for one node's own document.
    public static func planNodePolicy(_ node: ObjectRef) -> WriteIntent {
        WriteIntent(
            tier: .plan,
            verb: "Plan the outbound policy of",
            object: node,
            scopes: [policyAdmin],
            consequence: "Compiles the outbound policy of \(node.name) into an nft ruleset and files it for approval. Nothing changes on \(node.name) until the plan is approved and applied.",
            affected: [node],
            verify: { client in try await pendingSentence(client, plugin: "nftpolicy", node: node) },
            changes: [.approvals, .policies],
            perform: { client, _ in
                let approval = try await client.networkingPlanNodePolicy(nodeID: node.id)
                return .filed(approvalIDs: [approval.id], refused: [], notes: ["Filed the outbound policy plan for \(node.name)"])
            }
        )
    }

    /// Creates an outbound policy from the node's manual document, then
    /// files its plan. The policy exists as soon as the server answers, even
    /// if the plan is later rejected, which is why this is T3 before P.
    public static func convertPolicy(_ node: ObjectRef, name: String?, priority: Int?) -> WriteIntent {
        let body = NetworkingConvertBody(targetNodeID: node.id, name: name, priority: priority)
        let shown = body.name.map { "outbound policy \"\($0)\"" } ?? "an outbound policy named after \(node.name)"
        return WriteIntent(
            tier: .t3,
            verb: "Convert",
            object: node,
            scopes: [policyAdmin],
            consequence: "Creates \(shown) directly, targeting \(node.name) with the same rules, then files a plan for \(node.name). The new policy stays even if the plan is rejected.",
            affected: [node],
            verify: { client in
                let policies = try await client.networkingGroupPolicies()
                let made = policies.first { $0.target.nodes == [node.id] && !$0.target.all && $0.target.groups.isEmpty }
                return made.map { "Outbound policy \($0.displayName) now targets \(node.name)." } ?? "No outbound policy targets \(node.name) alone yet."
            },
            changes: [.approvals, .policies],
            perform: { client, _ in
                let result = try await client.networkingConvertPolicy(body)
                let policy = result.groupPolicy.displayName
                guard let approval = result.approval else {
                    return .done("Created outbound policy \(policy). It is disabled, so no plan was filed")
                }
                return .filed(approvalIDs: [approval.id], refused: [], notes: ["Created outbound policy \(policy) and filed its plan for \(node.name)"])
            }
        )
    }

    // MARK: Self-host DNS

    /// Files the DNS plan. A plan the lint says may lock the node out is
    /// refused with findings; the acceptance is sent only once ticked.
    public static func planDNS(_ deployment: ObjectRef, node: ObjectRef) -> WriteIntent {
        WriteIntent(
            tier: .plan,
            verb: "Plan",
            object: deployment,
            scopes: dnsPlanScopes,
            consequence: "Renders the CoreDNS config of \(deployment.name) and the firewall chain it needs on \(node.name), and files them for approval. The plan replaces the node's whole lattice_guard input chain, so the server checks it for lockout first.",
            affected: [node],
            toggles: [acceptLockout],
            dryRun: { client in
                guard let current = try await client.networkingDNSDeployments().first(where: { $0.id == deployment.id }) else {
                    return DryRunReport(lines: [DetailLine(label: "Deployment", value: "Deleted since this screen loaded")], blocking: true, fingerprint: "gone")
                }
                return dnsPlanReport(current)
            },
            verify: { client in try await pendingSentence(client, plugin: "selfdns", node: node) },
            changes: [.approvals, .dns],
            perform: { client, choices in
                let answer = try await client.networkingPlanDNS(NetworkingDNSPlanBody(id: deployment.id, acceptLockoutRisk: choices.isAccepted(acceptLockoutID)))
                let warnings = answer.findings.map { $0.isBlocking ? "Accepted: \($0.message)" : $0.message }
                return .filed(approvalIDs: [answer.approval.id], refused: [], notes: ["Filed the DNS plan for \(deployment.name)"] + warnings)
            }
        )
    }

    /// What a DNS plan renders, read again right before filing so an edit
    /// made on the web in between stops it.
    public static func dnsPlanReport(_ deployment: NetworkingDNSDeployment) -> DryRunReport {
        let group = "What the plan renders"
        let answers = deployment.exposure != "public" ? "Mesh peers"
            : (deployment.allowedClients.isEmpty ? "Every client that reaches the port"
               : (deployment.allowedClients.count == 1 ? "1 client network" : "\(deployment.allowedClients.count) client networks"))
        let lines = [
            DetailLine(label: "Listens", value: deployment.listenSummary, group: group),
            DetailLine(label: "Answers", value: answers, group: group),
        ]
        let fingerprint = [deployment.updatedAt.map { String($0.timeIntervalSince1970) } ?? "", deployment.listenSummary,
                           deployment.allowedClients.joined(separator: ","), String(deployment.zones.count)].joined(separator: "|")
        return DryRunReport(lines: lines, fingerprint: fingerprint)
    }

    /// Writes the node's current addresses to the external DNS provider.
    /// The server has no preview, so the dry run computes one on the phone
    /// from a fresh read of the node, and a change before send stops it.
    public static func publishDNS(_ deployment: NetworkingDNSDeployment) -> WriteIntent {
        let id = deployment.id
        let name = deployment.displayName
        let host = deployment.hostname
        let nodeID = deployment.nodeID
        return WriteIntent(
            tier: .t3,
            verb: "Publish",
            object: ObjectRef(kind: "DNS deployment", id: id, name: name),
            scopes: publishScopes,
            consequence: "Writes the node's current address to the DNS provider for \(IdentifierText.breakable(host)). Resolvers see the new record within its TTL. This changes a record outside Lattice.",
            affected: [ObjectRef(kind: "node", id: nodeID, name: deployment.nodeDisplayName)],
            dryRun: { client in
                async let nodes = client.fetchNodes()
                async let deployments = client.networkingDNSDeployments()
                guard let current = try await deployments.first(where: { $0.id == id }) else {
                    return DryRunReport(lines: [DetailLine(label: "Deployment", value: "Deleted since this screen loaded")], blocking: true, fingerprint: "gone")
                }
                let node = try await nodes.first { $0.id == nodeID }
                return publishReport(current, publicIPv4: node?.publicIP, publicIPv6: node?.publicIPv6)
            },
            verify: { client in
                guard let current = try await client.networkingDNSDeployments().first(where: { $0.id == id }) else { return "\(name) no longer exists." }
                if !current.lastPublishError.isEmpty { return "The last publish of \(name) failed: \(current.lastPublishError)" }
                return "The provider has \(current.lastIPv4.isEmpty ? "no IPv4 record" : current.lastIPv4) for \(host)."
            },
            changes: [.dns],
            perform: { client, _ in
                let answer = try await client.networkingPublishDNS(id: id)
                let values = [answer.ipv4, answer.ipv6].filter { !$0.isEmpty }.joined(separator: " and ")
                return .done(values.isEmpty ? "Published \(host)" : "Published \(host): \(values)")
            }
        )
    }

    /// The labelled on-device preview Publish IPs shows before the button enables.
    public static func publishReport(_ deployment: NetworkingDNSDeployment, publicIPv4: String?, publicIPv6: String?) -> DryRunReport {
        let preview = NetworkingPublishPreview(deployment: deployment, publicIPv4: publicIPv4, publicIPv6: publicIPv6)
        let group = "Computed on this iPhone from the node's reported address"
        var lines = preview.lines.map { line in
            DetailLine(label: line.type, value: line.previous.isEmpty ? "\(line.value), new" : (line.changes ? "\(line.value), provider has \(line.previous)" : "\(line.value), unchanged"), group: group)
        }
        if !preview.refusals.isEmpty {
            lines = preview.refusals.map { DetailLine(label: $0.label, value: "The server refuses: \($0.text)", group: group) }
        }
        let fingerprint = (preview.lines.map { "\($0.type)=\($0.value)" } + preview.refusals.map(\.label)).joined(separator: ",")
        let hostname = preview.hostname.isEmpty ? [] : [DetailLine(label: "Hostname", value: preview.hostname, group: group)]
        return DryRunReport(lines: hostname + lines, blocking: preview.blocking, fingerprint: fingerprint)
    }

    /// Creates a tls check on each DoT or DoH port of an external engine and
    /// links it, or links the check already there.
    public static func measureCert(_ deployment: NetworkingDNSDeployment, ports: [Int]) -> WriteIntent {
        let id = deployment.id
        let name = deployment.displayName
        let targets = ports.map { "\(deployment.hostname):\($0)" }
        let targetText = targets.count <= 2 ? targets.joined(separator: " and ") : "\(targets.count) ports of \(deployment.hostname)"
        return WriteIntent(
            tier: .t2,
            verb: "Measure the certificate of",
            object: ObjectRef(kind: "DNS deployment", id: id, name: name),
            scopes: measureScopes,
            consequence: "Creates a TLS check on \(targetText) and links it to \(name). The check alerts before the certificate expires.",
            changes: [.dns, .checks],
            perform: { client, _ in
                let answer = try await client.networkingMeasureCert(NetworkingMeasureCertBody(id: id, ports: ports))
                switch (answer.created.count, answer.linked.count) {
                case (0, 0): return .done("No check changed for \(name)")
                case (let made, 0): return .done(made == 1 ? "Created a TLS check for \(name)" : "Created \(made) TLS checks for \(name)")
                case (0, let linked): return .done(linked == 1 ? "Linked the existing TLS check to \(name)" : "Linked \(linked) existing TLS checks to \(name)")
                case (let made, let linked): return .done("Created \(made) and linked \(linked) TLS checks for \(name)")
                }
            }
        )
    }

    // MARK: DDNS

    /// Runs the profile now. The dry run shows the records it will write,
    /// computed on the phone from a fresh read of the node.
    public static func runDDNS(_ profile: DDNSProfile) -> WriteIntent {
        let id = profile.id
        let name = profile.name.isEmpty ? profile.id : profile.name
        let domains = profile.domains.joined(separator: ", ")
        let nodeID = profile.nodeID
        return WriteIntent(
            tier: .t3,
            verb: "Run DDNS profile",
            object: ObjectRef(kind: "DDNS profile", id: id, name: name),
            scopes: ddnsRunScopes,
            consequence: "Writes \(domains.isEmpty ? "its records" : IdentifierText.breakable(domains)) at the DNS provider now instead of waiting for the next sweep. This changes records outside Lattice.",
            dryRun: { client in
                async let nodes = client.fetchNodes()
                async let profiles = client.listDDNS()
                guard let current = try await profiles.first(where: { $0.id == id }) else {
                    return DryRunReport(lines: [DetailLine(label: "Profile", value: "Deleted since this screen loaded")], blocking: true, fingerprint: "gone")
                }
                let node = try await nodes.first { $0.id == nodeID }
                return ddnsReport(current, publicIPv4: node?.publicIP, publicIPv6: node?.publicIPv6)
            },
            verify: { client in
                guard let current = try await client.listDDNS().first(where: { $0.id == id }) else { return "\(name) no longer exists." }
                if !current.lastError.isEmpty { return "The last run of \(name) failed: \(NetworkingDDNSPreview.errorText(current.lastError))" }
                return "\(name) holds \(current.isCNAME ? current.lastTarget : current.lastIPv4)."
            },
            changes: [.ddns],
            perform: { client, _ in
                let after = try await client.networkingRunDDNS(id: id)
                if !after.lastError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let reason = NetworkingDDNSPreview.errorText(after.lastError)
                    return .refused(.validation(reason), "\(name) ran and failed: \(reason)")
                }
                let value = after.isCNAME ? after.lastTarget : [after.lastIPv4, after.lastIPv6].filter { !$0.isEmpty }.joined(separator: " and ")
                return .done(value.isEmpty ? "Ran \(name)" : "Ran \(name): \(value)")
            }
        )
    }

    public static func ddnsReport(_ profile: DDNSProfile, publicIPv4: String?, publicIPv6: String?) -> DryRunReport {
        let records = NetworkingDDNSPreview.records(profile, publicIPv4: publicIPv4, publicIPv6: publicIPv6)
        let group = "Computed on this iPhone from the node's reported address"
        let lines = records.map { record in
            DetailLine(label: "\(record.domain) \(record.type)", value: record.previous.isEmpty ? "\(record.value), new" : (record.previous == record.value ? "\(record.value), unchanged" : "\(record.value), was \(record.previous)"), group: group)
        }
        let empty = DetailLine(label: "Records", value: "None: the node reports no address for the enabled families", group: group)
        return DryRunReport(lines: lines.isEmpty ? [empty] : lines, blocking: records.isEmpty, fingerprint: records.map { "\($0.domain)/\($0.type)=\($0.value)" }.joined(separator: ","))
    }

    public static func deleteDDNS(_ profile: DDNSProfile) -> WriteIntent {
        let id = profile.id
        let name = profile.name.isEmpty ? profile.id : profile.name
        return WriteIntent(
            tier: .t4,
            verb: "Delete DDNS profile",
            object: ObjectRef(kind: "DDNS profile", id: id, name: name),
            scopes: [ddnsAdmin],
            consequence: "Removes \(name) and its stored provider credential. The records it wrote stay at the provider and are no longer updated when the node's address moves. This cannot be undone.",
            confirmPhrase: name,
            verify: { client in
                try await client.listDDNS().contains { $0.id == id } ? "\(name) still exists." : "\(name) was deleted."
            },
            changes: [.ddns],
            perform: { client, _ in
                try await client.networkingDeleteDDNS(id: id)
                return .done("Deleted DDNS profile \(name)")
            }
        )
    }

    // MARK: Geo-Routing

    /// The delete removes only the record; an applied routing's zone stays
    /// on its DNS nodes, which the dry run names from a fresh read.
    public static func deleteGeo(_ routing: NetworkingGeoRouting, names: [String: String], time: @escaping @Sendable (Date) -> String) -> WriteIntent {
        let id = routing.id
        let name = routing.displayName
        let impact = routing.deleteImpact(name: { names[$0] ?? $0 }, time: time)
        return WriteIntent(
            tier: .t4,
            verb: "Delete geo routing",
            object: ObjectRef(kind: "geo routing", id: id, name: name),
            scopes: [geoAdmin],
            consequence: geoConsequence(routing, time: time),
            affected: routing.dnsNodeIDs.map { ObjectRef(kind: "node", id: $0, name: names[$0]) },
            confirmPhrase: impact.typed ? name : nil,
            dryRun: { client in
                guard let current = try await client.networkingGeoRoutings().first(where: { $0.id == id }) else {
                    return DryRunReport(lines: [DetailLine(label: "Geo routing", value: "Deleted since this screen loaded")], blocking: true, fingerprint: "gone")
                }
                return geoDeleteReport(current, names: names, time: time)
            },
            verify: { client in
                try await client.networkingGeoRoutings().contains { $0.id == id } ? "\(name) still exists." : "\(name) was deleted."
            },
            changes: [.geo],
            perform: { client, _ in
                try await client.networkingDeleteGeo(id: id)
                return .done("Deleted geo routing \(name)")
            }
        )
    }

    /// One sentence for the geo delete: the record goes; an applied zone stays.
    static func geoConsequence(_ routing: NetworkingGeoRouting, time: (Date) -> String) -> String {
        guard let applied = routing.lastAppliedAt else {
            return "Removes the geo routing for \(routing.hostname). It was never applied, so no node changes. This cannot be undone."
        }
        let nodes = routing.dnsNodeIDs.count == 1 ? "its DNS node" : "its \(routing.dnsNodeIDs.count) DNS nodes"
        return "Removes only the record for \(routing.hostname). The zone applied \(time(applied)) stays on \(nodes), which keep answering it. This cannot be undone."
    }

    /// The geo delete's dry run: the record goes, and an applied zone stays
    /// on each DNS node, named one per row.
    public static func geoDeleteReport(_ routing: NetworkingGeoRouting, names: [String: String], time: (Date) -> String) -> DryRunReport {
        var lines = [DetailLine(label: "Record for \(routing.hostname)", value: "Removed", group: "What changes")]
        if let applied = routing.lastAppliedAt {
            let stays = "Stays, as applied \(time(applied))"
            lines += routing.dnsNodeIDs.isEmpty
                ? [DetailLine(label: "Zone on its DNS nodes", value: stays, group: "What stays on nodes")]
                : routing.dnsNodeIDs.map { DetailLine(label: names[$0] ?? $0, value: stays, group: "What stays on nodes") }
        } else {
            lines.append(DetailLine(label: "DNS nodes", value: "Nothing was ever sent", group: "What stays on nodes"))
        }
        return DryRunReport(lines: lines, fingerprint: "\(routing.lastAppliedAt?.timeIntervalSince1970 ?? 0)|\(routing.dnsNodeIDs.joined(separator: ","))")
    }

    // MARK: Tunnels

    public static func planTunnel(_ tunnel: TunnelProfile, node: ObjectRef) -> WriteIntent {
        WriteIntent(
            tier: .plan,
            verb: "Plan tunnel",
            object: ObjectRef(kind: "tunnel", id: tunnel.id, name: tunnel.displayName),
            scopes: [tunnelAdmin],
            consequence: "Renders the cloudflared config of \(tunnel.displayName) with \(tunnel.ingress.count == 1 ? "1 ingress rule" : "\(tunnel.ingress.count) ingress rules") and files it for approval. Nothing changes on \(node.name) until the plan is approved and applied.",
            affected: [node],
            verify: { client in try await pendingSentence(client, plugin: "cftunnel", node: node) },
            changes: [.approvals, .tunnels],
            perform: { client, _ in
                let approval = try await client.networkingPlanTunnel(id: tunnel.id)
                return .filed(approvalIDs: [approval.id], refused: [], notes: ["Filed the tunnel plan for \(tunnel.displayName)"])
            }
        )
    }

    public static func deleteTunnel(_ tunnel: TunnelProfile, nodeName: String) -> WriteIntent {
        let id = tunnel.id
        let name = tunnel.displayName
        let impact = tunnel.networkingDeleteImpact(nodeName: nodeName)
        return WriteIntent(
            tier: .t4,
            verb: "Delete tunnel",
            object: ObjectRef(kind: "tunnel", id: id, name: name),
            scopes: [tunnelAdmin],
            consequence: impact.lines.joined(separator: " ") + " This cannot be undone.",
            confirmPhrase: impact.typed ? name : nil,
            verify: { client in
                try await client.listTunnels().contains { $0.id == id } ? "\(name) still exists." : "\(name) was deleted."
            },
            changes: [.tunnels],
            perform: { client, _ in
                try await client.networkingDeleteTunnel(id: id)
                return .done("Deleted tunnel \(name)")
            }
        )
    }

    // MARK: Helpers

    /// For a plan whose answer was lost: what Approvals now holds for the node.
    static func pendingSentence(_ client: LatticeClient, plugin: String, node: ObjectRef) async throws -> String {
        let page = try await client.listApprovals(query: ApprovalQuery(status: "pending", plugin: plugin, nodeID: node.id, limit: 5))
        return page.approvals.isEmpty ? "No new plan for \(node.name) is pending." : "A plan for \(node.name) is pending in Approvals."
    }
}
