import Foundation

enum ConnectionCheckState: Equatable {
    case idle
    case checking
    case success(String)
    case failure(String)
}

@MainActor
final class DashboardModel: ObservableObject {
    // Core (v1) state
    @Published var settings: AppSettings
    @Published var latticeToken: String
    @Published var latticeSessionCookie: String
    @Published var latticeCSRFToken: String
    @Published var loginUsername = ""
    @Published var loginPassword = ""
    @Published var loginTOTPCode = ""
    @Published var barkDeviceKey: String
    @Published private(set) var nodes: [LatticeNode] = []
    @Published private(set) var events: [MonitorEvent] = []
    @Published private(set) var isPolling = false
    @Published private(set) var isBusy = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var latticeCheckState: ConnectionCheckState = .idle
    @Published private(set) var barkCheckState: ConnectionCheckState = .idle
    @Published private(set) var backgroundRefreshStatus: BackgroundRefreshStatus
    @Published var lastError: String?

    // v2 control-plane state
    @Published var identity: LatticeIdentity?
    @Published var serverVersion: LatticeServerVersion?
    @Published private(set) var machines: [MachineProfile] = []
    @Published private(set) var monitors: [Monitor] = []
    @Published private(set) var monitorResults: [String: [MonitorResult]] = [:]
    @Published private(set) var notifyChannels: [NotifyChannel] = []
    @Published private(set) var notifyRules: [NotifyRule] = []
    @Published private(set) var auditEvents: [AuditEvent] = []
    @Published private(set) var tokens: [LatticeToken] = []
    @Published private(set) var logSources: [LogSource] = []
    @Published private(set) var logLines: [String: [LogLine]] = [:]
    @Published private(set) var tasks: [LatticeTask] = []
    @Published private(set) var taskResults: [LatticeTaskResult] = []
    @Published private(set) var geoNodes: [NodeGeoView] = []
    @Published private(set) var metricsHistory = MetricsHistory()

    // Network & security (read-only views + gated approve)
    @Published private(set) var netPolicies: [NetPolicy] = []
    @Published var netGraph: NetGraph?
    @Published private(set) var nftInputs: [NFTInputs] = []
    @Published private(set) var tunnels: [TunnelProfile] = []
    @Published private(set) var approvals: [Approval] = []

    // Per-section async state
    @Published private(set) var loadingKeys: Set<String> = []
    @Published private(set) var sectionErrors: [String: String] = [:]

    private var monitorEngine: MonitorEngine
    private var pollingTask: Task<Void, Never>?
    private var pendingTOTPChallengeID = ""

    init() {
        let loadedSettings = SettingsStore.load()
        let nodeSnapshot = NodeStore.load()
        settings = loadedSettings
        latticeToken = SecretStore.load(AppSecretAccount.latticeToken)
        latticeSessionCookie = SecretStore.load(AppSecretAccount.latticeSessionCookie)
        latticeCSRFToken = SecretStore.load(AppSecretAccount.latticeCSRFToken)
        barkDeviceKey = SecretStore.load(AppSecretAccount.barkDeviceKey)
        nodes = nodeSnapshot.nodes
        lastRefresh = nodeSnapshot.refreshedAt
        events = EventStore.load()
        backgroundRefreshStatus = BackgroundRefreshStatusStore.load()
        monitorEngine = MonitorEngine(configuration: loadedSettings.monitorConfiguration, state: MonitorEngineStateStore.load())
    }

    deinit {
        pollingTask?.cancel()
    }

    // MARK: - Derived

    var configured: Bool {
        normalizedLatticeURL(settings.latticeBaseURL) != nil && currentCredential.hasAuthentication
    }

    var hasLatticeURL: Bool {
        normalizedLatticeURL(settings.latticeBaseURL) != nil
    }

    var onlineCount: Int {
        let timeout = settings.offlineTimeout
        return nodes.filter { !$0.isOffline(timeout: timeout) }.count
    }

