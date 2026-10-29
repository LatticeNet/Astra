import SwiftUI

/// M6-05 DNS deployment: service, zones, allowed clients, drift,
/// certificate and publishing. Plan (P, lockout findings loop), Publish IPs
/// (T3, preview computed on this iPhone), Measure certificate (T2), edit and
/// delete on the web.
struct DNSDeploymentScreen: View {
    let id: String

    @Environment(NetworkingStore.self) private var store
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        NetworkingListState(state: store.deployments, noun: "the DNS deployment", web: .dnsDeployment(id: id),
                            retry: { Task { await store.refreshDNS() } }) { deployments in
            if let deployment = deployments.first(where: { $0.id == id }) {
                detail(deployment)
            } else {
                notFound
            }
        }
        .navigationTitle(deployment?.displayName ?? "DNS deployment")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(deployment.map { StatusStyle.networkingDNS($0.health(now: .now)).word.networkingCapitalized } ?? "")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NetworkingMoreMenu(link: NetworkingCopy.link(.dnsDeployment(id: id), fallback: "lattice://dns/\(id)"), web: .dnsDeployment(id: id)) {
                    if let deployment {
                        if deployment.canPlan {
                            NetworkingGatedButton(title: "Plan", systemImage: "doc.badge.gearshape", blocked: planBlocked) { plan(deployment) }
                        }
                        if !deployment.isExternal {
                            NetworkingGatedButton(title: "Publish IPs", systemImage: "arrow.up.to.line", blocked: publishBlocked(deployment)) { publish(deployment) }
                        } else {
                            NetworkingGatedButton(title: "Measure certificate", systemImage: "lock.doc", blocked: measureBlocked(deployment)) { measure(deployment) }
                        }
                        Button("Edit on web", systemImage: "square.and.pencil") { router.openOnWeb(.dnsDeployment(id: id)) }
                    }
                }
            }
        }
        .refreshable { await store.refreshDNS() }
        .task { await nodes.refreshIfOlder(than: 60) }
        .polling(.standard, version: changes.version([.dns, .nodes, .checks])) {
            await store.refreshDNS()
        }
    }

    private var deployment: NetworkingDNSDeployment? {
        store.deployments.value?.first { $0.id == id }
    }

    @ViewBuilder
    private func detail(_ deployment: NetworkingDNSDeployment) -> some View {
        let now = Date()
        let health = deployment.health(now: now)
        List {
            Section {
                NetworkingRefreshError(state: store.deployments, noun: "the DNS deployment") { Task { await store.refreshDNS() } }
                StatusRow(style: .networkingDNS(health), title: deployment.displayName,
                          detail: deployment.isExternal ? "External engine, observed only" : "CoreDNS, deployed by plans",
                          reason: health.reason)
            }
            service(deployment)
            zones(deployment)
            drift(deployment)
            certificate(deployment, now: now)
            publishing(deployment)
            apply(deployment)
            actions(deployment)
        }
        .listStyle(.insetGrouped)
    }

    private func service(_ deployment: NetworkingDNSDeployment) -> some View {
        Section("Service") {
            NetworkingNodeLink(nodeID: deployment.nodeID, label: "Node")
            if deployment.isExternal {
                if deployment.listeners.isEmpty {
                    DetailRow(label: "Listeners", value: "None recorded", copyable: false)
                }
                ForEach(deployment.listeners.sorted { ($0.port, $0.proto) < ($1.port, $1.proto) }, id: \.self) { listener in
                    DetailRow(label: "\(listener.proto)/\(listener.port)", value: listener.process.isEmpty ? "nothing observed" : listener.process, copyable: false)
                }
            } else {
                DetailRow(label: "Listens", value: deployment.listenSummary, copyable: false)
            }
            if !deployment.hostname.isEmpty {
                DetailRow(label: "Hostname", value: deployment.hostname, monospaced: true)
            }
            if !deployment.isExternal {
                DetailRow(label: "Exposure", value: deployment.exposure == "public" ? "Public" : "Mesh only", copyable: false)
                if deployment.allowedClients.isEmpty {
                    DetailRow(label: "Allowed clients", value: deployment.exposure == "public" ? "Every client that reaches the port" : "Mesh peers", copyable: false)
                } else {
                    ForEach(deployment.allowedClients, id: \.self) { network in
                        DetailRow(label: "Allowed client", value: network, monospaced: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func zones(_ deployment: NetworkingDNSDeployment) -> some View {
        if !deployment.zones.isEmpty {
            Section {
                ForEach(Array(deployment.zones.enumerated()), id: \.offset) { _, zone in
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(zone.suffix == "." ? "Everything else (.)" : zone.suffix).font(TextRole.identifierInDetail.font)
                        Text(zone.summary).textRole(.rowDetail)
                        ForEach(Array(zone.records.enumerated()), id: \.offset) { _, record in
                            Text("\(record.name) \(record.type) \(record.value)").textRole(.identifierInRow).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Zones (\(deployment.zones.count))")
            }
        }
    }

    @ViewBuilder
    private func drift(_ deployment: NetworkingDNSDeployment) -> some View {
        if let drift = deployment.drift {
            Section {
                let style: StatusStyle = switch drift.status {
                case "drift": StatusStyle(word: "drift", symbol: "exclamationmark.triangle.fill", tone: .warn)
                case "ok": StatusStyle(word: "matches the node", symbol: "checkmark.circle.fill", tone: .ok)
                default: StatusStyle(word: "unknown", symbol: "questionmark.circle", tone: .quiet)
                }
                StatusRow(style: style, title: "Listeners",
                          detail: drift.realityCollectedAt.map { "node reported \(TimeDisplay.relative($0, now: .now, locale: locale))" },
                          reason: drift.status == "drift" ? drift.findings.joined(separator: " ") : nil)
                if drift.status == "unknown" {
                    Text("The node has not reported its listeners recently, so the record cannot be compared.")
                        .textRole(.footnote)
                }
            } header: {
                Text("Drift")
            } footer: {
                Text("Compared with the node's latest guard reality on every read. Lattice never changes an external engine.")
            }
        }
    }

    @ViewBuilder
    private func certificate(_ deployment: NetworkingDNSDeployment, now: Date) -> some View {
        if deployment.isExternal {
            Section {
                if let shown = deployment.certShown {
                    let state = deployment.certState(now: now)
                    let tone: StatusTone = switch state {
                    case .expired: .fail
                    case .soon: .warn
                    case .ok: .ok
                    case .unknown: .quiet
                    }
                    StatusRow(style: StatusStyle(word: state.words, symbol: "lock.doc", tone: tone),
                              title: TimeDisplay.dateTime(shown.notAfter, mode: mode, locale: locale),
                              detail: shown.source == "measured" ? "measured by a linked check" : "typed by an operator")
                } else {
                    Text("No certificate date: none was typed and no linked check has measured one.")
                        .foregroundStyle(.secondary)
                        .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                }
                ForEach(deployment.certChecks, id: \.monitorID) { check in
                    NavigationLink(value: AppRoute.monitoring(.check(id: check.monitorID))) {
                        StatusRow(style: StatusStyle(word: check.enabled ? "warns \(check.thresholdDays) days ahead" : "paused",
                                                     symbol: check.enabled ? "checkmark.shield" : "pause.circle", tone: .quiet),
                                  title: check.target, titleIsIdentifier: true)
                    }
                }
                NetworkingActionRow(title: "Measure certificate", systemImage: "lock.doc",
                                    detail: measureDetail(deployment), blocked: measureBlocked(deployment)) { measure(deployment) }
            } header: {
                Text("Certificate")
            } footer: {
                Text(deployment.certThresholdDays == 0 ? "Nothing watches this expiry yet, so only an expiry already past is flagged." : "Judged at the linked check's own warning window.")
            }
        }
    }

    @ViewBuilder
    private func publishing(_ deployment: NetworkingDNSDeployment) -> some View {
        if !deployment.isExternal, deployment.publishIPv4 || deployment.publishIPv6 || !deployment.hostname.isEmpty {
            Section {
                DetailRow(label: "Publishes", value: [deployment.publishIPv4 ? "IPv4" : nil, deployment.publishIPv6 ? "IPv6" : nil].compactMap { $0 }.joined(separator: " and ").networkingNonEmpty ?? "Nothing", copyable: false)
                if !deployment.lastIPv4.isEmpty { DetailRow(label: "Provider has (A)", value: deployment.lastIPv4, monospaced: true) }
                if !deployment.lastIPv6.isEmpty { DetailRow(label: "Provider has (AAAA)", value: deployment.lastIPv6, monospaced: true) }
                if let published = deployment.lastPublishedAt {
                    DetailRow(label: "Last published", value: TimeDisplay.dateTime(published, mode: mode, locale: locale),
                              secondary: TimeDisplay.otherZone(published, mode: mode, locale: locale), copyable: false)
                }
                if !deployment.lastPublishError.isEmpty {
                    DetailRow(label: "Last publish error", value: NetworkingDDNSPreview.errorText(deployment.lastPublishError), copyable: true)
                }
                if deployment.publishes {
                    let preview = publishPreview(deployment)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Label("Computed on this iPhone", systemImage: "iphone").textRole(.footnote)
                        ForEach(preview.sentences, id: \.self) { Text($0) }
                    }
                    .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    NetworkingActionRow(title: "Publish IPs", systemImage: "arrow.up.to.line",
                                        detail: "Writes the node's current address to the DNS provider", blocked: publishBlocked(deployment)) { publish(deployment) }
                }
            } header: {
                Text("Publishing")
            } footer: {
                Text(deployment.hasCredential ? "The provider credential is stored on the server and never sent to this iPhone." : "No provider credential is stored, so nothing can be published.")
            }
        }
    }

    private func apply(_ deployment: NetworkingDNSDeployment) -> some View {
        Section("Apply") {
            DetailRow(label: "Status", value: deployment.status.networkingCapitalized, copyable: false)
            if !deployment.engineVersion.isEmpty {
                DetailRow(label: "Engine", value: "CoreDNS \(deployment.engineVersion)", copyable: false)
            }
            if let applied = deployment.lastAppliedAt {
                DetailRow(label: "Last applied", value: TimeDisplay.dateTime(applied, mode: mode, locale: locale),
                          secondary: TimeDisplay.otherZone(applied, mode: mode, locale: locale), copyable: false)
            }
            if !deployment.lastError.isEmpty {
                DetailRow(label: "Last error", value: deployment.lastError)
            }
        }
    }

    private func actions(_ deployment: NetworkingDNSDeployment) -> some View {
        Section {
            if deployment.canPlan {
                NetworkingActionRow(title: "Plan", systemImage: "doc.badge.gearshape",
                                    detail: "Files the config and its firewall chain for approval", blocked: planBlocked) { plan(deployment) }
            }
            WebLinkRow(title: "Edit on web", path: .dnsDeployment(id: deployment.id))
            WebLinkRow(title: "Delete on web", path: .dnsDeployment(id: deployment.id))
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if deployment.isExternal { Text("An external engine is observed only: Lattice never plans or publishes it.") }
                FreshnessFooter(state: store.deployments, interval: Polling.standard.interval(lowPower: false))
            }
        }
    }

    // MARK: Gates and actions

    private var planBlocked: String? { store.blocked(NetworkingIntents.dnsPlanScopes) }

    private func publishPreview(_ deployment: NetworkingDNSDeployment) -> NetworkingPublishPreview {
        let node = nodes.nodes[deployment.nodeID]
        return NetworkingPublishPreview(deployment: deployment, publicIPv4: node?.publicIP, publicIPv6: node?.publicIPv6)
    }

    private func publishBlocked(_ deployment: NetworkingDNSDeployment) -> String? {
        if let blocked = store.blocked(NetworkingIntents.publishScopes) { return blocked }
        if deployment.disabled { return "The deployment is disabled" }
        if deployment.hostname.isEmpty { return "The deployment has no hostname to publish" }
        if !deployment.hasCredential { return "No provider credential is stored" }
        // The node directory may not have loaded; the sheet's dry run reads the node itself.
        guard nodes.nodes[deployment.nodeID] != nil else { return nil }
        if let refusal = publishPreview(deployment).refusals.first { return refusal.text.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        return nil
    }

    private func measureBlocked(_ deployment: NetworkingDNSDeployment) -> String? {
        if let blocked = store.measureBlocked { return blocked }
        if let block = deployment.measureBlock { return block }
        return deployment.portsToMeasure.isEmpty ? "Every DoT and DoH port already has a check" : nil
    }

    private func measureDetail(_ deployment: NetworkingDNSDeployment) -> String {
        let ports = deployment.portsToMeasure
        guard !ports.isEmpty else { return "" }
        return "Creates a TLS check on \(ports.map { "\(deployment.hostname):\($0)" }.joined(separator: ", "))"
    }

    private var nodeRef: (NetworkingDNSDeployment) -> ObjectRef {
        { ObjectRef(kind: "node", id: $0.nodeID, name: $0.nodeDisplayName) }
    }

    private func plan(_ deployment: NetworkingDNSDeployment) {
        Task { await runner.run(NetworkingIntents.planDNS(ObjectRef(kind: "DNS deployment", id: deployment.id, name: deployment.displayName), node: nodeRef(deployment))) }
    }

    private func publish(_ deployment: NetworkingDNSDeployment) {
        Task { await runner.run(NetworkingIntents.publishDNS(deployment)) }
    }

    private func measure(_ deployment: NetworkingDNSDeployment) {
        Task { await runner.run(NetworkingIntents.measureCert(deployment, ports: deployment.portsToMeasure)) }
    }

    private var notFound: some View {
        WholeScreenState {
            ContentUnavailableView {
                Label("Not found", systemImage: "questionmark.square.dashed")
            } description: {
                Text("This DNS deployment was deleted, or it is on a node this token cannot read.")
            } actions: {
                Button("Token scopes") { router.openSettings([.page(.scopes)]) }.buttonStyle(.bordered)
                Button("Open on web") { router.openOnWeb(.dnsDeployment(id: id)) }
            }
        }
    }
}

extension String {
    /// nil for an empty string, so `??` can supply a word.
    var networkingNonEmpty: String? { isEmpty ? nil : self }
}
