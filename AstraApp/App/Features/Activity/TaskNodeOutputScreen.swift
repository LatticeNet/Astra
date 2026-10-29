import SwiftUI
import UIKit

/// M4-03 Output. One node's full output in a read-only, find-enabled text
/// view: the exit code and timing first, then stdout and stderr in the code
/// style. Everything scrolls together, so the header never crowds the output
/// at large text sizes.
struct TaskNodeOutputScreen: View {
    let taskID: String
    let nodeID: String

    @Environment(TasksStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(ChangeLog.self) private var changes
    @Environment(NodeDirectory.self) private var nodes
    @Environment(Router.self) private var router

    @State private var model = ActivityNodeOutputModel()
    @State private var text = ActivityTextController()

    var body: some View {
        ActivityResource(state: model.output, noun: "the output", retry: reload) { output in
            content(output)
        }
        .navigationTitle(nodes.name(for: nodeID))
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(taskID)
        .toolbar { toolbar }
        .polling(model.isLive ? .live : .standard, version: changes.version([.tasks])) {
            await nodes.refreshIfOlder(than: 60)
            return await model.load(taskID: taskID, nodeID: nodeID, hint: store.task(id: taskID), session: session)
        }
    }

    private func reload() {
        Task { await model.load(taskID: taskID, nodeID: nodeID, hint: store.task(id: taskID), session: session) }
    }

    @ViewBuilder
    private func content(_ output: ActivityNodeOutput) -> some View {
        if let row = output.result {
            ActivityOutputText(document: ActivityOutputDocument(row: row, state: output.state, task: output.task), controller: text)
                .ignoresSafeArea(.container, edges: .bottom)
        } else {
            let style = StatusStyle.task(output.state)
            WholeScreenState {
                ContentUnavailableView {
                    Label("No result from \(nodes.name(for: nodeID)) yet", systemImage: style.symbol)
                } description: {
                    Text(noResultSentence(output))
                } actions: {
                    Button("Open the run") { router.push(.activity(.task(id: taskID))) }
                }
            }
        }
    }

    private func noResultSentence(_ output: ActivityNodeOutput) -> String {
        switch output.state {
        case .expired: "Expired: the node never picked it up."
        case .cancelled: "Cancelled before any agent ran it."
        case .stalled: TasksModel.stalledText(output.task?.leaseProgress(nodeID: nodeID)) + "."
        case .leased: "The node is running it. Output arrives when it finishes."
        default: "The node has not reported for this run."
        }
    }

    /// Find, Jump to end, and Copy and Share in a menu, in the navigation bar:
    /// a bottom bar on a pushed screen sits behind the floating tab bar.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let row = model.output.value?.result {
            ToolbarItemGroup(placement: .topBarTrailing) { actions(ActivityOutputDocument.plainText(row)) }
        }
    }

    @ViewBuilder
    private func actions(_ all: String) -> some View {
        Button("Find", systemImage: "magnifyingglass") { text.find() }
        Button("Jump to end", systemImage: "arrow.down.to.line") { text.jumpToEnd() }
        Menu {
            Button("Copy output", systemImage: "doc.on.doc") { UIPasteboard.general.string = all }
                .disabled(all.isEmpty)
            ShareLink(item: all, subject: Text("Output of \(taskID) on \(nodes.name(for: nodeID))")) {
                Label("Share output", systemImage: "square.and.arrow.up")
            }
            .disabled(all.isEmpty)
            Divider()
            Button("Open the run", systemImage: "terminal") { router.push(.activity(.task(id: taskID))) }
            Button("Open node", systemImage: "server.rack") { router.push(.fleet(.node(id: nodeID))) }
            Button("Open on web", systemImage: "safari") { router.openOnWeb(.taskNode(taskID: taskID, nodeID: nodeID)) }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }
}

/// What the output screen shows: the node's newest result, its state in the
/// run, and the run when it was read.
struct ActivityNodeOutput: Sendable {
    var result: TasksResultRow?
    var state: TaskRunState
    var task: LatticeTask?
}

@MainActor @Observable
final class ActivityNodeOutputModel {
    private(set) var output: ResourceState<ActivityNodeOutput> = .idle

    var isLive: Bool {
        guard let value = output.value else { return false }
        return value.result == nil && !value.state.isSettled
    }

    @discardableResult
    func load(taskID: String, nodeID: String, hint: LatticeTask?, session: SessionStore) async -> Bool {
        if let missing = session.missing(TasksStore.readRequirement), !missing.isEmpty {
            output = .denied(scope: missing.joined(separator: " and "))
            return true
        }
        guard let client = session.client else { return false }
        let before = output
        output = before.reloading
        do {
            async let page = client.tasksResults(TasksResultsQuery(taskIDs: [taskID], nodeID: nodeID, omitOutput: false, limit: 50))
            let task = try await client.tasksFind(id: taskID, hint: before.value?.task ?? hint)
            let rows = try await page.results.filter { $0.result.nodeID == nodeID }
            let latest = TasksModel.latestByNode(rows)[nodeID]
            let state = task.map { TasksModel.nodeRow(task: $0, nodeID: nodeID, result: latest, now: Date()).state }
                ?? latest.map { TasksModel.resultFailed($0.result) ? .failed : .finished } ?? .queued
            output = .loaded(ActivityNodeOutput(result: latest, state: state, task: task), at: Date())
            return true
        } catch {
            if TasksStore.isCancellation(error) { output = before; return true }
            let apiError = LatticeAPIError(error)
            if case .invalidResponse = apiError { session.markCompanionBehind("Task output") }
            output = output.failing(apiError, surface: "Task output", missingScope: TasksIntents.readScope)
            return false
        }
    }
}

