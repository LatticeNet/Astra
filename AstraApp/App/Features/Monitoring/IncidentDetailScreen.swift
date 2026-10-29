import SwiftUI
import UIKit

/// The notify deliveries that carried one incident, read from the Sent log.
@MainActor @Observable
final class MonitoringDeliveriesModel {
    private(set) var deliveries: ResourceState<[NotifyDelivery]> = .idle
    static let requirement = ScopeRequirement("notify:admin")

    @discardableResult
    func load(incidentID: String, session: SessionStore) async -> Bool {
        if let missing = session.missing(Self.requirement), !missing.isEmpty {
            deliveries = .denied(scope: missing.joined(separator: " and "))
            return true
        }
        guard let client = session.client else { return false }
        deliveries = deliveries.reloading
        do {
            let all = try await client.fetchDeliveries(query: DeliveryQuery(limit: 200)).deliveries
            deliveries = .loaded(all.filter { $0.incidentIDs.contains(incidentID) }.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }, at: Date())
            return true
        } catch {
            if MonitoringStore.isCancellation(error) { deliveries = deliveries.value.map { .loaded($0, at: deliveries.loadedAt ?? Date()) } ?? .idle; return true }
            deliveries = deliveries.failing(LatticeAPIError(error), surface: "Notify deliveries", missingScope: "notify:admin")
            return false
        }
    }
}

/// M3-11 Incident.
struct IncidentDetailScreen: View {
    let id: String

