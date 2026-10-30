import SwiftUI

/// One entry of a node's merged timeline.
enum FleetTimelineItem: Identifiable {
    case audit(AuditEvent)
    case task(LatticeTask)
    case approval(Approval)

    var id: String {
        switch self {
        case .audit(let event): "audit:\(event.id)"
        case .task(let task): "task:\(task.id)"
        case .approval(let approval): "approval:\(approval.id)"
        }
    }

    var date: Date {
        switch self {
        case .audit(let event): event.at ?? .distantPast
        case .task(let task): task.createdAt ?? .distantPast
        case .approval(let approval): approval.createdAt ?? .distantPast
        }
    }

    var words: String {
        switch self {
        case .audit(let event): [event.action, event.actorID, event.reason].joined(separator: " ")
        case .task(let task): [task.id, task.status, task.interpreter].joined(separator: " ")
        case .approval(let approval): [approval.action, approval.plugin, approval.status].joined(separator: " ")
        }
    }
}

/// The Activity view's scopes (`.searchScopes`, broadest first).
enum FleetTimelineScope: String, CaseIterable, Hashable {
    case all = "All", changes = "Changes", tasks = "Tasks", approvals = "Approvals"
}

/// NodeDetail's Activity tab (M2-03): audit events, tasks and approvals for
/// the node, newest first, with a Logs row to the log explorer.
struct NodeActivitySection: View {
    let model: FleetNodeDetailModel

    @State private var scope: FleetTimelineScope = .all
    @State private var text = ""

    var body: some View {
        if let record = model.record.value {
            List {
                FleetNodeHeader(record: record, fleetVersions: model.fleetVersions)
                Section {
                    NavigationLink(value: AppRoute.evidence(.logs(nodeID: model.nodeID))) {
                        FleetRelatedRow(title: "Logs", symbol: "text.alignleft", detail: "This node's log lines in the explorer")
                    }
                }
                denied
                let items = timeline
                Section {
                    FleetSectionError(state: model.audit, noun: "audit events") { Task { await model.refreshActivity() } }
                    FleetSectionError(state: model.tasks, noun: "tasks") { Task { await model.refreshActivity() } }
                    FleetSectionError(state: model.approvals, noun: "approvals") { Task { await model.refreshActivity() } }
                    if items.isEmpty, anyWaiting {
                        LoadingRows(label: "Loading activity", count: 3)
                    } else if items.isEmpty, !anyFailedEmpty {
                        ContentUnavailableView(text.isEmpty ? "No activity for this node" : "No matches", systemImage: "clock.arrow.circlepath")
                    }
                    ForEach(items) { item in row(item) }
                } header: {
                    Text("Timeline")
                } footer: {
                    FleetFooter(state: model.audit)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search activity")
            .searchScopes($scope, activation: .onSearchPresentation) {
                ForEach(FleetTimelineScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .refreshable { await model.refreshActivity() }
        }
    }

    /// Some source has not answered yet, so an empty timeline is not yet "no activity".
    private var anyWaiting: Bool {
        FleetLoad.isWaiting(model.audit) || FleetLoad.isWaiting(model.tasks) || FleetLoad.isWaiting(model.approvals)
    }

    /// A source that failed with nothing to show: "No activity" would then be a guess.
    private var anyFailedEmpty: Bool {
        FleetLoad.failedEmpty(model.audit) || FleetLoad.failedEmpty(model.tasks) || FleetLoad.failedEmpty(model.approvals)
    }

    private func deniedScope<T>(_ state: ResourceState<T>) -> String? {
        if case .denied(let scope) = state { return scope }
        return nil
    }

    @ViewBuilder
    private var denied: some View {
        let missing = [deniedScope(model.audit), deniedScope(model.tasks), deniedScope(model.approvals)].compactMap { $0 }
        if !missing.isEmpty {
            Section { ForEach(missing, id: \.self) { ScopeDeniedRow(scope: $0) } }
        }
    }

    private var timeline: [FleetTimelineItem] {
        var items: [FleetTimelineItem] = []
        if scope == .all || scope == .changes { items += (model.audit.value ?? []).map(FleetTimelineItem.audit) }
        if scope == .all || scope == .tasks { items += (model.tasks.value ?? []).map(FleetTimelineItem.task) }
        if scope == .all || scope == .approvals { items += (model.approvals.value ?? []).map(FleetTimelineItem.approval) }
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty { items = items.filter { $0.words.lowercased().contains(needle) } }
        return items.sorted { $0.date > $1.date }
    }

    @ViewBuilder
    private func row(_ item: FleetTimelineItem) -> some View {
        switch item {
        case .audit(let event):
            NavigationLink(value: AppRoute.activity(.auditEvent(id: event.id))) { AuditRow(event: event) }
        case .task(let task):
            NavigationLink(value: AppRoute.activity(.task(id: task.id))) { TaskRow(task: task) }
        case .approval(let approval):
            ApprovalRowLink(approval: approval, nodeName: model.node?.displayName)
        }
    }
}

/// An approval in the node timeline; it opens in Review.
private struct ApprovalRowLink: View {
    let approval: Approval
    let nodeName: String?
    @Environment(Router.self) private var router

    var body: some View {
        Button {
            router.present(.review(.single(approval.id)))
        } label: {
            ApprovalRow(approval: approval, nodeName: nodeName)
        }
        .tint(.primary)
    }
}
