import SwiftUI

/// M3-12 Start maintenance. A node is held from now for a preset span or
/// until a chosen time; Start is T2 and names the node and the end.
struct MaintenanceStartSheet: View {
    let nodeID: String?

    @Environment(NodeDirectory.self) private var nodes
    @Environment(MonitoringStore.self) private var store
    @Environment(ActionRunner.self) private var runner
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var subject = ""
    @State private var name = ""
    @State private var nameEdited = false
    @State private var preset = MonitoringMaintenance.Preset.oneHour
    @State private var until = Date().addingTimeInterval(2 * 3_600)
    @State private var note = ""
    @State private var starting = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Node", selection: $subject) {
                        if subject.isEmpty { Text("Choose a node").tag("") }
                        ForEach(nodeOptions, id: \.id) { node in
                            Text(node.displayName).tag(node.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .frame(minHeight: Spacing.minimumTarget)
                } header: {
                    Text("Hold incidents for").accessibilityAddTraits(.isHeader)
                } footer: {
                    Text("Groups and future windows are scheduled on web.")
                }
                Section {
                    TextField("Name", text: $name, axis: .vertical)
                        .focused($nameFocused)
                        .onChange(of: name) { _, value in
                            if nameFocused { nameEdited = true }
                            if value.utf8.count > MonitoringMaintenance.nameLimit {
                                name = value.clippedUTF8(MonitoringMaintenance.nameLimit)
                            }
                        }
                } header: {
                    Text("Name").accessibilityAddTraits(.isHeader)
                } footer: {
                    // The server limits the name in bytes; a non-Latin letter takes two or three.
                    Text("\(name.utf8.count) of \(MonitoringMaintenance.nameLimit) bytes")
                }
                Section {
                    Picker("Duration", selection: $preset) {
                        ForEach(MonitoringMaintenance.Preset.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(minHeight: Spacing.minimumTarget)
                    if preset == .until {
                        DatePicker("Until", selection: $until, in: Date()...Date().addingTimeInterval(MonitoringMaintenance.maxSpan))
                    }
                    LabeledContent("Ends", value: TimeDisplay.dateTime(endsAt, mode: mode, locale: locale))
                } header: {
                    Text("Starts now").accessibilityAddTraits(.isHeader)
                }
                Section {
                    TextField("Optional note", text: $note, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("Note").accessibilityAddTraits(.isHeader)
                }
                Section {
                    WebLinkRow(title: "Schedule on web", path: .maintenance)
                }
            }
            .navigationTitle("Start maintenance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { startBar }
            .actionHost(inSheet: true)
        }
        .presentationDetents([.large])
        .onAppear(perform: prefill)
        .onChange(of: subject) { prefillName() }
        .task { await nodes.refreshIfOlder(than: 60) }
        .onChange(of: nodes.loadedAt) { prefill() }
    }

    private var nodeOptions: [LatticeNode] {
        nodes.nodes.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var subjectName: String { subject.isEmpty ? "" : nodes.name(for: subject) }

    private var startsAt: Date { Date() }

    private var endsAt: Date {
        preset.end(from: startsAt) ?? until
    }

    private var problem: String? {
        MonitoringMaintenance.problem(name: name, reason: note, hasSubject: !subject.isEmpty, startsAt: startsAt, endsAt: endsAt, now: Date().addingTimeInterval(-1))
    }

    private var startBar: some View {
        let missing = store.missing(ScopeRequirement(MonitoringStore.adminScope))
        return VStack(spacing: Spacing.s) {
            if let problem {
                Text(problem).textRole(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            } else if !missing.isEmpty {
                Text("Needs \(missing.joined(separator: ", "))").textRole(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                start()
            } label: {
                Text(subject.isEmpty || typeSize.isAccessibilitySize ? "Start" : "Start maintenance on \(subjectName)")
                    .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget)
            }
            .accessibilityLabel(subject.isEmpty ? "Start maintenance" : "Start maintenance on \(subjectName)")
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .tint(Color.accentFill)
            .disabled(problem != nil || !missing.isEmpty || starting)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func prefill() {
        if subject.isEmpty, let nodeID, !nodeID.isEmpty { subject = nodeID }
        prefillName()
    }

    private func prefillName() {
        guard !nameEdited else { return }
        name = MonitoringMaintenance.defaultName(subject: subjectName, time: TimeDisplay.clock(Date(), mode: mode, locale: locale))
    }

    private func start() {
        let end = endsAt
        let until = TimeDisplay.dateTime(end, mode: mode, locale: locale)
        let input = MonitoringMaintenance.input(name: name, reason: note, nodeIDs: [subject], startsAt: Date(), endsAt: end)
        starting = true
        Task {
            let outcome = await runner.run(MonitoringIntents.startMaintenance(input, subject: subjectName, until: until))
            starting = false
            if case .done = outcome { dismiss() }
        }
    }
}

extension String {
    /// The longest prefix that fits in `limit` UTF-8 bytes.
    fileprivate func clippedUTF8(_ limit: Int) -> String {
        var result = ""
        for character in self {
            if result.utf8.count + String(character).utf8.count > limit { break }
            result.append(character)
        }
        return result
    }
}
