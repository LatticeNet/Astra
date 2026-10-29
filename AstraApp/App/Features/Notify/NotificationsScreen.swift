import SwiftUI

/// M9-01 Notifications. Routing (what needs attention, channels with health
/// and fallback, rules with their events and quiet hours, the control-plane
/// witness with Plan witness) and Sent (M9-02). Channel and rule authoring,
/// and the notify:send test, are on the web.
struct NotificationsScreen: View {
    var view: String?

    enum Segment: String, CaseIterable, Hashable {
        case routing, sent

        var title: String { self == .routing ? "Routing" : "Sent" }
    }

    @Environment(NotifyStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    @State private var segment: Segment
    @State private var width: CGFloat?
    @State private var witnessSheet: WitnessTarget?

    struct WitnessTarget: Identifiable {
        let nodeID: String?
        var id: String { nodeID ?? "new" }
    }

    init(view: String? = nil) {
        self.view = view
        _segment = State(initialValue: view == Segment.sent.rawValue ? .sent : .routing)
    }

    var body: some View {
        let picker = AdaptiveSegmentedPicker(title: "Notification views", options: Segment.allCases.map { ($0, $0.title) }, selection: $segment, containerWidth: width)
        Group {
            switch segment {
            case .routing: routing
            case .sent: SentLogScreen()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaBar(edge: .top) {
            if verticalSizeClass != .compact {
                picker.padding(.horizontal, Spacing.l).padding(.bottom, Spacing.s)
            }
        }
        .toolbar {
            if verticalSizeClass == .compact {
                ToolbarItem(placement: .principal) { picker.frame(maxWidth: 420) }
            }
            if segment == .routing {
                ToolbarItem(placement: .topBarTrailing) { moreMenu }
            }
        }
        .sheet(item: $witnessSheet) { target in
            NotifyWitnessPlanSheet(nodeID: target.nodeID)
        }
    }

    // MARK: Routing

    private var routing: some View {
        NotifyResourceScreen(state: store.channels, noun: "notification channels", retry: refresh) { channels in
            routingList(channels)
        }
        .polling(.standard, version: changes.version([.notify, .approvals])) {
            await store.refreshRouting()
        }
    }

    private func routingList(_ channels: [NotifyChannel]) -> some View {
        List {
            NotifyRefreshError(state: store.channels, noun: "channels", retry: refresh)
            attentionSection(channels)
            channelsSection(channels)
            rulesSection(channels)
            witnessSection
            Section {} footer: {
                NotifyFreshness(state: store.channels)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refreshRouting() }
    }

    @ViewBuilder
    private func attentionSection(_ channels: [NotifyChannel]) -> some View {
        let failing = NotifyChannels.failing(channels)
        let witness = store.witness.value.map { NotifyWitness.attention($0.nodes) } ?? []
        if !failing.isEmpty || !witness.isEmpty {
            Section {
                ForEach(failing) { channel in
                    NavigationLink(value: AppRoute.notify(.channel(id: channel.id))) {
                        let line = NotifyChannelHealthLine.of(channel.health)
                        StatusRow(
                            style: .notifyChannel(channel),
                            title: "\(channel.displayName) is failing, so alerts routed only to it are not arriving.",
                            detail: line.at.map { "Since \(NotifyTime.when($0, mode: mode, locale: locale)), \(line.failures) in a row" },
                            reason: line.cause.map { "Last failure: \($0.sentence)." },
                            accessibilityPhrase: "\(channel.displayName), failing"
                        )
                    }
                }
                ForEach(Array(witness.enumerated()), id: \.offset) { _, item in
                    StatusRow(
                        style: item.isFailure ? StatusStyle(word: item.word, symbol: "xmark.octagon.fill", tone: .fail)
                            : StatusStyle(word: item.word, symbol: "exclamationmark.triangle.fill", tone: .warn),
                        title: item.claim,
                        detail: item.line.sentence(mode: mode, locale: locale, now: Date()),
                        accessibilityPhrase: item.claim
                    )
                }
            } header: {
                Text("Needs attention").accessibilityAddTraits(.isHeader)
            }
        }
    }

    @ViewBuilder
    private func channelsSection(_ channels: [NotifyChannel]) -> some View {
        Section {
            if channels.isEmpty {
                ContentUnavailableView {
                    Label("No channels", systemImage: "bell.slash")
                } description: {
                    Text("Nothing can deliver an alert. Add a Telegram, Bark, Discord or webhook channel on the web.")
                }
            }
            ForEach(channels.sorted(by: channelOrder)) { channel in
                NavigationLink(value: AppRoute.notify(.channel(id: channel.id))) {
                    NotifyChannelRow(channel: channel, fallback: store.channel(id: channel.fallbackChannelID))
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if store.adminMissing == nil {
                        Button("Send test", systemImage: "paperplane") {
                            Task { await runner.run(NotifyIntents.testChannel(channel)) }
                        }
                        .tint(Color.accentFill)
                    }
                }
                .contextMenu {
                    NotifyObjectMenu(route: .notify(.channel(id: channel.id)), link: .notifyChannel(id: channel.id), web: .notifyChannel(id: channel.id), objectID: channel.id)
                    Divider()
                    NotifyGatedButton(title: "Send test", systemImage: "paperplane", missing: store.adminMissing) {
                        Task { await runner.run(NotifyIntents.testChannel(channel)) }
                    }
                    NotifyGatedButton(title: "Delete channel", systemImage: "trash", missing: store.adminMissing, role: .destructive) {
                        Task { await runner.run(NotifyIntents.deleteChannel(channel, rules: store.rules.value, channels: channels)) }
                    }
                }
                .accessibilityActions {
                    Button("Copy link") { NotifyCopy.copy(NotifyCopy.link(.notifyChannel(id: channel.id))) }
                    if store.adminMissing == nil {
                        Button("Delete channel") {
                            Task { await runner.run(NotifyIntents.deleteChannel(channel, rules: store.rules.value, channels: channels)) }
                        }
                    }
                }
            }
        } header: {
            Text(channels.count == 1 ? "1 channel" : "\(channels.count) channels").accessibilityAddTraits(.isHeader)
        } footer: {
            Text("Keys and tokens are write-only: the server never returns them, so channels are created and edited on the web.")
        }
    }

    /// Problems first, then by name.
    private func channelOrder(_ a: NotifyChannel, _ b: NotifyChannel) -> Bool {
        func rank(_ c: NotifyChannel) -> Int {
            guard c.enabled else { return 4 }
            switch NotifyChannelHealthLine.of(c.health).state {
            case .failing: return 0
            case .degraded: return 1
            default: return 2
            }
        }
        let (ra, rb) = (rank(a), rank(b))
        return ra != rb ? ra < rb : a.displayName.localizedCompare(b.displayName) == .orderedAscending
    }

    @ViewBuilder
    private func rulesSection(_ channels: [NotifyChannel]) -> some View {
        Section {
            switch store.rules {
            case .denied(let scope):
                ScopeDeniedRow(scope: scope)
            case .companionBehind(let surface):
                CompanionBehindRow(surface: surface)
            case .failed(let error, nil, _):
                ErrorRow(message: "Could not load rules: \(error.localizedDescription)", retry: refresh)
            default:
                if let rules = store.rules.value {
                    NotifyRefreshError(state: store.rules, noun: "rules", retry: refresh)
                    if rules.isEmpty {
                        Text("No rules. Every enabled channel receives every event until a rule exists.")
                            .foregroundStyle(.secondary)
                            .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                    }
                    ForEach(rules.sorted { ($0.enabled ? 0 : 1, $0.displayName) < ($1.enabled ? 0 : 1, $1.displayName) }) { rule in
                        NavigationLink(value: AppRoute.notify(.rule(id: rule.id))) {
                            NotifyRuleRow(rule: rule, channels: channels)
                        }
                        .contextMenu {
                            Button("Open", systemImage: "arrow.up.right.square") { router.push(.notify(.rule(id: rule.id))) }
                            Button("Copy ID", systemImage: "number") { NotifyCopy.copy(rule.id) }
                            Button("Edit on web", systemImage: "safari") { router.openOnWeb(.notifyNotifications(view: "routing")) }
                        }
                    }
                } else {
                    LoadingRows(label: "Loading rules", count: 2)
                }
            }
        } header: {
            Text(store.rules.value.map { $0.count == 1 ? "1 rule" : "\($0.count) rules" } ?? "Rules").accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: Witness

    @ViewBuilder
    private var witnessSection: some View {
        Section {
            switch store.witness {
            case .denied(let scope):
                ScopeDeniedRow(scope: scope)
            case .companionBehind(let surface):
                CompanionBehindRow(surface: surface)
            case .failed(let error, nil, _):
                ErrorRow(message: "The witness status was not read: \(error.localizedDescription)", retry: refresh)
            default:
                if let status = store.witness.value {
                    NotifyRefreshError(state: store.witness, noun: "the witness", retry: refresh)
                    let shown = NotifyWitness.shownNodes(status)
                    if shown.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Nothing outside watches the control plane").font(.headline)
                            Text("If this server stops, no notification can say so. A witness on the node that runs Bark can push from there.")
                                .textRole(.rowDetail)
                        }
                        .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                    ForEach(shown) { node in
                        witnessRow(node, status: status)
                    }
                    let missing = store.witnessMissing
                    Button {
                        witnessSheet = WitnessTarget(nodeID: nil)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(shown.isEmpty ? "Set up the control-plane witness" : "Plan witness")
                                Text(missing.map { "Needs \($0)" } ?? "Files a plan; nothing changes until it is approved.")
                                    .textRole(.footnote)
                            }
                        } icon: {
                            Image(systemName: "binoculars")
                        }
                        .frame(minHeight: Spacing.minimumTarget)
                    }
                    .disabled(missing != nil)
                } else {
                    LoadingRows(label: "Loading the witness", count: 1)
                }
            }
        } header: {
            Text("Control-plane witness").accessibilityAddTraits(.isHeader)
        } footer: {
            if let status = store.witness.value {
                Text(status.healthURL.isEmpty
                     ? "This server has no public URL, so a witness watches only a URL set in its plan."
                     : "One node watches \(status.healthURL) from outside and pushes through its own Bark server when it stops answering.")
            }
        }
    }

    private func witnessRow(_ node: NotifyWitnessNode, status: NotifyWitnessStatus) -> some View {
        let line = NotifyWitnessLine.of(node)
        let style = StatusStyle.notifyWitness(line)
        let sentence = line.sentence(mode: mode, locale: locale, now: Date())
        var facts: [String] = []
        if let configured = node.configured {
            facts.append("Pushes to \(configured.channelName.isEmpty ? configured.channelID : configured.channelName)")
        }
        if let pending = node.pending {
            facts.append(pending.action == "remove" ? "Removal waiting for approval" : (pending.status == "approved" ? "Approved, task running" : "Plan waiting for approval"))
        }
        if let failed = node.lastFailed {
            facts.append("Last plan failed: \(failed.reason)")
        }
        if NotifyWitness.configState(node) == .differs {
            facts.append("Runs a different config than the last applied plan")
        }
        let problem = line.tone != .quiet
        return StatusRow(
            style: style,
            title: node.nodeName,
            detail: (facts.map { $0 + "." } + (problem ? [] : [sentence])).joined(separator: " "),
            reason: problem ? sentence : nil,
            accessibilityPhrase: "Witness on \(node.nodeName), \(style.word)"
        )
        .contextMenu {
            if let approval = node.pending ?? node.lastFailed {
                Button("Review plan", systemImage: "checkmark.seal") { router.present(.review(.single(approval.approvalID))) }
            }
            NotifyGatedButton(title: "Change settings", systemImage: "slider.horizontal.3", missing: store.witnessMissing) {
                witnessSheet = WitnessTarget(nodeID: node.nodeID)
            }
            if node.configured != nil {
                NotifyGatedButton(title: "Remove the witness", systemImage: "trash", missing: store.witnessMissing, role: .destructive) {
                    Task { await runner.run(NotifyIntents.removeWitness(node: ObjectRef(kind: "node", id: node.nodeID, name: node.nodeName))) }
                }
            }
            Button("Open node", systemImage: "server.rack") { router.push(.fleet(.node(id: node.nodeID))) }
        }
        .accessibilityActions {
            if let approval = node.pending ?? node.lastFailed {
                Button("Review plan") { router.present(.review(.single(approval.approvalID))) }
            }
            if store.witnessMissing == nil {
                Button("Change settings") { witnessSheet = WitnessTarget(nodeID: node.nodeID) }
                if node.configured != nil {
                    Button("Remove the witness") {
                        Task { await runner.run(NotifyIntents.removeWitness(node: ObjectRef(kind: "node", id: node.nodeID, name: node.nodeName))) }
                    }
                }
            }
        }
    }

    // MARK: Toolbar

    private var moreMenu: some View {
        Menu {
            Button("Open on web", systemImage: "safari") { router.openOnWeb(.notifyNotifications(view: "routing")) }
            Button("New channel on web", systemImage: "plus.circle") { router.openOnWeb(.notifyNotifications(view: "routing")) }
            Button("New rule on web", systemImage: "arrow.triangle.branch") { router.openOnWeb(.notifyNotifications(view: "routing")) }
            Button("Test send on web (needs notify:send)", systemImage: "paperplane") { router.openOnWeb(.notifyNotifications(view: "routing")) }
            Button("Webhooks", systemImage: "arrow.down.forward.and.arrow.up.backward") { router.push(.notify(.webhooks)) }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    private func refresh() {
        Task { await store.refreshRouting() }
    }
}

/// A channel: health word, kind, fallback, and why it failed.
struct NotifyChannelRow: View {
    let channel: NotifyChannel
    let fallback: NotifyChannel?

    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale

    var body: some View {
        let style = StatusStyle.notifyChannel(channel)
        let line = NotifyChannelHealthLine.of(channel.health)
        var detail = NotifyKind.label(channel.kind)
        if !channel.fallbackChannelID.isEmpty {
            detail += ", falls back to \(fallback?.displayName ?? channel.fallbackChannelID)"
        }
        let reason: String? = switch line.state {
        case .failing, .degraded:
            channel.enabled ? line.cause.map { "Last failure: \($0.sentence)." } : nil
        default: nil
        }
        return StatusRow(
            style: style,
            title: channel.displayName,
            detail: detail,
            reason: reason,
            trailing: line.at.map { RelativeDateFormatter.shortDuration(Date().timeIntervalSince($0)) },
            accessibilityPhrase: "\(channel.displayName), \(NotifyKind.label(channel.kind)), \(style.word)"
        )
    }
}

/// A rule: on or off, its events and channels, quiet hours.
struct NotifyRuleRow: View {
    let rule: NotifyRule
    let channels: [NotifyChannel]

    var body: some View {
        let style = StatusStyle.notifyRule(rule, channels: channels)
        let events = NotifyRules.matchesEverything(rule) ? "Every event" : (rule.eventTypes.count == 1 ? rule.eventTypes[0] : "\(rule.eventTypes.count) event types")
        let names = rule.channelIDs.map { id in channels.first { $0.id == id }?.displayName ?? id }
        let to = names.isEmpty ? "no channel" : names.joined(separator: ", ")
        var detail = "\(events) to \(to)"
        if let quiet = NotifyRules.quietHoursText(rule) { detail += ". Quiet \(quiet)" }
        return StatusRow(style: style, title: rule.displayName, detail: detail, accessibilityPhrase: "Rule \(rule.displayName), \(style.word)")
    }
}
