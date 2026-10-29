import Synchronization
import SwiftUI

/// The digest a knock reveal hands to the rotation, and nothing else.
final class SSHGuardDigestBox: Sendable {
    private let value = Mutex<String?>(nil)

    func set(_ digest: String) { value.withLock { $0 = digest } }
    func take() -> String? { value.withLock { $0 } }
}

/// What the arm sheet reads before it can show a form: the node's status,
/// its last arm plan (to prefill), and in rotate mode the knock state and
/// the plan of the arm that installed the sequence.
@MainActor @Observable
final class SSHGuardArmModel {
    enum Load: Equatable {
        case loading
        case ready
        case failed(String)
    }

    let nodeID: String
    let rotate: Bool
    private(set) var load: Load = .loading
    private(set) var status: SSHGuardNodeStatus?
    private(set) var knock: SSHGuardKnockState?
    private(set) var governingPlan: String?
    private(set) var digest: String?
    var form: SSHGuardRotation.Form
    var portText = ""
    var movePort = false
    var previousPorts = ""
    @ObservationIgnored let digestBox = SSHGuardDigestBox()

    init(nodeID: String, rotate: Bool) {
        self.nodeID = nodeID
        self.rotate = rotate
        form = .defaults(nodeID: nodeID)
    }

    func start(session: SessionStore) async {
        guard let client = session.client else {
            load = .failed("Not connected to a server.")
            return
        }
        load = .loading
        do {
            let status = try await client.fetchSSHGuardStatus(nodeID: nodeID)
            self.status = status
            if rotate {
                let knock = try await client.sshGuardKnockState(nodeID: nodeID)
                self.knock = knock
                if !knock.approvalID.isEmpty {
                    let arm = try? await client.fetchApproval(id: knock.approvalID)
                    governingPlan = arm.flatMap { $0.nodeID == nodeID && $0.isSSHGuardArm ? $0.plan : nil }
                }
            } else {
                var lastPlan: String?
                if let id = status.lastArm?.approvalID, !id.isEmpty {
                    lastPlan = (try? await client.fetchApproval(id: id))?.plan
                }
                form = .prefilled(nodeID: nodeID, lastArm: status.lastArm, lastArmPlan: lastPlan)
                movePort = form.sshPort > 0
                portText = form.sshPort > 0 ? String(form.sshPort) : ""
            }
            load = .ready
        } catch {
            load = .failed(LatticeAPIError(error).localizedDescription)
        }
    }

    var name: String {
        guard let status, !status.nodeName.isEmpty else { return nodeID }
        return status.nodeName
    }

    var ref: ObjectRef { ObjectRef(kind: "node", id: nodeID, name: name) }

    var observedPorts: [Int] { status?.sshd?.ports ?? [] }

    /// Applies the port field to the form.
    func syncPort() {
        form.sshPort = movePort ? (Int(portText.trimmingCharacters(in: .whitespaces)) ?? -1) : 0
    }

    var problems: [SSHGuardRotation.FormProblem] {
        var problems = SSHGuardRotation.validate(form)
        if movePort, form.sshPort <= 0, !problems.contains(.portRange) { problems.append(.portRange) }
        return problems
    }

    // MARK: Rotation

    var rotationPort: Int? {
        SSHGuardRotation.rotationSSHPort(serverPort: knock?.sshPort, governingPlan: governingPlan, observed: observedPorts)
    }

    var eligibility: SSHGuardRotation.RotateEligibility {
        SSHGuardRotation.eligibility(selected: [knock?.knowledge ?? "unknown"], previousPorts: previousPorts, sshPort: rotationPort, governingPlan: governingPlan)
    }

    var fallback: SSHGuardRotation.Fallback {
        SSHGuardRotation.fallback(forPlan: governingPlan)
    }

    /// Picks up the digest the reveal step captured, if it ran.
    func collectDigest() {
        if let value = digestBox.take(), !value.isEmpty { digest = value }
    }