    var criticalCount: Int {
        nodes.filter { node in
            if node.isOffline(timeout: settings.offlineTimeout) { return true }
            if node.metrics.cpuPercent >= settings.cpuCritical { return true }
            if let memory = node.memoryUsedFraction, memory * 100 >= settings.memoryCritical { return true }
            if let disk = node.diskUsedFraction, disk * 100 >= settings.diskCritical { return true }
            return false
        }.count
    }

    var fleetSummary: FleetSummary {
        FleetSummary(nodes: nodes, configuration: settings.monitorConfiguration)
    }

    var inventorySummary: InventorySummary {
        InventorySummary(machines: machines)
    }

    /// Nodes that are currently offline or breaching a threshold.
    var criticalNodes: [LatticeNode] {
        nodes.filter { node in
            if node.isOffline(timeout: settings.offlineTimeout) { return true }
            if node.metrics.cpuPercent >= settings.cpuCritical { return true }
            if let memory = node.memoryUsedFraction, memory * 100 >= settings.memoryCritical { return true }
            if let disk = node.diskUsedFraction, disk * 100 >= settings.diskCritical { return true }
            return false
        }
    }

    var dashboardURL: URL? {
        normalizedLatticeDashboardURL(settings.latticeBaseURL)
    }

    func node(withID id: String) -> LatticeNode? {
        nodes.first { $0.id == id }
    }

    func samples(forNode id: String) -> [MetricSample] {
        metricsHistory.samples(for: id)
    }

    func isLoading(_ key: String) -> Bool { loadingKeys.contains(key) }
    func error(for key: String) -> String? { sectionErrors[key] }

    private var currentCredential: LatticeCredential {
        LatticeCredential(bearerToken: latticeToken, sessionCookie: latticeSessionCookie, csrfToken: latticeCSRFToken)
    }

    /// A configured client, or nil when the URL/credentials are missing.
    var latticeClient: LatticeClient? {
        guard let url = normalizedLatticeURL(settings.latticeBaseURL), currentCredential.hasAuthentication else {
            return nil
        }
        return LatticeClient(baseURL: url, credential: currentCredential)
    }

    // MARK: - Settings persistence

    func saveSettings() {
        settings.latticeBaseURL = settings.latticeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.barkServerURL = settings.barkServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.barkGroup = settings.barkGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.barkSound = settings.barkSound.trimmingCharacters(in: .whitespacesAndNewlines)
        latticeToken = latticeToken.trimmingCharacters(in: .whitespacesAndNewlines)
        latticeSessionCookie = latticeSessionCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        latticeCSRFToken = latticeCSRFToken.trimmingCharacters(in: .whitespacesAndNewlines)
        barkDeviceKey = BarkDeviceKeyNormalizer.deviceKey(from: barkDeviceKey)
        SettingsStore.save(settings)
        SecretStore.save(latticeToken, account: AppSecretAccount.latticeToken)
        SecretStore.save(latticeSessionCookie, account: AppSecretAccount.latticeSessionCookie)
        SecretStore.save(latticeCSRFToken, account: AppSecretAccount.latticeCSRFToken)
        SecretStore.save(barkDeviceKey, account: AppSecretAccount.barkDeviceKey)
        monitorEngine.configuration = settings.monitorConfiguration
        AstraBackgroundRefreshCoordinator.shared.schedule(settings: settings)
    }

    // MARK: - Refresh & polling (nodes)

