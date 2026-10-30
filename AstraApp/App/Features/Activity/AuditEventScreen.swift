import SwiftUI

/// M4-05 Audit event. Every field, the time in both zones, the plan seal
/// when the event names an approval, and links to the node, task, approval
/// and correlation trace.
struct AuditEventScreen: View {
    let id: String

    @Environment(AuditStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(NodeDirectory.self) private var nodes
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    @State private var model = ActivityAuditEventModel()

    var body: some View {
        content
            .navigationTitle(model.event.value.map { AuditActionWords.words(for: $0.action) } ?? "Audit event")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(model.event.value.map { ActivityStyle.decision(AuditModel.decision(of: $0)).word } ?? "")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ActivityObjectMenu(link: .auditEvent(id: id), web: .auditEvent(id: id), objectID: id)
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
            .task {
                await nodes.refreshIfOlder(than: 60)
                await model.load(id: id, hint: store.event(id: id), session: session)
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.notFound {
            WholeScreenState {
                ContentUnavailableView {
                    Label("Not found in the last \(AuditModel.lookupPageSize * 10) events", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("The event is older than the newest \(AuditModel.lookupPageSize * 10), or this token cannot see its node.")
                } actions: {
                    Button("Open on web") { router.openOnWeb(.auditEvent(id: id)) }
                }
            }
        } else {
            ActivityResource(state: model.event, noun: "the event", retry: reload) { event in
                detail(event)
            }
        }
    }

    private func reload() {
        Task { await model.load(id: id, hint: store.event(id: id), session: session) }
    }

    private func detail(_ event: AuditEvent) -> some View {
        let words = AuditActionWords.words(for: event.action)
        let style = ActivityStyle.decision(AuditModel.decision(of: event))
        return List {
            Section {
                // The title can truncate; the full sentence leads the content (5.0).
                Text(sentence(event, words: words))
                    .textRole(.detailHeader)
                    .accessibilityAddTraits(.isHeader)
                ActivityStateHeader(style: style, reason: event.reason.isEmpty ? nil : event.reason)
            }
            if let approvalID = AuditModel.approvalID(of: event) {
                approvalSection(approvalID)
            }
            Section {
                DetailRow(label: "Action", value: event.action, monospaced: true)
                if !event.actorID.isEmpty { DetailRow(label: "Actor", value: event.actorID) }
                if !event.tokenID.isEmpty { DetailRow(label: "Token", value: event.tokenID, monospaced: true) }
                if !event.scope.isEmpty { DetailRow(label: "Scope", value: event.scope, monospaced: true) }
                DetailRow(label: "Decision", value: event.decision.isEmpty ? "none recorded" : event.decision, copyable: false)
                if let at = event.at {
                    DetailRow(label: "Time", value: TimeDisplay.dateTime(at, mode: mode, locale: locale),
                              secondary: TimeDisplay.otherZone(at, mode: mode, locale: locale), copyable: false)
                }
                DetailRow(label: "Event ID", value: event.id, monospaced: true)
            } header: {
                Text("Event").accessibilityAddTraits(.isHeader)
            }
            linksSection(event)
            if !event.metadata.isEmpty {
                Section {
                    ForEach(event.metadata.keys.sorted(), id: \.self) { key in
                        DetailRow(label: key, value: event.metadata[key] ?? "", monospaced: true)
                    }
                } header: {
                    Text("Metadata").accessibilityAddTraits(.isHeader)
                }
            }
            Section {
                WebLinkRow(path: .auditEvent(id: event.id))
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.load(id: id, hint: nil, session: session) }
    }

    private func sentence(_ event: AuditEvent, words: String) -> String {
        var text = words
        if !event.actorID.isEmpty { text += " by \(event.actorID)" }
        if !event.nodeID.isEmpty { text += " on \(nodes.name(for: event.nodeID))" }
        return text
    }

    @ViewBuilder
    private func approvalSection(_ approvalID: String) -> some View {
        Section {
            Button {
                router.present(.review(.single(approvalID)))
            } label: {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Approval").textRole(.rowDetail)
                    Text(model.approval.map { ApprovalEvents.title(for: $0) } ?? approvalID)
                        .foregroundStyle(Color.accentText)
                }
                .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget, alignment: .leading)
            }
            .accessibilityHint("Opens the approval with its plan")
            if let seal = model.approval?.planSHA256, !seal.isEmpty {
                SealLabel(sha256: seal, state: .unverified, placement: .standalone)
            } else if model.approvalUnreadable {
                Text("This token cannot read the approval, so its plan seal is not shown.")
                    .textRole(.footnote)
            } else if let error = model.approvalError {
                ErrorRow(message: "Could not read the approval: \(error.localizedDescription)") {
                    guard let client = session.client else { return }
                    Task { await model.loadApproval(approvalID, client: client) }
                }
            }
        } header: {
            Text("Plan").accessibilityAddTraits(.isHeader)
        } footer: {
            if model.approval != nil {
                Text("The seal is the approval's plan hash as the server lists it. Review hashes the plan on this iPhone before any decision.")
            }
        }
    }

    @ViewBuilder
    private func linksSection(_ event: AuditEvent) -> some View {
        let taskID = AuditModel.taskID(of: event)
        if !event.nodeID.isEmpty || taskID != nil || !event.correlationID.isEmpty {
            Section {
                if !event.nodeID.isEmpty {
                    ActivityLinkRow(label: "Node", value: nodes.name(for: event.nodeID), route: .fleet(.node(id: event.nodeID)))
                }
                if let taskID {
                    ActivityLinkRow(label: "Task", value: taskID, monospaced: true, route: .activity(.task(id: taskID)))
                }
                if !event.correlationID.isEmpty {
                    ActivityLinkRow(label: "Trace", value: event.correlationID, monospaced: true, route: .activity(.trace(correlationID: event.correlationID)))
                }
            } header: {
                Text("Related").accessibilityAddTraits(.isHeader)
            } footer: {
                if !event.correlationID.isEmpty {
                    Text("The trace lists every event of the same request, oldest first.")
                }
            }
        }
    }
}

/// The event screen's own data: the event, found on the list or by paging
/// it, and the approval it names.
@MainActor @Observable
final class ActivityAuditEventModel {
    private(set) var event: ResourceState<AuditEvent> = .idle
    private(set) var approval: Approval?
    private(set) var approvalUnreadable = false
    /// A read that failed for another reason than scope, kept with Retry.
    private(set) var approvalError: LatticeAPIError?
    private(set) var notFound = false

    func load(id: String, hint: AuditEvent?, session: SessionStore) async {
        if let missing = session.missing(AuditStore.readRequirement), !missing.isEmpty {
            event = .denied(scope: missing.joined(separator: " and "))
            return
        }
        guard let client = session.client else { return }
        if let hint {
            event = .loaded(hint, at: Date())
        } else {
            let before = event
            event = before.reloading
            do {
                guard let found = try await client.auditFind(id: id) else {
                    notFound = true
                    return
                }
                event = .loaded(found, at: Date())
            } catch {
                if TasksStore.isCancellation(error) { event = before; return }
                let apiError = LatticeAPIError(error)
                if case .invalidResponse = apiError { session.markCompanionBehind("Audit event") }
                event = event.failing(apiError, surface: "Audit event", missingScope: "audit:read")
                return
            }
        }
        if let value = event.value, let approvalID = AuditModel.approvalID(of: value), approval == nil {
            await loadApproval(approvalID, client: client)
        }
    }

    func loadApproval(_ approvalID: String, client: LatticeClient) async {
        do {
            approval = try await client.fetchApproval(id: approvalID)
            approvalUnreadable = false
            approvalError = nil
        } catch {
            if TasksStore.isCancellation(error) { return }
            let apiError = LatticeAPIError(error)
            switch apiError {
            case .forbidden, .notFound: approvalUnreadable = true
            default: approvalError = apiError
            }
        }
    }
}
