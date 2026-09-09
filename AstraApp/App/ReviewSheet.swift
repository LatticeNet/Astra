import SwiftUI

/// Hash-bound review of one approval. Loads by id so the plan body is the
/// bytes that are hashed. Face ID (or device passcode) gates approve and reject.
struct ApprovalReviewView: View {
    @EnvironmentObject private var model: DashboardModel
    @Environment(\.dismiss) private var dismiss

    var approvalID: String

    @State private var loaded: Approval?
    @State private var loadError: String?
    @State private var hashError: String?
    @State private var companionBehind = false
    @State private var queueApply = true
    @State private var dismissNote = "No longer needed"
    @State private var working = false
    @State private var outcome: String?
    @State private var outcomeWaiting: ApprovalWaiting?

    var body: some View {
        List {
            if companionBehind {
                Section {
                    Label("Companion is behind this server. The approval view could not be decoded, so approve is disabled.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                }
            } else if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                    Button("Reload") { Task { await reload() } }
                }
            } else if let approval = loaded {
                headerSection(approval)
                if approval.isSSHGuardConfirm {
                    Section {
                        Text("This is the SSH Guard confirm plan, a second decision after arm. It is not a duplicate of the arm row.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                proofSection(approval)
                planSection(approval)
                if let hashError {
                    Section {
                        Label(hashError, systemImage: "xmark.seal.fill")
                            .foregroundStyle(Theme.offline)
                        Button("Reload") { Task { await reload() } }
                    }
                }
                if let waiting = approval.waiting ?? outcomeWaiting {
                    waitingSection(waiting)
                }
                if let outcome {
                    Section {
                        Text(outcome)
                            .font(.subheadline)
                    } header: {
                        Text("Result")
                    }
                }
                actionsSection(approval)
            } else {
                Section {
                    InlineStatusView(isLoading: true, error: nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .task { await reload() }
    }

    private func headerSection(_ approval: Approval) -> some View {
        Section {
            DetailRow(label: "Plugin", value: approval.plugin)
            DetailRow(label: "Action", value: approval.action.isEmpty ? approval.plugin : approval.action)
            DetailRow(label: "Node", value: approval.nodeID, monospaced: true, copyable: true)
            if !approval.targets.isEmpty {
                DetailRow(label: "Targets", value: approval.targets.joined(separator: ", "), monospaced: true)
            }
            if !approval.actorID.isEmpty {
                DetailRow(label: "Actor", value: approval.actorID)
            }
            if !approval.pluginVersion.isEmpty {
                DetailRow(label: "Plugin version", value: approval.pluginVersion, monospaced: true)
            }
            if !approval.artifactDigest.isEmpty {
                DetailRow(label: "Artifact", value: approval.artifactDigest, monospaced: true, copyable: true)
            }
            StatusPill(
                text: approval.isStale ? "stale" : approval.status,
                systemImage: approval.isStale ? "exclamationmark.triangle.fill" : "clock.fill",
                color: approval.isStale ? Theme.warning : Theme.accent
            )
            if !approval.reason.isEmpty {
                Text(approval.reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Plan")
        }
    }

    private func proofSection(_ approval: Approval) -> some View {
        Section {
            Text(approval.proofLine)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(Theme.accent)
                .textSelection(.enabled)
            DetailRow(label: "plan_sha256", value: approval.planSHA256, monospaced: true, copyable: true)
        } header: {
            Text("Proof")
        } footer: {
            Text("Approve sends this hash. If the plan changed since review, the server rejects it.")
        }
    }

    private func planSection(_ approval: Approval) -> some View {
        Section {
            Text(approval.plan.isEmpty ? "(no plan body)" : approval.plan)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            Text("Reviewed text")
        }
    }

    private func waitingSection(_ waiting: ApprovalWaiting) -> some View {
        Section {
            DetailRow(label: "Code", value: waiting.code, monospaced: true)
            Text(waiting.reason)
                .font(.footnote)
            DetailRow(label: "Blocked", value: waiting.blocked ? "yes" : "no")
            if !waiting.nodeStatus.isEmpty {
                DetailRow(label: "Node", value: "\(waiting.nodeName.isEmpty ? waiting.nodeID : waiting.nodeName) · \(waiting.nodeStatus)")
            }
            if !waiting.taskID.isEmpty {
                DetailRow(label: "Task", value: "\(waiting.taskID) · \(waiting.taskStatus)", monospaced: true)
            }
        } header: {
            Text("Waiting")
        }
    }

    @ViewBuilder
    private func actionsSection(_ approval: Approval) -> some View {
        if let url = model.consoleURL(forApproval: approval.id) {
            Section {
                Link(destination: url) {
                    Label("Open on web", systemImage: "safari")
                }
            }
        }

        if approval.isStale || (!approval.isPending && outcome == nil) {
            Section {
                Text(approval.isStale
                     ? "This row is inspect-only. Re-plan on the web console."
                     : "This approval is no longer pending.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let url = model.consoleURL(forApproval: approval.id) {
                    Link("Re-plan on web", destination: url)
                }
            }
        } else if approval.isPending, outcome == nil {
            Section {
                Toggle("Queue apply after approval", isOn: $queueApply)
                Button {
                    Task { await decide(.approve) }
                } label: {
                    label("Approve", systemImage: "checkmark.seal.fill", working: working)
                }
                .disabled(working || companionBehind || hashError != nil || model.companionBehindServer)
                Button(role: .destructive) {
                    Task { await decide(.reject) }
                } label: {
                    label("Reject", systemImage: "xmark.octagon.fill", working: working)
                }
                .disabled(working)
            } footer: {
                Text("Face ID or the device passcode confirms the decision. Cancelling authentication does not send anything.")
            }

            if canDismiss(approval) {
                Section {
                    TextField("Dismiss note", text: $dismissNote)
                    Button("Dismiss") {
                        Task { await decide(.dismiss) }
                    }
                    .disabled(working || dismissNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("Dismiss retires a stale agent-update or SSH Guard row that will never apply.")
                }
            }
        }
    }

    private func canDismiss(_ approval: Approval) -> Bool {
        if let waiting = approval.waiting { return waiting.dismissible }
        return approval.isStale || approval.plugin == "sshguard" || approval.plugin == "agentupdate"
    }

    private func label(_ title: String, systemImage: String, working: Bool) -> some View {
        HStack {
            if working { ProgressView() }
            Label(title, systemImage: systemImage)
        }
        .frame(maxWidth: .infinity)
    }

    private enum Decision { case approve, reject, dismiss }

    private func reload() async {
        loadError = nil
        hashError = nil
        companionBehind = false
        do {
            let approval = try await model.fetchReviewApproval(id: approvalID)
            loaded = approval
            bindHash(approval)
        } catch LatticeAPIError.invalidResponse {
            companionBehind = true
            model.markCompanionBehind()
            loadError = "Companion is behind this server."
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func bindHash(_ approval: Approval) {
        do {
            _ = try approval.reviewedPlanSHA256()
            hashError = nil
        } catch let error as ApprovalReviewError {
            hashError = error.localizedDescription
        } catch {
            hashError = error.localizedDescription
        }
    }

    private func decide(_ decision: Decision) async {
        guard let approval = loaded else { return }
        working = true
        defer { working = false }
        let prompt: String
        switch decision {
        case .approve: prompt = "Approve this Lattice plan."
        case .reject: prompt = "Reject this Lattice plan."
        case .dismiss: prompt = "Dismiss this Lattice approval."
        }
        switch await IntentAuth.confirm(reason: prompt) {
        case .failure(.cancelled):
            return
        case .failure(.failed(let message)):
            loadError = message
            return
        case .success:
            break
        }

        do {
            switch decision {
            case .approve:
                let updated = try await model.approveReviewed(approval, queueApply: queueApply)
                loaded = updated
                let refreshed = try? await model.fetchReviewApproval(id: approval.id)
                if let refreshed {
                    loaded = refreshed
                    outcomeWaiting = refreshed.waiting
                }
                if let waiting = refreshed?.waiting {
                    outcome = waiting.blocked
                        ? "Approved, waiting: \(waiting.reason)"
                        : "Approved, apply in progress: \(waiting.reason)"
                } else {
                    outcome = queueApply ? "Approved and queued." : "Approved without queuing apply."
                }
            case .reject:
                loaded = try await model.rejectApproval(id: approval.id)
                outcome = "Rejected."
            case .dismiss:
                loaded = try await model.dismissApproval(id: approval.id, note: dismissNote)
                outcome = "Dismissed."
            }
            await model.refreshInbox()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