    func refresh(sendNotifications: Bool = true) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await performRefresh(sendNotifications: sendNotifications)
    }

    private func performRefresh(sendNotifications: Bool) async {
        saveSettings()
        guard let url = normalizedLatticeURL(settings.latticeBaseURL) else {
            lastError = "Enter a Lattice server URL in Settings."
            return
        }
        guard currentCredential.hasAuthentication else {
            lastError = "Enter a Lattice PAT or log in before refreshing."
            return
        }

        do {
            let fetched = try await LatticeClient(baseURL: url, credential: currentCredential).fetchNodes()
            let refreshedAt = Date()
            nodes = fetched
            metricsHistory.record(nodes: fetched, at: refreshedAt)
            NodeStore.save(fetched, refreshedAt: refreshedAt)
            lastRefresh = refreshedAt
            lastError = nil

            let generated = monitorEngine.evaluate(nodes: fetched)
            if sendNotifications, settings.notificationsEnabled {
                do {
                    try await sendBarkNotifications(for: generated)
                } catch let failure as BarkDeliveryFailure {
                    monitorEngine.markDeliveryFailed(events: failure.undeliveredEvents)
                    lastError = failure.localizedDescription
                } catch {
                    monitorEngine.markDeliveryFailed(events: generated)
                    lastError = error.localizedDescription
                }
            } else {
                monitorEngine.markDeliveryFailed(events: generated)
            }
            MonitorEngineStateStore.save(monitorEngine.state)
            record(events: generated)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func testLatticeConnection() async {
        guard !isBusy else { return }
        saveSettings()
        guard let url = normalizedLatticeURL(settings.latticeBaseURL) else {
            let message = "Enter a Lattice server URL first."
            latticeCheckState = .failure(message)
            lastError = message
            return
        }
        guard currentCredential.hasAuthentication else {
            let message = "Enter a Lattice PAT or log in first."
            latticeCheckState = .failure(message)
            lastError = message
            return
        }

        isBusy = true
        latticeCheckState = .checking
        defer { isBusy = false }

        do {
            let client = LatticeClient(baseURL: url, credential: currentCredential)
            let fetched = try await client.fetchNodes()
            let refreshedAt = Date()
            nodes = fetched
            metricsHistory.record(nodes: fetched, at: refreshedAt)
            NodeStore.save(fetched, refreshedAt: refreshedAt)
            lastRefresh = refreshedAt
            lastError = nil
            latticeCheckState = .success("Loaded \(fetched.count) node\(fetched.count == 1 ? "" : "s").")
            identity = try? await client.fetchIdentity()
            serverVersion = try? await client.fetchServerVersion()
        } catch {
            lastError = error.localizedDescription
            latticeCheckState = .failure(error.localizedDescription)
        }
    }

    func startPolling() {
        guard pollingTask == nil else { return }
        saveSettings()
        isPolling = true
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(sendNotifications: true)
                let seconds = UInt64(max(10, self.settings.pollInterval))
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        isPolling = false
        AstraBackgroundRefreshCoordinator.shared.schedule(settings: settings)
    }

    func togglePolling() {
        isPolling ? stopPolling() : startPolling()
    }

    // MARK: - Generic section loader

    private func run(_ key: String, _ operation: @escaping (LatticeClient) async throws -> Void) async {
        guard let client = latticeClient else {
            sectionErrors[key] = "Configure Lattice in Settings first."
            return
        }
        loadingKeys.insert(key)
        sectionErrors[key] = nil
        defer { loadingKeys.remove(key) }
        do {
            try await operation(client)
        } catch {
            sectionErrors[key] = error.localizedDescription
        }
    }

    // MARK: - Section loads

    func loadAccount() async {
        await run("account") { client in
            async let identity = client.fetchIdentity()
            async let tokens = client.listTokens()
            self.identity = try await identity
            self.serverVersion = try? await client.fetchServerVersion()
            self.tokens = try await tokens
        }
    }

    func loadMachines() async {
        await run("machines") { client in
            self.machines = try await client.listMachines()
        }
    }

    func loadMonitors() async {
        await run("monitors") { client in
            self.monitors = try await client.listMonitors()
        }
    }

    func loadMonitorResults(monitorID: String) async {
        await run("monitor.\(monitorID)") { client in
            self.monitorResults[monitorID] = try await client.monitorResults(monitorID: monitorID)
        }
    }

    func loadNotify() async {
        await run("notify") { client in
            async let channels = client.listNotifyChannels()
            async let rules = client.listNotifyRules()
            self.notifyChannels = try await channels
            self.notifyRules = try await rules
        }
    }

    func loadAudit() async {
        await run("audit") { client in
            self.auditEvents = try await client.fetchAudit(limit: 200).events
        }
    }

    func loadLogs() async {
        await run("logs") { client in
            self.logSources = try await client.listLogSources()
        }
    }

    func loadLogLines(sourceID: String, search: String? = nil) async {
        await run("logline.\(sourceID)") { client in
            self.logLines[sourceID] = try await client.queryLogs(sourceID: sourceID, search: search, limit: 200).lines
        }
    }

    func loadTasks() async {
        await run("tasks") { client in
            async let tasks = client.listTasks()
            async let results = client.listTaskResults()
            self.tasks = try await tasks
            self.taskResults = try await results
        }
    }

    func loadGeo() async {
        await run("geo") { client in
            self.geoNodes = try await client.fetchNodeGeo()
        }
    }

    var pendingApprovalCount: Int {
        approvals.filter { $0.isPending }.count
    }

    /// Loads all network/security read views. Each endpoint is tolerated
    /// independently so a token missing one scope still shows the rest; failures
    /// are surfaced (never silently swallowed) in the "network" section error.
    func loadNetwork() async {
        guard let client = latticeClient else {
            sectionErrors["network"] = "Configure Lattice in Settings first."
            return
        }
        loadingKeys.insert("network")
        sectionErrors["network"] = nil
        defer { loadingKeys.remove("network") }

        var failed: [String] = []
        do { approvals = try await client.listApprovals() } catch { failed.append("approvals") }
        do { netPolicies = try await client.listNetPolicies() } catch { failed.append("policies") }
        do { netGraph = try await client.netPolicyGraph() } catch { failed.append("graph") }
        do { nftInputs = try await client.listNFTInputs() } catch { failed.append("nft") }
        do { tunnels = try await client.listTunnels() } catch { failed.append("tunnels") }

        if failed.count == 5 {
            sectionErrors["network"] = "Couldn't load network data — check your connection or token scopes."
        } else if !failed.isEmpty {
            sectionErrors["network"] = "Some sections need higher scopes: \(failed.joined(separator: ", "))."
        }
    }

    /// Approves a pending plan. Always sends the SHA-256 of the reviewed plan so
    /// the server rejects a plan that changed since review. This is the one write
    /// action in the network surface and is always behind an explicit confirm.
    @discardableResult
    func approve(_ approval: Approval, queueApply: Bool) async -> Bool {
        guard let client = latticeClient else { lastError = "Configure Lattice first."; return false }
        do {
            _ = try await client.approveApproval(approvalID: approval.id, queueApply: queueApply, planSHA256: approval.planHash)
            await loadNetwork()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Actions

    @discardableResult
    func setNodeDisabled(nodeID: String, disabled: Bool) async -> Bool {
        guard let client = latticeClient else { lastError = "Configure Lattice first."; return false }
        do {
            try await client.setNodeDisabled(nodeID: nodeID, disabled: disabled)
            await refresh(sendNotifications: false)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func rotateNodeToken(nodeID: String) async -> NodeTokenResponse? {
        guard let client = latticeClient else { lastError = "Configure Lattice first."; return nil }
        do { return try await client.rotateNodeToken(nodeID: nodeID) }
        catch { lastError = error.localizedDescription; return nil }
    }

    func enrollNode(nodeID: String, name: String, tags: [String], role: String, wireGuardIP: String) async -> NodeTokenResponse? {
        guard let client = latticeClient else { lastError = "Configure Lattice first."; return nil }
        do {
            let result = try await client.enrollNode(nodeID: nodeID, name: name, tags: tags, role: role, wireGuardIP: wireGuardIP)
            await refresh(sendNotifications: false)
            return result
        } catch { lastError = error.localizedDescription; return nil }
    }

    func createToken(name: String, scopes: [String], serverAllowlist: [String]) async -> CreatedTokenResponse? {
        guard let client = latticeClient else { lastError = "Configure Lattice first."; return nil }
        do {
            let result = try await client.createToken(name: name, scopes: scopes, serverAllowlist: serverAllowlist)
            await loadAccount()
            return result
        } catch { lastError = error.localizedDescription; return nil }
    }

    @discardableResult
    func revokeToken(tokenID: String) async -> Bool {
        guard let client = latticeClient else { lastError = "Configure Lattice first."; return false }
        do { try await client.revokeToken(tokenID: tokenID); await loadAccount(); return true }
        catch { lastError = error.localizedDescription; return false }
    }

    @discardableResult
    func saveMachine(_ request: MachineProfileRequest, isNew: Bool) async -> Bool {
        guard let client = latticeClient else { lastError = "Configure Lattice first."; return false }
        do {
            _ = isNew ? try await client.createMachine(request) : try await client.updateMachine(request)
            await loadMachines()
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    @discardableResult
    func deleteMachine(id: String) async -> Bool {
        guard let client = latticeClient else { lastError = "Configure Lattice first."; return false }
        do { try await client.deleteMachine(id: id); await loadMachines(); return true }
        catch { lastError = error.localizedDescription; return false }
    }

    @discardableResult
    func renewMachine(id: String, nextRenewal: Date) async -> Bool {
        guard let client = latticeClient else { lastError = "Configure Lattice first."; return false }
        do { _ = try await client.renewMachine(id: id, nextRenewal: nextRenewal); await loadMachines(); return true }
        catch { lastError = error.localizedDescription; return false }
    }

    @discardableResult
    func createMonitor(name: String, type: MonitorType, target: String, intervalSec: Int, timeoutSec: Int, assignAll: Bool, nodeIDs: [String]) async -> Bool {
        guard let client = latticeClient else { lastError = "Configure Lattice first."; return false }
        do {
            try await client.createMonitor(name: name, type: type, target: target, intervalSec: intervalSec, timeoutSec: timeoutSec, assignAll: assignAll, nodeIDs: nodeIDs)
            await loadMonitors()
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    @discardableResult
    func deleteMonitor(id: String) async -> Bool {
        guard let client = latticeClient else { lastError = "Configure Lattice first."; return false }
        do { try await client.deleteMonitor(id: id); await loadMonitors(); return true }
        catch { lastError = error.localizedDescription; return false }
    }

    @discardableResult
    func testNotifyChannel(id: String) async -> Bool {
        guard let client = latticeClient else { lastError = "Configure Lattice first."; return false }
        do {
            try await client.testNotifyChannel(channelID: id, title: "Lattice test", body: "Test notification from the Lattice iOS app.")
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    @discardableResult
    func resolveGeo(all: Bool = true, missingOnly: Bool = true) async -> Bool {
        guard let client = latticeClient else { lastError = "Configure Lattice first."; return false }
        do { _ = try await client.resolveNodeGeo(all: all, missingOnly: missingOnly); await loadGeo(); return true }
        catch { lastError = error.localizedDescription; return false }
    }

    @discardableResult
    func runRenewalReminders() async -> Int {
        guard let client = latticeClient else { lastError = "Configure Lattice first."; return 0 }
        do { return try await client.runRenewalReminders().count }
        catch { lastError = error.localizedDescription; return 0 }
    }

    // MARK: - Bark test

    func sendTestBark() async {
        guard !isBusy else { return }
        saveSettings()
        guard let serverURL = normalizedBarkURL(settings.barkServerURL) else {
            let message = "Bark server URL is invalid."
            barkCheckState = .failure(message)
            lastError = message
            return
        }
        let event = MonitorEvent(
            id: "lattice.test",
            nodeID: "local",
            nodeName: "Lattice",
            kind: .recovered,
            title: "Lattice test",
            body: "Bark notifications are configured.",
            date: Date()
        )
        let configuration = BarkConfiguration(
            serverURL: serverURL,
            deviceKey: barkDeviceKey,
            defaultGroup: settings.barkGroup,
            sound: settings.barkSound.isEmpty ? nil : settings.barkSound,
            icon: URL(string: "https://day.app/assets/images/avatar.jpg"),
            url: normalizedLatticeDashboardURL(settings.latticeBaseURL),
            level: settings.barkLevel
        )

        isBusy = true
        barkCheckState = .checking
        defer { isBusy = false }

        do {
            try await BarkClient().send(configuration: configuration, event: event)
            lastError = nil
            barkCheckState = .success("Test notification sent.")
        } catch {
            lastError = error.localizedDescription
            barkCheckState = .failure(error.localizedDescription)
        }
    }

    // MARK: - Login

    func loginToLattice() async {
        guard !isBusy else { return }
        saveSettings()
        guard let url = normalizedLatticeURL(settings.latticeBaseURL) else {
            lastError = "Enter a Lattice server URL before login."
            latticeCheckState = .failure(lastError ?? "")
            return
        }
        let username = loginUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !loginPassword.isEmpty else {
            lastError = "Enter Lattice username and password."
            latticeCheckState = .failure(lastError ?? "")
            return
        }

        isBusy = true
        latticeCheckState = .checking
        defer { isBusy = false }

        do {
            let client = LatticeClient(baseURL: url)
            let session: LatticeLoginSession
            if !pendingTOTPChallengeID.isEmpty, !loginTOTPCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                session = try await client.loginTOTP(
                    challengeID: pendingTOTPChallengeID,
                    code: loginTOTPCode.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            } else {
                session = try await client.login(username: username, password: loginPassword)
            }
            apply(session: session)
            loginUsername = username
            loginPassword = ""
            loginTOTPCode = ""
            pendingTOTPChallengeID = ""
            saveSettings()
            lastError = nil
            latticeCheckState = .success("Logged in as \(session.actorID ?? username).")
            await performRefresh(sendNotifications: false)
            await loadAccount()
        } catch LatticeAPIError.totpRequired(let challengeID) {
            pendingTOTPChallengeID = challengeID
            lastError = "Enter your Lattice TOTP code and tap Login again."
            latticeCheckState = .failure(lastError ?? "")
        } catch {
            lastError = error.localizedDescription
            latticeCheckState = .failure(error.localizedDescription)
        }
    }

    func signOut() {
        latticeToken = ""
        latticeSessionCookie = ""
        latticeCSRFToken = ""
        identity = nil
        tokens = []
        saveSettings()
        latticeCheckState = .idle
    }

    // MARK: - Background refresh

    func configureBackgroundRefresh() {
        AstraBackgroundRefreshCoordinator.shared.schedule(settings: settings)
        reloadBackgroundRefreshStatus()
    }

    func reloadBackgroundRefreshStatus() {
        backgroundRefreshStatus = BackgroundRefreshStatusStore.load()
    }

    // MARK: - Private helpers

    private func apply(session: LatticeLoginSession) {
        latticeToken = ""
        latticeSessionCookie = session.sessionCookie
        latticeCSRFToken = session.csrfToken
    }

    private func sendBarkNotifications(for events: [MonitorEvent]) async throws {
        guard !events.isEmpty else { return }
        guard let serverURL = normalizedBarkURL(settings.barkServerURL) else {
            throw BarkError.invalidURL
        }
        let configuration = BarkConfiguration(
            serverURL: serverURL,
            deviceKey: barkDeviceKey,
            defaultGroup: settings.barkGroup,
            sound: settings.barkSound.isEmpty ? nil : settings.barkSound,
            icon: URL(string: "https://day.app/assets/images/avatar.jpg"),
            url: normalizedLatticeDashboardURL(settings.latticeBaseURL),
            level: settings.barkLevel
        )
        let client = BarkClient()
        try await client.sendAll(configuration: configuration, events: events)
    }

    private func record(events newEvents: [MonitorEvent]) {
        guard !newEvents.isEmpty else { return }
        events.insert(contentsOf: newEvents.reversed(), at: 0)
        if events.count > 100 {
            events.removeLast(events.count - 100)
        }
        EventStore.save(events)
    }

    private func normalizedLatticeURL(_ rawValue: String) -> URL? {
        AstraURLNormalizer.serviceURL(from: rawValue)
    }

    private func normalizedBarkURL(_ rawValue: String) -> URL? {
        AstraURLNormalizer.serviceURL(from: rawValue, defaultScheme: "http")
    }

    private func normalizedLatticeDashboardURL(_ rawValue: String) -> URL? {
        AstraURLNormalizer.latticeDashboardURL(from: rawValue)
    }
}