    @Environment(MonitoringStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    @State private var deliveries = MonitoringDeliveriesModel()
    @State private var snoozeTarget: Incident?
    @State private var failure: String?
    @State private var retry: WriteIntent?

    var body: some View {
        content
            .navigationTitle(store.incident(id: id).map(Self.shortSubject) ?? "Incident")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(store.incident(id: id).map { style($0).word } ?? "")
            .toolbar { toolbar }
            .toolbarVisibility(showsBottomBar ? .visible : .automatic, for: .bottomBar)
            // The bottom toolbar and the floating tab bar share the same edge;
            // while the actions show, the tab bar steps aside (back returns it).
            .toolbarVisibility(showsBottomBar ? .hidden : .automatic, for: .tabBar)
            .monitoringSnoozeDialog($snoozeTarget)
            .announcing(failure)
            .polling(.monitoring, version: changes.version([.incidents, .maintenance])) {
                await nodes.refreshIfOlder(than: 60)
                let delivered = Task { await deliveries.load(incidentID: id, session: session) }
                let ok = await store.refreshIncidents()
                _ = await delivered.value
                if store.paths.value == nil, store.incident(id: id)?.kind.hasPrefix("path.") == true {
                    await store.refreshPaths(window: appState.monitorWindow)
                }
                return ok
            }
    }

    /// "edge-tyo-1 to relay-fra-1" or "relay-fra-2": the subject, arrows spoken as "to".
    static func shortSubject(_ incident: Incident) -> String {
        let subject = incident.subject.isEmpty ? (incident.nodeName.isEmpty ? incident.displayTitle : incident.nodeName) : incident.subject
        return subject.replacingOccurrences(of: " → ", with: " to ")
    }

    private func style(_ incident: Incident) -> StatusStyle {
        StatusStyle.incident(incident.displayState(now: Date()), snoozedUntil: incident.snoozedUntil.map { TimeDisplay.clock($0, mode: mode, locale: locale) })
    }

    @ViewBuilder
    private var content: some View {
        if let incident = store.incident(id: id) {
            detail(incident)
        } else if store.incidents.value != nil {
            WholeScreenState {
                ContentUnavailableView {
                    Label("Not found in the last 500", systemImage: "exclamationmark.magnifyingglass")
                } description: {
                    Text("The incident list holds no \(id). It may be older than what the server keeps.")
                } actions: {
                    Button("Open on web") { router.openOnWeb(.incident(id: id, query: "")) }
                }
            }
        } else {
            ResourceView(state: store.incidents, noun: "the incident", retry: { Task { await store.refreshIncidents() } }) { _ in EmptyView() }
        }
    }

    // MARK: Detail

    private func detail(_ incident: Incident) -> some View {
        let style = style(incident)
        let pathKey = MonitoringIncidentLink.pathKey(for: incident, in: store.pathItems { nodes.nodes[$0]?.displayName })
        return List {
            if let failure {
                ErrorRow(message: failure) {
                    if let retry { Task { await perform(retry) } }
                }
            }
            MonitoringRefreshError(state: store.incidents, noun: "the incident") { Task { await store.refreshIncidents() } }
            Section {
                Text(incident.displayTitle)
                    .textRole(.detailHeader)
                    .accessibilityAddTraits(.isHeader)
                HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                    StatusGlyph(style: style)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("\(incident.severity.capitalized), \(style.word)")
                            .foregroundStyle(style.tone.isProblem ? style.tone.word : .primary)
                        if incident.flapping {
                            Label("flapping, \(incident.flaps) flaps", systemImage: StatusStyle.flapping.symbol)
                                .textRole(.rowDetail)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                if incident.state == "pending", let opens = incident.opensAt {
                    Label("Opens at \(TimeDisplay.clock(opens, mode: mode, locale: locale)) if still failing", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
                subjectRow(incident, pathKey: pathKey)
                if let opened = incident.openedAt ?? incident.since {
                    DetailRow(label: "Opened", value: TimeDisplay.dateTime(opened, mode: mode, locale: locale),
                              secondary: TimeDisplay.otherZone(opened, mode: mode, locale: locale), copyable: false)
                    DetailRow(label: "Duration", value: TimeDisplay.duration((incident.resolvedAt ?? Date()).timeIntervalSince(opened), locale: locale), copyable: false)
                }
                if incident.flaps > 0 {
                    DetailRow(label: "Flaps", value: String(incident.flaps), copyable: false)
                }
            }
            evidenceSection(incident, pathKey: pathKey)
            notificationSection(incident)
            deliveriesSection
            timelineSection(incident)
            if let window = holdingWindow(incident) {
                Section {
                    NavigationLink(value: AppRoute.monitoring(.maintenanceWindow(id: window.id))) {
                        MonitoringWindowRow(window: window)
                    }
                } header: {
                    Text("Held by").accessibilityAddTraits(.isHeader)
                }
            } else if !incident.maintenance.isEmpty {
                Section {
                    DetailRow(label: "Held by", value: incident.maintenance, copyable: false)
                }
            }
            Section {
                WebLinkRow(path: .incident(id: incident.id, query: incident.subject.isEmpty ? incident.nodeName : incident.subject))
            } footer: {
                MonitoringFreshness(state: store.incidents, cadence: .monitoring)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await store.refreshIncidents()
            await deliveries.load(incidentID: id, session: session)
        }
    }

    @ViewBuilder
    private func subjectRow(_ incident: Incident, pathKey: String?) -> some View {
        if let pathKey {
            NavigationLink(value: AppRoute.monitoring(.path(key: pathKey))) {
                LabeledContent("Path", value: Self.shortSubject(incident)).frame(minHeight: Spacing.minimumTarget)
            }
        }
        if !incident.nodeID.isEmpty {
            NavigationLink(value: AppRoute.fleet(.node(id: incident.nodeID))) {
                HStack {
                    LabeledContent("Node", value: incident.nodeName.isEmpty ? nodes.name(for: incident.nodeID) : incident.nodeName)
                    if let node = nodes.nodes[incident.nodeID] { StatusGlyph(style: .node(node.honesty), font: .body) }
                }
                .frame(minHeight: Spacing.minimumTarget)
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func evidenceSection(_ incident: Incident, pathKey: String?) -> some View {
        Section {
            if !incident.detail.isEmpty {
                Text(incident.detail)
            }
            if let pathKey {
                NavigationLink(value: AppRoute.monitoring(.path(key: pathKey))) {
                    Label("Latency and loss chart", systemImage: "chart.xyaxis.line").frame(minHeight: Spacing.minimumTarget)
                }
            }
            if !incident.monitorID.isEmpty, store.monitor(id: incident.monitorID) != nil || store.monitors.value == nil {
                NavigationLink(value: AppRoute.monitoring(.check(id: incident.monitorID))) {
                    Label("Last check results", systemImage: "checklist").frame(minHeight: Spacing.minimumTarget)
                }
            }
            if !incident.nodeID.isEmpty, pathKey == nil {
                NavigationLink(value: AppRoute.fleet(.node(id: incident.nodeID))) {
                    Label(incident.kind == "agent.stalled" ? "Agent loop health" : "Node, last seen and history", systemImage: "server.rack")
                        .frame(minHeight: Spacing.minimumTarget)
                }
            }
        } header: {
            Text("Evidence").accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func notificationSection(_ incident: Incident) -> some View {
        Section {
            if let list = deliveries.deliveries.value {
                ForEach(list.filter { !$0.recovery }.prefix(3), id: \.id) { delivery in
                    truthRow(delivery)
                }
                if list.isEmpty {
                    Label(incident.notified.isEmpty ? "No notification went out" : "Notified at \(incident.notifiedAt.map { TimeDisplay.clock($0, mode: mode, locale: locale) } ?? "an unknown time")", systemImage: "bell.slash")
                        .foregroundStyle(.secondary)
                }
            } else if !incident.notified.isEmpty, let at = incident.openNotifiedAt ?? incident.notifiedAt {
                Label("Notified at \(TimeDisplay.clock(at, mode: mode, locale: locale))", systemImage: "bell")
            }
            if incident.owedRecovery {
                Label("Recovery still owed", systemImage: "bell.badge").foregroundStyle(Color.statusWarnText)
            }
            if incident.owedOpen {
                Label("Open message still owed", systemImage: "bell.badge").foregroundStyle(Color.statusWarnText)
            }
            if !incident.suppressed.isEmpty {
                Label("Suppressed: \(incident.suppressed)", systemImage: "bell.slash").foregroundStyle(.secondary)
            }
            ForEach(incident.escalated.sorted { $0.value < $1.value }, id: \.key) { step, at in
                Label("Escalated to \(step) at \(TimeDisplay.clock(at, mode: mode, locale: locale))", systemImage: "arrow.up.right.circle")
            }
        } header: {
            Text("Notifications").accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func truthRow(_ delivery: NotifyDelivery) -> some View {
        let channel = delivery.channelName.isEmpty ? delivery.channelKind : delivery.channelName
        let time = (delivery.settledAt ?? delivery.createdAt).map { TimeDisplay.clock($0, mode: mode, locale: locale) } ?? ""
        switch delivery.outcome {
        case "sent":
            Label("Notified via \(channel) at \(time)", systemImage: "bell")
        case "failed":
            Label("Notification failed via \(channel) at \(time)", systemImage: "bell.slash").foregroundStyle(Color.statusFailText)
        default:
            Label("\(delivery.outcome.capitalized) via \(channel.isEmpty ? "no channel" : channel) at \(time)", systemImage: "bell.slash").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var deliveriesSection: some View {
        Section {
            switch deliveries.deliveries {
            case .denied(let scope):
                ScopeDeniedRow(scope: scope)
            case .failed(let error, nil, _):
                ErrorRow(message: "Could not load deliveries: \(error.localizedDescription)") { Task { await deliveries.load(incidentID: id, session: session) } }
            default:
                if let list = deliveries.deliveries.value {
                    if list.isEmpty {
                        Text("No delivery in the newest 200 carried this incident.").foregroundStyle(.secondary)
                    }
                    ForEach(list) { delivery in
                        NavigationLink(value: AppRoute.notify(.delivery(id: delivery.id))) {
                            deliveryRow(delivery)
                        }
                    }
                } else {
                    LoadingRows(label: "Loading deliveries", count: 2)
                }
            }
        } header: {
            Text("Deliveries").accessibilityAddTraits(.isHeader)
        }
    }

    private func deliveryRow(_ delivery: NotifyDelivery) -> some View {
        let style: StatusStyle = switch delivery.outcome {
        case "sent": StatusStyle(word: "sent", symbol: "checkmark.circle.fill", tone: .ok)
        case "failed": StatusStyle(word: "failed", symbol: "xmark.circle.fill", tone: .fail)
        default: StatusStyle(word: delivery.outcome.replacingOccurrences(of: "_", with: " "), symbol: "bell.slash", tone: .quiet)
        }
        let channel = delivery.channelName.isEmpty ? "No channel" : delivery.channelName
        return StatusRow(
            style: style,
            title: channel,
            detail: [delivery.recovery ? "recovery" : delivery.eventType, delivery.createdAt.map { TimeDisplay.clock($0, mode: mode, locale: locale) }].compactMap { $0 }.joined(separator: ", "),
            reason: delivery.reason.isEmpty ? nil : delivery.reason,
            accessibilityPhrase: "\(channel), \(style.word)"
        )
    }

    private func timelineSection(_ incident: Incident) -> some View {
        Section {
            if let opened = incident.firstOpenedAt ?? incident.openedAt ?? incident.since {
                timelineRow("Opened", opened, symbol: "exclamationmark.circle")
            }
            if let notified = incident.openNotifiedAt ?? incident.notifiedAt {
                timelineRow("Notified", notified, symbol: "bell")
            }
            if let acked = incident.ackedAt {
                timelineRow(incident.ackedBy.isEmpty ? "Acknowledged" : "Acknowledged by \(incident.ackedBy)", acked, symbol: "person.crop.circle.badge.checkmark")
            }
            if let snoozed = incident.snoozedUntil, IncidentFilter.isSnoozed(incident, now: Date()) {
                timelineRow(incident.snoozedBy.isEmpty ? "Snoozed until" : "Snoozed by \(incident.snoozedBy) until", snoozed, symbol: "moon.zzz")
            }
            if let resolved = incident.resolvedAt {
                timelineRow("Resolved", resolved, symbol: "checkmark.circle")
            }
        } header: {
            Text("Timeline").accessibilityAddTraits(.isHeader)
        }
    }

    private func timelineRow(_ label: String, _ date: Date, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Image(systemName: symbol).foregroundStyle(Color.statusQuiet).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(label)
                Text("\(TimeDisplay.dateTime(date, mode: mode, locale: locale)), \(TimeDisplay.relative(date, now: Date(), locale: locale))")
                    .textRole(.stamp)
            }
        }
        .frame(minHeight: Spacing.minimumTarget)
        .accessibilityElement(children: .combine)
    }

    private func holdingWindow(_ incident: Incident) -> MaintenanceWindow? {
        guard !incident.maintenance.isEmpty || !incident.maintenanceID.isEmpty else { return nil }
        return ((store.windows.value?.windows ?? []) + (store.incidents.value?.windows ?? [])).first { MonitoringMaintenance.holds($0, incident) }
    }

    // MARK: Actions

    private var showsBottomBar: Bool {
        guard verticalSizeClass != .compact, let incident = store.incident(id: id) else { return false }
        return IncidentFilter.isActive(incident) && !incident.isDerivedPending
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        let incident = store.incident(id: id)
        let actions = incident.map { IncidentActions.of($0, now: Date(), canAdmin: true) } ?? .none
        let available = incident.map { IncidentFilter.isActive($0) && !$0.isDerivedPending } ?? false
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if verticalSizeClass == .compact, available, let incident { maintenanceButton(incident) }
                Button("Open on web", systemImage: "safari") {
                    router.openOnWeb(.incident(id: id, query: incident.map { $0.subject.isEmpty ? $0.nodeName : $0.subject } ?? ""))
                }
                Button("Copy link", systemImage: "link") { UIPasteboard.general.url = LatticeDeepLink.incident(id: id).customURL }
                Button("Copy ID", systemImage: "number") { UIPasteboard.general.string = id }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
        if available, let incident {
            if verticalSizeClass == .compact {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ackButton(incident, actions: actions)
                    snoozeButton(incident)
                }
            } else {
                ToolbarItemGroup(placement: .bottomBar) {
                    ackButton(incident, actions: actions)
                    snoozeButton(incident)
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) { maintenanceButton(incident) }
            }
        }
    }

    @ViewBuilder
    private func ackButton(_ incident: Incident, actions: IncidentActions) -> some View {
        if actions.acknowledge {
            Button("Acknowledge", systemImage: "person.crop.circle.badge.checkmark") { Task { await perform(IncidentRow.acknowledgeIntent(incident)) } }
                .disabled(!store.canAdmin)
                .accessibilityHint("Stops repeat alerts")
        } else if incident.state == "acknowledged" {
            Button("Unacknowledge", systemImage: "person.crop.circle.badge.xmark") { Task { await perform(IncidentRow.unacknowledgeIntent(incident)) } }
                .disabled(!store.canAdmin)
                .accessibilityHint("Repeat alerts resume")
        }
    }

    private func snoozeButton(_ incident: Incident) -> some View {
        Button("Snooze", systemImage: "moon.zzz") { snoozeTarget = incident }
            .disabled(!store.canAdmin)
    }

    private func maintenanceButton(_ incident: Incident) -> some View {
        Button("Start maintenance", systemImage: "wrench.and.screwdriver") { router.present(.maintenanceStart(nodeID: incident.nodeID.isEmpty ? nil : incident.nodeID)) }
            .disabled(!store.canAdmin)
    }

    /// Runs a T1 write; a refusal or lost answer stays on screen with Retry.
    private func perform(_ intent: WriteIntent) async {
        failure = nil
        let outcome = await runner.run(intent)
        switch outcome {
        case .refused(.notSent("Cancelled"), _):
            break
        case .refused(_, let message), .unknown(let message):
            failure = message
            retry = intent
        default:
            retry = nil
        }
    }
}