/// The text the output view holds, built from one result.
struct ActivityOutputDocument: Equatable {
    let row: TasksResultRow
    let state: TaskRunState
    let task: LatticeTask?

    static func plainText(_ row: TasksResultRow) -> String {
        var parts: [String] = []
        if !row.result.stdout.isEmpty { parts.append(row.result.stdout) }
        if !row.result.stderr.isEmpty { parts.append(row.result.stderr) }
        return parts.joined(separator: parts.count == 2 && !row.result.stdout.hasSuffix("\n") ? "\n" : "")
    }

    var isEmpty: Bool { row.result.stdout.isEmpty && row.result.stderr.isEmpty }

    /// How the agent ran it, from the pinned posture; nil when unknown.
    var posture: String? {
        guard let context = row.execContext else { return nil }
        if context.execDisabled { return "This agent refuses task execution, so nothing in this run reached the host." }
        if context.nonRoot { return "Ran as a non-root user: anything that needs root read nothing here." }
        if context.rootExec { return "Ran as root." }
        return nil
    }
}

/// Holds the text view so the toolbar can find and jump.
@MainActor @Observable
final class ActivityTextController {
    @ObservationIgnored weak var view: UITextView?

    func find() {
        guard let view else { return }
        view.becomeFirstResponder()
        view.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    func jumpToEnd() {
        guard let view, view.textStorage.length > 0 else { return }
        view.scrollRangeToVisible(NSRange(location: view.textStorage.length - 1, length: 1))
        UIAccessibility.post(notification: .announcement, argument: "Jumped to the end of the output")
    }
}

/// A read-only, selectable, find-enabled text view (section 4.3 `code`).
struct ActivityOutputText: UIViewRepresentable {
    let document: ActivityOutputDocument
    let controller: ActivityTextController

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isFindInteractionEnabled = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .systemGroupedBackground
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 32, right: 12)
        view.dataDetectorTypes = []
        view.accessibilityIdentifier = "activity.output"
        controller.view = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        controller.view = view
        let key = Key(document: document, typeSize: typeSize, mode: mode, dark: colorScheme == .dark, contrast: contrast == .increased)
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        view.attributedText = attributed(traits: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize)))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var key: Key?
    }

    struct Key: Equatable {
        let document: ActivityOutputDocument
        let typeSize: DynamicTypeSize
        let mode: TimeZoneMode
        let dark: Bool
        let contrast: Bool
    }

    private func attributed(traits: UITraitCollection) -> NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        let headline = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits)
        let footnote = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        let code = UIFontMetrics(forTextStyle: .callout).scaledFont(for: .monospacedSystemFont(ofSize: 16, weight: .regular), compatibleWith: traits)
        let secondary = UIColor.secondaryLabel
        let style = StatusStyle.task(document.state)
        let tone = UIColor(style.tone.glyph)
        let word = style.tone.isProblem ? UIColor(style.tone.word) : UIColor.label
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 6
        let out = NSMutableAttributedString()
        func add(_ text: String, _ font: UIFont, _ color: UIColor = .label) {
            out.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]))
        }

        // The state as symbol, word and color (section 4.2), then the exit code.
        let symbol = UIImage(systemName: style.symbol, withConfiguration: UIImage.SymbolConfiguration(font: headline))?
            .withTintColor(tone, renderingMode: .alwaysOriginal)
        if let symbol {
            out.append(NSAttributedString(attachment: NSTextAttachment(image: symbol)))
            add(" ", headline)
        }
        add(style.word.activityCapitalized, headline, word)
        add(", exit code \(document.row.result.exitCode)\n", headline, word)
        var timing: [String] = []
        if let start = document.row.result.startedAt { timing.append("Started \(TimeDisplay.dateTime(start, mode: mode, locale: locale))") }
        if let start = document.row.result.startedAt, let end = document.row.result.finishedAt, end >= start {
            let seconds = end.timeIntervalSince(start)
            timing.append("took \(seconds < 1 ? "under a second" : TaskLeaseProgress.formatLeaseAge(seconds))")
        }
        if !timing.isEmpty { add(timing.joined(separator: ", ") + "\n", footnote, secondary) }
        if !document.row.result.error.isEmpty { add("Agent error: \(document.row.result.error)\n", footnote, UIColor(Color.statusFailText)) }
        if let posture = document.posture { add(posture + "\n", footnote, secondary) }

        if document.isEmpty {
            add("\nNo output captured.\n", body, secondary)
            return out
        }
        if !document.row.result.stdout.isEmpty {
            add("\nstdout\n", footnote, secondary)
            add(document.row.result.stdout.hasSuffix("\n") ? document.row.result.stdout : document.row.result.stdout + "\n", code)
        }
        if !document.row.result.stderr.isEmpty {
            add("\nstderr\n", footnote, secondary)
            add(document.row.result.stderr, code)
        }
        return out
    }
}
