import SwiftUI

/// M4-06 Trace. Every event of one request, oldest first, as a timeline,
/// with the approvals and tasks the request touched.
struct CorrelationTraceScreen: View {
    let correlationID: String

    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @Environment(NodeDirectory.self) private var nodes
    @Environment(Router.self) private var router
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    @State private var model = ActivityTraceModel()

    var body: some View {
        ActivityResource(state: model.trace, noun: "the trace", retry: reload) { trace in
            timeline(trace)
        }
        .navigationTitle("Trace")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(correlationID)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ActivityObjectMenu(link: .trace(correlationID: correlationID), web: .trace(correlationID: correlationID), objectID: correlationID)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .polling(.standard, version: changes.version([.audit, .tasks, .approvals])) {
            await nodes.refreshIfOlder(than: 60)
            return await model.load(correlationID: correlationID, session: session)
        }
    }

    private func reload() {
        Task { await model.load(correlationID: correlationID, session: session) }
    }

    private func timeline(_ trace: ActivityTrace) -> some View {
        let summary = AuditModel.summarize(trace.events)
        let approvals = AuditModel.referencedApprovalIDs(trace.events)
        let tasks = AuditModel.referencedTaskIDs(trace.events)
        return List {
            ActivityRefreshError(state: model.trace, noun: "the trace", retry: reload)
            Section {
                Text(headline(summary))
                    .textRole(.detailHeader)
                    .accessibilityAddTraits(.isHeader)
                if let span = span(summary) {
                    Text(span).textRole(.rowDetail)
                }
                if !summary.nodes.isEmpty {
                    Text("Nodes: " + summary.nodes.map { nodes.name(for: $0) }.joined(separator: ", "))
                        .textRole(.rowDetail)
                }
            }
            if trace.events.isEmpty {
                ContentUnavailableView {
                    Label("No events in this trace", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("No event this token can see carries \(correlationID).")
                }
            } else {
                Section {
                    ForEach(Array(trace.events.enumerated()), id: \.element.id) { index, event in
                        NavigationLink(value: AppRoute.activity(.auditEvent(id: event.id))) {
                            ActivityTraceRow(event: event, isFirst: index == 0, isLast: index == trace.events.count - 1, nodeName: nodes.name(for:))
                        }
                        // One continuous rail: no separators, no gaps between steps.
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: Spacing.l, bottom: 0, trailing: Spacing.l))
                    }
                } header: {
                    Text("Timeline, oldest first").accessibilityAddTraits(.isHeader)
                } footer: {
                    if trace.truncated {
                        Text("The trace is longer than this iPhone reads at once. Open it on the web for the rest.")
                    }
                }
            }
            if !approvals.isEmpty || !tasks.isEmpty {
                Section {
                    ForEach(approvals, id: \.self) { id in
                        Button {
                            router.present(.review(.single(id)))
                        } label: {
                            Label {
                                Text(id).font(TextRole.identifierInDetail.font)
                            } icon: {
                                Image(systemName: "hand.raised").foregroundStyle(Color.accentText)
                            }
                            .frame(minHeight: Spacing.minimumTarget)
                        }
                        .accessibilityLabel("Approval \(id)")
                        .accessibilityHint("Opens the approval with its plan")
                    }
                    ForEach(tasks, id: \.self) { id in
                        NavigationLink(value: AppRoute.activity(.task(id: id))) {
                            Label {
                                Text(id).font(TextRole.identifierInDetail.font)
                            } icon: {
                                Image(systemName: "terminal").foregroundStyle(.secondary)
                            }
                            .frame(minHeight: Spacing.minimumTarget)
                        }
                        .accessibilityLabel("Task \(id)")
                    }
                } header: {
                    Text("What this request touched").accessibilityAddTraits(.isHeader)
                }
            }
            Section {
                WebLinkRow(path: .trace(correlationID: correlationID))
            } footer: {
                ActivityFreshness(state: model.trace)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.load(correlationID: correlationID, session: session) }
    }

