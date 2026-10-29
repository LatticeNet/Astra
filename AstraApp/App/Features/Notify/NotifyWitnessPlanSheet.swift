import SwiftUI

/// Plan witness (P), presented from Notifications. The phone asks only for
/// what the server cannot default: the node, the Bark channel whose device
/// key the witness pushes with, and the bark-server on that node's loopback
/// address. The watch URL, references, level and timing are the server's
/// defaults; changing them is desk work on the web. Continue pushes the plan
/// confirmation inside this sheet, and the filed approval opens in Review.
struct NotifyWitnessPlanSheet: View {
    /// The node whose settings change, or nil for a new witness.
    let nodeID: String?

    @Environment(NotifyStore.self) private var store
    @Environment(ActionRunner.self) private var runner
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.dismiss) private var dismiss

    @State private var node = ""
    @State private var channel = ""
    @State private var barkURL = ""
    @State private var filing = false
    @State private var prepared = false
    @FocusState private var urlFocused: Bool

    var body: some View {
        NavigationStack {
            NotifyResourceScreen(state: store.witness, noun: "the witness", retry: { Task { await store.refreshRouting() } }) { status in
                form(status)
            }
            .navigationTitle(nodeID == nil ? "Plan witness" : "Change the witness")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .disabled(filing)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let status = store.witness.value { continueBar(status) }
            }
            .actionHost(inSheet: true)
        }
        .presentationDetents([.large])
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        .interactiveDismissDisabled(filing)
        .task {
            if store.witness.value == nil || store.channels.value == nil { await store.refreshRouting() }
            prepare()
        }
        .onChange(of: store.witness.loadedAt) { prepare() }
    }

    private var barkChannels: [NotifyChannel] { NotifyChannels.bark(store.channels.value ?? []) }

    /// The form a setup or change starts from (`witnessFormDefaults`): the
    /// node and channel of the applied plan, or the only choice when there is one.
    private func prepare() {
        guard !prepared, let status = store.witness.value, store.channels.value != nil else { return }
        prepared = true
        let existing = status.nodes.first { $0.nodeID == nodeID }
        node = nodeID ?? (status.capableNodes.count == 1 ? status.capableNodes[0].nodeID : "")
        if let applied = existing?.configured?.channelID, barkChannels.contains(where: { $0.id == applied }) {
            channel = applied
        } else if barkChannels.count == 1 {
            channel = barkChannels[0].id
        }
    }

    private func problems(_ status: NotifyWitnessStatus) -> [NotifyWitness.FormProblem] {
        NotifyWitness.formProblems(nodeID: node, channelID: channel, barkURL: barkURL, defaultHealthURL: status.healthURL)
    }

    @ViewBuilder
    private func form(_ status: NotifyWitnessStatus) -> some View {
        let d = status.defaults
        List {
            Section {
                Text("Files a plan. Nothing changes on the node until someone approves it.")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
            }

            Section {
                if status.capableNodes.isEmpty {
                    Text("No node runs an agent with witness mode. Update the agent on the service node first.")
                        .foregroundStyle(Color.statusWarnText)
                } else {
                    Picker("Node", selection: $node) {
                        if node.isEmpty { Text("Choose").tag("") }
                        ForEach(status.capableNodes) { candidate in
                            Text(candidate.online ? candidate.nodeName : "\(candidate.nodeName), offline").tag(candidate.nodeID)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .disabled(nodeID != nil)
                }
            } header: {
                Text("Node")
            } footer: {
                Text("The node that runs Bark. Only nodes whose agent has witness mode (control-plane-witness-v1) are listed.")
            }

            Section {
                if barkChannels.isEmpty {
                    Text("Create a Bark channel first; the witness pushes with its device key.")
                        .foregroundStyle(Color.statusWarnText)
                    WebLinkRow(title: "New channel on web", path: .notifyNotifications(view: "routing"))
                } else {
                    Picker("Bark channel", selection: $channel) {
                        if channel.isEmpty { Text("Choose").tag("") }
                        ForEach(barkChannels) { Text($0.displayName).tag($0.id) }
                    }
                    .pickerStyle(.navigationLink)
                }
            } header: {
                Text("Bark channel")
            } footer: {
                Text("The witness pushes with this channel's device key. The plan shows a fingerprint of the key, never the key.")
            }

            Section {
                TextField("http://127.0.0.1:8080", text: $barkURL)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(TextRole.identifierInDetail.font)
                    .focused($urlFocused)
                    .submitLabel(.done)
                    .frame(minHeight: Spacing.minimumTarget)
                    .accessibilityLabel("Local bark-server URL")
                if !barkURL.isEmpty, !NotifyWitness.isLoopbackBaseURL(barkURL) {
                    Text(NotifyWitness.FormProblem.barkURLLoopback.sentence)
                        .foregroundStyle(Color.statusWarnText)
                        .font(.subheadline)
                }
            } header: {
                Text("Local bark-server URL")
            } footer: {
                Text("The bark-server on that node, on its loopback address, so the key never leaves the node. bark-server listens on 8080 unless its unit says otherwise.")
            }

            Section {
                if status.healthURL.isEmpty {
                    Text("This server has no public URL, so the witness needs a watch URL of its own.")
                        .foregroundStyle(Color.statusWarnText)
                } else {
                    DetailRow(label: "Watches", value: status.healthURL, monospaced: true)
                }
                DetailRow(label: "Checks every", value: "\(d.intervalSeconds) s", copyable: false)
                DetailRow(label: "Alerts after failing for", value: "\(d.holdSeconds) s", copyable: false)
                DetailRow(label: "Recovery after answering for", value: "\(d.recoverSeconds) s", copyable: false)
                DetailRow(label: "Alert level", value: d.barkLevel, copyable: false)
                if !d.referenceURLs.isEmpty {
                    DetailRow(label: "Reference URLs", value: d.referenceURLs.joined(separator: "\n"), monospaced: true)
                }
                WebLinkRow(title: "Change these on the web", path: .notifyNotifications(view: "routing"))
            } header: {
                Text("The server's defaults")
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
    }

    private func continueBar(_ status: NotifyWitnessStatus) -> some View {
        let problems = problems(status)
        let missing = store.witnessMissing
        let note: String? = missing.map { "Needs \($0)" } ?? (network.isSatisfied ? problems.first?.sentence : "No connection")
        return VStack(spacing: Spacing.s) {
            if let note {
                Text(note)
                    .textRole(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                Task { await file(status) }
            } label: {
                Text("Continue").frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentFill)
            .disabled(!problems.isEmpty || missing != nil || filing || !network.isSatisfied)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func file(_ status: NotifyWitnessStatus) async {
        guard let picked = barkChannels.first(where: { $0.id == channel }) else { return }
        let name = status.capableNodes.first { $0.nodeID == node }?.nodeName ?? status.nodes.first { $0.nodeID == node }?.nodeName ?? node
        urlFocused = false
        filing = true
        let outcome = await runner.run(NotifyIntents.planWitness(node: ObjectRef(kind: "node", id: node, name: name), channel: picked,
                                                                 barkURL: barkURL.trimmingCharacters(in: .whitespacesAndNewlines), status: status))
        filing = false
        if case .filed = outcome { dismiss() }
    }
}
