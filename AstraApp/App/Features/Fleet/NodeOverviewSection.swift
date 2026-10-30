import SwiftUI

/// NodeDetail's Overview tab (M2-03): open incidents, live numbers, the
/// history chart, the worst paths, and one row per related page.
struct NodeOverviewSection: View {
    let model: FleetNodeDetailModel

    @Environment(Router.self) private var router
    @Environment(ActionRunner.self) private var runner
    @Environment(FleetStore.self) private var store
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @State private var snoozing: Incident?

    var body: some View {
        if let record = model.record.value {
            List {
                FleetNodeHeader(record: record, fleetVersions: model.fleetVersions)
                FleetRefreshError(state: model.record, noun: "the node") { Task { await model.refreshCore() } }
                switch record.node.honesty {
                case .neverReported:
                    neverReported(record)
                default:
                    incidents
                    now(record)
                    history
                    paths(record)
                    related(record)
                    queued
                }
                Section {
                } footer: {
                    FleetFooter(state: model.record, interval: 15)
                }
            }
            .listStyle(.insetGrouped)
            .refreshable {
                await model.refreshCore()
                await model.refreshOverview()
            }
            .confirmationDialog(
                snoozing.map { "Snooze \($0.displayTitle)" } ?? "",
                isPresented: Binding(get: { snoozing != nil }, set: { if !$0 { snoozing = nil } }),
                titleVisibility: .visible,
                presenting: snoozing
            ) { incident in
                snoozeButtons(incident)
            } message: { _ in
                Text("No repeat alerts until the time you choose.")
            }
        }
    }

    // MARK: Never reported