    private func headline(_ summary: AuditTraceSummary) -> String {
        let events = summary.total == 1 ? "1 event" : "\(summary.total) events"
        return summary.denied == 0 ? events : "\(events), \(summary.denied) denied"
    }

    private func span(_ summary: AuditTraceSummary) -> String? {
        guard let first = summary.firstAt else { return nil }
        let start = TimeDisplay.dateTime(first, mode: mode, locale: locale)
        guard let last = summary.lastAt, last > first else { return "At \(start)" }
        return "From \(start), over \(TaskLeaseProgress.formatLeaseAge(last.timeIntervalSince(first)))"
    }
}

/// One step of the timeline: the time leads, a rail joins the steps, and the
/// decision shows as symbol and word.
struct ActivityTraceRow: View {
    let event: AuditEvent
    let isFirst: Bool
    let isLast: Bool
    let nodeName: (String) -> String

    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var glyphWidth: CGFloat = 28

    var body: some View {
        let style = ActivityStyle.decision(AuditModel.decision(of: event))
        let words = AuditActionWords.words(for: event.action)
        let time = event.at.map { TimeDisplay.clock($0, mode: mode, locale: locale) } ?? ""
        HStack(alignment: .top, spacing: Spacing.m) {
            if !typeSize.isAccessibilitySize {
                StatusGlyph(style: style)
                    .frame(width: glyphWidth, height: glyphWidth)
                    // The rail stops at the glyph instead of showing through its open center.
                    .background(Circle().fill(Color(uiColor: .secondarySystemGroupedBackground)))
                    .padding(.top, Spacing.m)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background { rail }
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(time).textRole(.stamp)
                Text(typeSize.isAccessibilitySize ? "\(Text(Image(systemName: style.symbol)).foregroundStyle(style.tone.glyph)) \(words)" : "\(words)")
                    .textRole(.rowTitle)
                Text(detail(style)).textRole(.rowDetail)
                if style.tone.isProblem, !event.reason.isEmpty {
                    Text(event.reason).textRole(.rowReason(style.tone.word))
                }
            }
            .padding(.vertical, Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: Spacing.minimumTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([time, words, style.word, detail(style), style.tone.isProblem ? event.reason : ""].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    /// The line that joins the steps, through the glyph column's full height:
    /// it starts at the first glyph and ends at the last.
    private var rail: some View {
        GeometryReader { proxy in
            let center = Spacing.m + glyphWidth / 2
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(width: 1.5)
                .frame(maxWidth: .infinity)
                .padding(.top, isFirst ? center : 0)
                .frame(height: isLast ? center : proxy.size.height, alignment: .top)
        }
        .accessibilityHidden(true)
    }

    private func detail(_ style: StatusStyle) -> String {
        var parts = [style.word]
        if !event.actorID.isEmpty { parts.append(event.actorID) }
        if !event.nodeID.isEmpty { parts.append(nodeName(event.nodeID)) }
        if let object = AuditModel.object(of: event) { parts.append(object) }
        return parts.joined(separator: " · ")
    }
}

struct ActivityTrace: Sendable {
    var events: [AuditEvent]
    var truncated: Bool
}

@MainActor @Observable
final class ActivityTraceModel {
    private(set) var trace: ResourceState<ActivityTrace> = .idle

    @discardableResult
    func load(correlationID: String, session: SessionStore) async -> Bool {
        if let missing = session.missing(AuditStore.readRequirement), !missing.isEmpty {
            trace = .denied(scope: missing.joined(separator: " and "))
            return true
        }
        guard let client = session.client else { return false }
        let before = trace
        trace = before.reloading
        do {
            let answer = try await client.auditTrace(correlationID: correlationID)
            trace = .loaded(ActivityTrace(events: answer.events, truncated: answer.truncated), at: Date())
            return true
        } catch {
            if TasksStore.isCancellation(error) { trace = before; return true }
            let apiError = LatticeAPIError(error)
            if case .invalidResponse = apiError { session.markCompanionBehind("Trace") }
            trace = trace.failing(apiError, surface: "Trace", missingScope: "audit:read")
            return false
        }
    }
}
