import SwiftUI

/// Remote task runs dispatched to the fleet and their per-node results. Read-only
/// on iOS — tasks are created from the web dashboard or CLI — but this surfaces
/// their lifecycle status and the exit outcome of each node that executed them.
///
/// Pushed inside MoreHub's NavigationStack, so it does not wrap itself in one.
struct TasksView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        List {
            tasksSection
            resultsSection
            statusSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Tasks")
        .task {
            if model.configured {
                await model.loadTasks()
            }
        }
        .refreshable {
            await model.loadTasks()
        }
    }

    // MARK: - Tasks

    @ViewBuilder
    private var tasksSection: some View {
        Section {
            if model.tasks.isEmpty {
                if !model.isLoading("tasks") {
                    AstraEmptyStateView(
                        title: "No tasks",
                        systemImage: "terminal",
                        message: "Dispatch a remote task from the web dashboard to see its progress here."
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(model.tasks) { task in
                    TaskRow(task: task)
                }
            }
        } header: {
            SectionHeaderView(
                "Tasks",
                systemImage: "terminal.fill",
                accessory: model.tasks.isEmpty ? nil : "\(model.tasks.count)"
            )
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        Section {
            if model.taskResults.isEmpty {
                if !model.isLoading("tasks") {
                    Text("No results yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.taskResults) { result in
                    TaskResultRow(result: result)
                }
            }
        } header: {
            SectionHeaderView(
                "Recent results",
                systemImage: "checklist",
                accessory: model.taskResults.isEmpty ? nil : "\(model.taskResults.count)"
            )
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        Section {
            InlineStatusView(isLoading: model.isLoading("tasks"), error: model.error(for: "tasks"))
        }
        .listRowBackground(Color.clear)
    }
}

// MARK: - Task row

struct TaskRow: View {
    var task: LatticeTask

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatusPill(
                    text: statusText,
                    systemImage: statusIcon,
                    color: statusColor
                )
                Spacer(minLength: 8)
                if let created = task.createdAt {
                    Text(RelativeDateFormatter.string(from: created))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Text(targetSummary)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Label(scriptSummary, systemImage: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        task.status.isEmpty ? "unknown" : task.status
    }

    private var statusIcon: String {
        switch task.status.lowercased() {
        case "finished": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "queued": "clock"
        case "leased": "arrow.triangle.2.circlepath"
        default: "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch task.status.lowercased() {
        case "finished": Theme.online
        case "failed": Theme.critical
        case "queued", "leased": Theme.warning
        default: Theme.secondary
        }
    }

    private var targetSummary: String {
        let interpreter = task.interpreter.isEmpty ? "script" : task.interpreter
        let count = task.targets.count
        return "\(interpreter) · \(count) target\(count == 1 ? "" : "s")"
    }

    private var scriptSummary: String {
        let bytes = ByteFormatter.bytes(UInt64(max(0, task.scriptSizeBytes)))
        return "script \(bytes)"
    }
}

// MARK: - Task result row

struct TaskResultRow: View {
    var result: LatticeTaskResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Label(result.nodeID.isEmpty ? "—" : result.nodeID, systemImage: "cpu")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                StatusPill(text: exitText, systemImage: exitIcon, color: exitColor)
            }

            if let finished = result.finishedAt {
                Text("finished \(RelativeDateFormatter.string(from: finished))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !result.error.isEmpty {
                Label(result.error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.critical)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var isClean: Bool { result.exitCode == 0 }

    private var exitText: String { "exit \(result.exitCode)" }

    private var exitIcon: String {
        isClean ? "checkmark.circle.fill" : "xmark.octagon.fill"
    }

    private var exitColor: Color {
        isClean ? Theme.online : Theme.critical
    }
}