    @ViewBuilder
    private func neverReported(_ record: FleetNodeRecord) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Agent has never reported").font(.headline)
                    Text("The node is enrolled, but its agent has not connected yet. Run the reconfigure command on the host; it carries a credential, so it is generated on the web.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "circle.dashed").foregroundStyle(Color.statusQuiet)
            }
            .padding(.vertical, Spacing.xs)
            if let created = record.node.createdAt {
                DetailRow(label: "Enrolled", value: "\(FleetAge.short(created) ?? "") ago", secondary: TimeDisplay.dateTime(created, mode: mode, locale: locale), copyable: false)
            }
            // The server dates a never-reported node from its creation, so the row only adds anything when they differ.
            if let since = record.node.statusSince, abs(since.timeIntervalSince(record.node.createdAt ?? since)) > 60 {
                DetailRow(label: "Waiting since", value: "\(FleetAge.short(since) ?? "") ago", copyable: false)
            }
            if let used = record.node.tokenLastUsedAt {
                DetailRow(label: "Token last used", value: "\(FleetAge.short(used) ?? "") ago", copyable: false)
            } else {
                DetailRow(label: "Token last used", value: "Never", copyable: false)
            }
            DetailRow(label: "Node ID", value: record.node.id, monospaced: true)
            WebLinkRow(title: "Reconfigure command on web", path: .node(id: record.node.id, view: .settings))
        } header: {
            Text("Enrollment")
        }
    }

    // MARK: Incidents

    @ViewBuilder
    private var incidents: some View {
        switch model.incidents {
        case .denied(let scope):
            Section("Incidents") { ScopeDeniedRow(scope: scope) }
        case .idle:
            EmptyView()
        default:
            let list = model.incidents.value ?? []
            if !list.isEmpty || FleetLoad.hasProblem(model.incidents) {
                Section("Open incidents") {
                    FleetSectionError(state: model.incidents, noun: "incidents") { Task { await model.refreshCore() } }
                    ForEach(list) { incident in
                        NavigationLink(value: AppRoute.monitoring(.incident(id: incident.id))) {
                            IncidentRow(incident: incident, canAdmin: store.can("monitor:admin")) { snoozing = $0 }
                        }
                    }
                }
            } else if model.incidents.value == nil {
                Section("Open incidents") { LoadingRows(label: "Loading incidents", count: 1) }
            }
        }
    }

    @ViewBuilder
    private func snoozeButtons(_ incident: Incident) -> some View {
        ForEach(IncidentSnoozeChoice.choices(now: Date(), mode: mode, locale: locale)) { choice in
            Button(choice.label) {
                Task { await runner.run(IncidentRow.snoozeIntent(incident, minutes: choice.minutes, until: choice.until)) }
            }
        }
        if incident.snoozed {
            Button("End snooze") { Task { await runner.run(IncidentRow.snoozeIntent(incident, minutes: 0, until: "")) } }
        }
        Button("Cancel", role: .cancel) {}
    }

    // MARK: Now

    @ViewBuilder
    private func now(_ record: FleetNodeRecord) -> some View {
        let node = record.node
        Section {
            switch node.honesty {
            case .disabled:
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Label("Not reporting while disabled", systemImage: "minus.circle")
                        .foregroundStyle(.secondary)
                    let missing = store.missing("node:admin")
                    Button("Enable \(node.displayName)") {
                        Task { await runner.run(FleetIntents.enable(FleetIntents.nodeRef(node))) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(missing != nil)
                    if let missing { Text("Needs \(missing)").textRole(.footnote) }
                }
                .padding(.vertical, Spacing.xs)
            case .offline:
                Label {
                    TimelineView(.periodic(from: .now, by: FleetAge.tick)) { context in
                        Text("Last reported \(FleetAge.short(node.lastSeen, now: context.date) ?? "a while") ago. Live numbers are hidden until it reports again.")
                    }
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.statusFailFill)
                }
                .foregroundStyle(.secondary)
                .frame(minHeight: Spacing.minimumTarget)
            default:
                ValueBarRow(label: "CPU", value: String(format: "%.0f%%", node.metrics.cpuPercent), fraction: node.metrics.cpuPercent / 100)
                ValueBarRow(label: "Memory", value: PercentFormatter.fraction(node.memoryUsedFraction), fraction: node.memoryUsedFraction)
                ValueBarRow(label: "Disk", value: PercentFormatter.fraction(node.diskUsedFraction), fraction: node.diskUsedFraction, threshold: 0.9)
                DetailRow(label: "Received", value: ByteFormatter.speed(node.metrics.netRxSpeed), copyable: false)
                DetailRow(label: "Sent", value: ByteFormatter.speed(node.metrics.netTxSpeed), copyable: false)
            }
        } header: {
            Text("Now")
        }
    }

    // MARK: History

    @ViewBuilder
    private var history: some View {
        Section {
            Picker("Range", selection: Binding(get: { model.historyRange }, set: { range in
                model.historyRange = range
                Task { await model.refreshHistory() }
            })) {
                ForEach(FleetMetricsRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            switch model.history {
            case .denied(let scope):
                ScopeDeniedRow(scope: scope)
            default:
                if let query = model.history.value {
                    FleetMetricChart(metric: .cpu, series: query.series(named: FleetMetric.cpu.rawValue),
                                     step: TimeInterval(max(query.stepSeconds, 1)), range: model.historyRange,
                                     reporting: model.record.value.map { FleetNodeReporting.isReporting($0.node.honesty) } ?? true,
                                     lastSeen: model.record.value?.node.lastSeen)
                } else if case .failed(let error, nil, _) = model.history {
                    ErrorRow(message: "Could not load history: \(error.localizedDescription)") { Task { await model.refreshHistory() } }
                } else {
                    LoadingRows(label: "Loading history", count: 1)
                }
            }
            NavigationLink(value: AppRoute.fleet(.nodeHistory(id: model.nodeID))) {
                Text("All metrics and status history")
            }
        } header: {
            Text("History")
        }
    }

    // MARK: Paths

    @ViewBuilder
    private func paths(_ record: FleetNodeRecord) -> some View {
        Section {
            switch model.paths {
            case .denied(let scope):
                ScopeDeniedRow(scope: scope)
            default:
                if let response = model.paths.value {
                    let worst = FleetPathPick.worst(response, nodeID: record.id)
                    if worst.isEmpty {
                        Text("This node takes part in no measured path.").foregroundStyle(.secondary)
                            .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                    }
                    ForEach(worst) { path in
                        NavigationLink(value: AppRoute.monitoring(.path(key: path.key))) {
                            PathRow(path: path, sourceName: name(path.source), targetName: path.targetNode.isEmpty ? nil : name(path.targetNode),
                                    judgesDegraded: response.judgesDegraded)
                        }
                    }
                    let total = FleetPathPick.count(response, nodeID: record.id)
                    if total > 0 {
                        Button {
                            router.select(tab: .monitor, scope: MonitorSegment.paths.rawValue, query: "source:\(record.node.displayName)")
                        } label: {
                            HStack {
                                Text(total == 1 ? "All paths (1)" : "All paths (\(total))")
                                Spacer()
                                Image(systemName: AppTab.monitor.symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                                Text("Opens in Monitor").font(.footnote).foregroundStyle(.secondary)
                            }
                            .frame(minHeight: Spacing.minimumTarget)
                        }
                        .tint(.primary)
                    }
                } else if case .failed(let error, nil, _) = model.paths {
                    ErrorRow(message: "Could not load paths: \(error.localizedDescription)") { Task { await model.refreshOverview() } }
                } else {
                    LoadingRows(label: "Loading paths", count: 2)
                }
            }
        } header: {
            Text("Paths")
        }
    }

    private func name(_ id: String) -> String {
        store.record(id: id)?.node.displayName ?? id
    }

    // MARK: Related pages

    @ViewBuilder
    private func related(_ record: FleetNodeRecord) -> some View {
        Section {
            NavigationLink(value: AppRoute.fleet(.nodeNetwork(id: record.id))) {
                FleetRelatedRow(title: "Effective network", symbol: "arrow.left.arrow.right", detail: networkDetail, style: failure(model.network))
            }
            switch model.sshGuard {
            case .denied(let scope):
                FleetRelatedRow(title: "SSH Guard", symbol: "lock.shield", detail: "Needs \(scope)")
            default:
                NavigationLink(value: AppRoute.sshGuard(.node(id: record.id))) {
                    FleetRelatedRow(title: "SSH Guard", symbol: "lock.shield", detail: sshGuardDetail, style: failure(model.sshGuard) ?? sshGuardStyle)
                }
            }
            NavigationLink(value: AppRoute.fleet(.nodeCapabilities(id: record.id))) {
                FleetRelatedRow(title: "Capabilities", symbol: "checkmark.shield", detail: capabilitiesDetail, style: failure(model.capabilities))
            }
            machine
            NavigationLink(value: AppRoute.fleet(.nodeBeacon(id: record.id))) {
                FleetRelatedRow(title: "Beacon", symbol: "dot.radiowaves.left.and.right", detail: beaconDetail, style: beaconFailure)
            }
        } header: {
            Text("Related")
        }
    }

    /// The row style for a read that failed with nothing earlier: never "Loading" forever.
    private func failure<T>(_ state: ResourceState<T>) -> StatusStyle? {
        FleetLoad.failedEmpty(state) ? StatusStyle(word: "could not load", symbol: "exclamationmark.triangle.fill", tone: .fail) : nil
    }

    private func pending<T>(_ state: ResourceState<T>) -> String {
        FleetLoad.failedEmpty(state) ? "Could not load" : "Loading"
    }

    private var beaconFailure: StatusStyle? {
        if case .failed(.notFound, _, _) = model.beacon { return nil }
        return failure(model.beacon)
    }

    @ViewBuilder
    private var machine: some View {
        switch model.machine {
        case .denied(let scope):
            FleetRelatedRow(title: "Machine", symbol: "shippingbox", detail: "Needs \(scope)")
        case .failed(.notFound, nil, _):
            FleetRelatedRow(title: "Machine", symbol: "shippingbox", detail: "No machine inventory on this server")
        default:
            if let found = model.machine.value {
                if let profile = found {
                    NavigationLink(value: AppRoute.inventory(.machine(id: profile.id))) {
                        FleetRelatedRow(title: "Machine", symbol: "shippingbox", detail: FleetMachineLine.detail(profile))
                    }
                } else {
                    FleetRelatedRow(title: "Machine", symbol: "shippingbox", detail: "No machine profile")
                }
            } else {
                FleetRelatedRow(title: "Machine", symbol: "shippingbox", detail: pending(model.machine), style: failure(model.machine))
            }
        }
    }

    private var networkDetail: String {
        switch model.network {
        case .denied(let scope): return "Needs \(scope)"
        default:
            guard let view = model.network.value else { return pending(model.network) }
            guard let outbound = view.outbound else { return "Outbound not reported" }
            if outbound.section.isRefused { return "Needs \(outbound.section.scope)" }
            let rules = outbound.ruleCount == 1 ? "1 rule" : "\(outbound.ruleCount) rules"
            return "\(outbound.effectiveTitle), \(rules)"
        }
    }

    private var sshGuardDetail: String {
        guard let status = model.sshGuard.value else { return pending(model.sshGuard) }
        let posture = StatusStyle.posture(SSHGuardPostureState(rawValue: status.posture.state) ?? .unknown).word
        let coverage = StatusStyle.coverage(SSHGuardBoard.coverage(for: status, scope: status.enrolled ? .enrolled : .undecided, now: Date())).word
        return "\(posture), \(coverage)"
    }

    private var sshGuardStyle: StatusStyle? {
        guard let status = model.sshGuard.value else { return nil }
        return StatusStyle.posture(SSHGuardPostureState(rawValue: status.posture.state) ?? .unknown)
    }

    private var capabilitiesDetail: String {
        switch model.capabilities {
        case .denied(let scope): return "Needs \(scope)"
        default:
            guard let caps = model.capabilities.value else { return pending(model.capabilities) }
            let admitted = caps.filter { $0.enforced && $0.allowed }.count
            let excluded = caps.filter { $0.state == "excluded" }.count
            return "\(admitted) admitted, \(excluded) excluded"
        }
    }

    private var beaconDetail: String {
        switch model.beacon {
        case .denied(let scope): return "Needs \(scope)"
        case .failed(.notFound, _, _): return "No beacon on this node"
        default:
            guard let beacon = model.beacon.value else { return pending(model.beacon) }
            return beacon.isEnabled ? "\(beacon.stateWord.prefix(1).uppercased() + beacon.stateWord.dropFirst()), epoch \(beacon.epoch)" : "Off"
        }
    }

    // MARK: Queued tasks

    @ViewBuilder
    private var queued: some View {
        if let tasks = model.queued.value, !tasks.isEmpty {
            Section("Queued tasks") {
                ForEach(tasks, id: \.id) { task in
                    NavigationLink(value: AppRoute.activity(.task(id: task.id))) { TaskRow(task: task) }
                }
            }
        } else if case .denied(let scope) = model.queued {
            Section("Queued tasks") { ScopeDeniedRow(scope: scope) }
        } else if FleetLoad.hasProblem(model.queued) {
            Section("Queued tasks") {
                FleetSectionError(state: model.queued, noun: "queued tasks") { Task { await model.refreshOverview() } }
            }
        }
    }
}

/// A row that leads to a related page: symbol, title and one line of state.
struct FleetRelatedRow: View {
    let title: String
    let symbol: String
    let detail: String
    var style: StatusStyle?

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: style?.symbol ?? symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(style?.tone.glyph ?? Color.accentText)
                    .frame(width: 28)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                // The role sets the color, so a problem uses the reason role rather than a later foregroundStyle.
                Text(detail)
                    .textRole(style.map { $0.tone.isProblem ? .rowReason($0.tone.word) : .rowDetail } ?? .rowDetail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: Spacing.minimumTarget)
        .accessibilityElement(children: .combine)
    }
}