    var rotationRequest: SSHGuardPlanRequest? {
        switch eligibility {
        case .digest:
            guard let digest else { return nil }
            return SSHGuardRotation.rotationRequest(nodeID: nodeID, sshPort: rotationPort ?? 0, from: .digest(digest), fallback: fallback)
        case .previousPorts(let ports):
            return SSHGuardRotation.rotationRequest(nodeID: nodeID, sshPort: rotationPort ?? 0, from: .previousPorts(ports), fallback: fallback)
        case .refused:
            return nil
        }
    }
}

/// M7-05 SSH Guard arm and knock rotation. Opens at `.large`; every step of
/// the flow (the reveal, the plan's confirm and findings) is pushed on this
/// sheet's own stack, so no second sheet opens.
struct SSHGuardArmSheet: View {
    let nodeID: String
    var rotate = false

    @State private var model: SSHGuardArmModel
    @State private var autoContinued = false
    @Environment(SessionStore.self) private var session
    @Environment(ActionRunner.self) private var runner
    @Environment(SSHGuardStore.self) private var store
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.dismiss) private var dismiss

    init(nodeID: String, rotate: Bool = false) {
        self.nodeID = nodeID
        self.rotate = rotate
        _model = State(initialValue: SSHGuardArmModel(nodeID: nodeID, rotate: rotate))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(rotate ? "Rotate knock" : "Arm SSH Guard")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                            .disabled(runner.isBusy)
                    }
                }
                .actionHost(inSheet: true)
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(runner.isBusy)
        .task {
            await model.start(session: session)
            await autoContinueIfAsked()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.load {
        case .loading:
            List { LoadingRows(label: "Loading \(rotate ? "the knock" : "the arm form")", count: 5) }
        case .failed(let message):
            WholeScreenState {
                ContentUnavailableView {
                    Label("Could not load \(model.name)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { Task { await model.start(session: session) } }.buttonStyle(.bordered)
                }
            }
        case .ready:
            if rotate { rotateForm } else { armForm }
        }
    }

    // MARK: Arm

    private var armForm: some View {
        @Bindable var model = model
        return Form {
            nodeSection
            Section {
                Toggle("Move SSH to a new port", isOn: $model.movePort)
                    .onChange(of: model.movePort) { model.syncPort() }
                if model.movePort {
                    TextField("Port, such as 58394", text: $model.portText)
                        .keyboardType(.numberPad)
                        .font(TextRole.identifierInDetail.font)
                        .onChange(of: model.portText) { model.syncPort() }
                    Toggle("Keep port 22 working too", isOn: $model.form.keepLegacyPort)
                }
            } header: {
                Text("SSH port").accessibilityAddTraits(.isHeader)
            } footer: {
                Text(portConsequence)
            }
            Section {
                Toggle("Port knocking", isOn: $model.form.enableKnock)
            } header: {
                Text("Knock").accessibilityAddTraits(.isHeader)
            } footer: {
                Text(model.form.enableKnock
                     ? "Anyone outside the management sources must knock a three-port sequence first. The server draws the sequence; it is revealed only with a fresh authenticator code."
                     : "No knock: only the management sources reach SSH. With no source either, the plan hardens sshd and installs no firewall.")
            }
            Section {
                TextField("Addresses or CIDR ranges", text: $model.form.mgmtSources, axis: .vertical)
                    .font(TextRole.identifierInDetail.font)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(2...6)
                let invalid = SSHGuardRotation.parseMgmtSources(model.form.mgmtSources).invalid
                if !invalid.isEmpty {
                    Label("Not an address: \(invalid.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.statusWarnText)
                }
            } header: {
                Text("Management sources").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("These sources reach SSH without knocking and never expire. Separate them with spaces, commas or new lines.")
            }
            Section {
                Toggle("Lattice terminal as the fallback", isOn: $model.form.outOfBandFallback)
            } footer: {
                Text(model.form.outOfBandFallback
                     ? "If knocking fails, the way back in is the node's Lattice terminal. The server refuses this when the node is offline or does not report the terminal."
                     : "Off: without a management source, the knock sequence is the only way in.")
            }
            Section {
                Picker("Confirm within", selection: $model.form.confirmWindowSec) {
                    ForEach(windowChoices, id: \.self) { seconds in
                        Text(SSHGuardIntents.windowWords(seconds)).tag(seconds)
                    }
                }
            } header: {
                Text("Revert timer").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Once the arm applies, \(model.name) undoes every change by itself unless a confirm plan applies within \(SSHGuardIntents.windowWords(model.form.confirmWindowSec)). Confirm only after you opened a new SSH connection over the hardened path.")
            }
            if !model.problems.isEmpty {
                Section {
                    ForEach(model.problems, id: \.self) { problem in
                        Label(problem.sentence, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.statusWarnText)
                    }
                } header: {
                    Text("Before filing").accessibilityAddTraits(.isHeader)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            primaryButton(title: "Continue", blocked: armBlockReason) { await fileArm() }
        }
    }

    private var windowChoices: [Int] {
        let base = [300, 600, 900, 1800, 3600]
        return base.contains(model.form.confirmWindowSec) ? base : (base + [model.form.confirmWindowSec]).sorted()
    }

    private var portConsequence: String {
        let current = model.observedPorts.isEmpty ? "its current port" : "port \(model.observedPorts.map(String.init).joined(separator: ", "))"
        if !model.movePort {
            return "sshd stays on \(current). The plan changes who may reach it, not where it listens."
        }
        return model.form.keepLegacyPort
            ? "sshd adds the new port before anything is taken away, and port 22 keeps working beside it."
            : "sshd moves to the new port; port 22 stops answering once the arm applies."
    }

    /// Short, because it sits pinned above the button; the problems
    /// themselves are listed in full in the form.
    private var armBlockReason: String? {
        if let reason = store.planBlockReason() { return reason }
        switch model.problems.count {
        case 0: return nil
        case 1: return "Fix the problem listed above"
        default: return "Fix the \(model.problems.count) problems listed above"
        }
    }

    private func fileArm() async {
        model.syncPort()
        await runner.run(SSHGuardIntents.arm(model.ref, form: model.form))
    }

    // MARK: Rotate

    private var rotateForm: some View {
        @Bindable var model = model
        let eligibility = model.eligibility
        return Form {
            nodeSection
            if let knock = model.knock {
                Section {
                    StatusRow(style: StatusStyle(word: SSHGuardKnockWords.word(knock.knowledge), symbol: SSHGuardKnockWords.symbol(knock.knowledge), tone: .quiet),
                              title: "Current sequence", detail: knock.portCount.map { "\($0) ports, opens for \(knock.openFor.isEmpty ? "12h" : knock.openFor)" })
                    if let port = model.rotationPort {
                        DetailRow(label: "SSH port", value: port == 0 || port == 22 ? "Keeps the current port" : String(port), copyable: false)
                    }
                    DetailRow(label: "Fallback", value: fallbackWords, copyable: false)
                    DetailRow(label: "Confirm within", value: SSHGuardIntents.windowWords(SSHGuardRotation.rotationConfirmWindowSec), copyable: false)
                } header: {
                    Text("What the rotation keeps").accessibilityAddTraits(.isHeader)
                } footer: {
                    Text(knock.note)
                }
            }
            switch eligibility {
            case .digest:
                Section {
                    if let digest = model.digest {
                        Label {
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text("Current sequence identified")
                                Text(PlanSeal.short(digest)).textRole(.identifierInRow)
                            }
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.statusOKFill)
                        }
                        .frame(minHeight: Spacing.minimumTarget)
                        .accessibilityElement(children: .combine)
                    } else {
                        Button {
                            Task { await revealCurrent() }
                        } label: {
                            SSHGuardActionLabel(title: "Reveal the current sequence", symbol: "eye",
                                                note: session.revealClient == nil
                                                    ? "Needs a signed-in session and a fresh authenticator code."
                                                    : "Needs a fresh authenticator code. The server names the sequence by its digest.")
                        }
                    }
                } header: {
                    Text("Step 1: name the current sequence").accessibilityAddTraits(.isHeader)
                } footer: {
                    Text("The rotation must name the sequence the node runs today, so it keeps working beside the new one until the confirm applies.")
                }
            case .previousPorts, .refused(.previousPortsRequired), .refused(.previousPortsInvalid):
                Section {
                    TextField("Three ports, such as 27431 45902 38117", text: $model.previousPorts)
                        .keyboardType(.numbersAndPunctuation)
                        .font(TextRole.identifierInDetail.font)
                    if case .refused(let code) = eligibility, !model.previousPorts.trimmingCharacters(in: .whitespaces).isEmpty {
                        Label(code.sentence, systemImage: "exclamationmark.triangle").foregroundStyle(Color.statusWarnText)
                    }
                } header: {
                    Text("Ports the node knocks on now").accessibilityAddTraits(.isHeader)
                } footer: {
                    Text(SSHGuardRotation.RotateRefusal.previousPortsRequired.sentence)
                }
            case .refused(let code):
                Section {
                    Label(code.sentence, systemImage: "info.circle")
                        .frame(minHeight: Spacing.minimumTarget)
                } header: {
                    Text("Cannot rotate").accessibilityAddTraits(.isHeader)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if eligibility.isOpenable {
                primaryButton(title: "Continue", blocked: rotateBlockReason) { await fileRotation() }
            }
        }
    }

    private var fallbackWords: String {
        switch model.fallback {
        case .terminal: "Lattice terminal"
        case .sources(let sources): sources.joined(separator: ", ")
        }
    }

    private var rotateBlockReason: String? {
        if let reason = store.planBlockReason() { return reason }
        switch model.eligibility {
        case .digest: return model.digest == nil ? "Reveal the current sequence first" : nil
        case .previousPorts: return nil
        case .refused(let code): return code.sentence
        }
    }

    private func revealCurrent() async {
        let box = model.digestBox
        await runner.reveal(SSHGuardIntents.knockReveal(model.ref) { box.set($0) })
        model.collectDigest()
    }

    private func fileRotation() async {
        guard let request = model.rotationRequest else { return }
        await runner.run(SSHGuardIntents.rotate(model.ref, request: request))
    }

    // MARK: Shared parts

    private var nodeSection: some View {
        Section {
            if let status = model.status {
                let posture = StatusStyle.posture(status.postureState)
                StatusRow(style: posture, title: model.name, detail: status.sshd.map { "sshd on \($0.ports.map(String.init).joined(separator: ", "))" },
                          accessibilityPhrase: "\(model.name), \(posture.word)")
            }
        } footer: {
            Text(rotate
                 ? "Files an arm plan that draws a new knock sequence. Nothing changes until the plan is approved."
                 : "Files an arm plan. Nothing changes until it is approved, and the server lints it first.")
        }
    }

    private func primaryButton(title: String, blocked: String?, action: @escaping () async -> Void) -> some View {
        let reason = network.isSatisfied ? blocked : "No connection"
        return VStack(spacing: Spacing.s) {
            if let reason {
                Text(reason).textRole(.footnote).multilineTextAlignment(.center)
            }
            Button {
                Task { await action() }
            } label: {
                Text(title).fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget - 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentFill)
            .disabled(reason != nil || runner.isBusy)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    /// Demo screenshots only: `-AstraAutoConfirm YES` taps Continue once.
    private func autoContinueIfAsked() async {
        guard LaunchOverrides.current.autoConfirm, session.isDemo, !autoContinued, model.load == .ready else { return }
        autoContinued = true
        try? await Task.sleep(for: .milliseconds(500))
        if rotate {
            if model.rotationRequest != nil { await fileRotation() }
        } else if armBlockReason == nil {
            await fileArm()
        }
    }
}
