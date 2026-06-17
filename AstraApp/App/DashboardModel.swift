import Foundation

enum ConnectionCheckState: Equatable {
    case idle
    case checking
    case success(String)
    case failure(String)
}

@MainActor
final class DashboardModel: ObservableObject {
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
            if node.isOffline(timeout: settings.offlineTimeout) {
                return true
            }
            if node.metrics.cpuPercent >= settings.cpuCritical {
                return true
            }
            if let memory = node.memoryUsedFraction, memory * 100 >= settings.memoryCritical {
                return true
            }
            if let disk = node.diskUsedFraction, disk * 100 >= settings.diskCritical {
                return true
            }
            return false
        }.count
    }

    private var currentCredential: LatticeCredential {
        LatticeCredential(
            bearerToken: latticeToken,
            sessionCookie: latticeSessionCookie,
            csrfToken: latticeCSRFToken
        )
    }

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

    func refresh(sendNotifications: Bool = true) async {
        guard !isBusy else {
            return
        }
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
        guard !isBusy else {
            return
        }
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
            let fetched = try await LatticeClient(baseURL: url, credential: currentCredential).fetchNodes()
            let refreshedAt = Date()
            nodes = fetched
            NodeStore.save(fetched, refreshedAt: refreshedAt)
            lastRefresh = refreshedAt
            lastError = nil
            latticeCheckState = .success("Loaded \(fetched.count) node\(fetched.count == 1 ? "" : "s").")
        } catch {
            lastError = error.localizedDescription
            latticeCheckState = .failure(error.localizedDescription)
        }
    }

    func startPolling() {
        guard pollingTask == nil else {
            return
        }
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

    func sendTestBark() async {
        guard !isBusy else {
            return
        }
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

    func loginToLattice() async {
        guard !isBusy else {
            return
        }
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
        } catch LatticeAPIError.totpRequired(let challengeID) {
            pendingTOTPChallengeID = challengeID
            lastError = "Enter your Lattice TOTP code and tap Login again."
            latticeCheckState = .failure(lastError ?? "")
        } catch {
            lastError = error.localizedDescription
            latticeCheckState = .failure(error.localizedDescription)
        }
    }

    func configureBackgroundRefresh() {
        AstraBackgroundRefreshCoordinator.shared.schedule(settings: settings)
        reloadBackgroundRefreshStatus()
    }

    func reloadBackgroundRefreshStatus() {
        backgroundRefreshStatus = BackgroundRefreshStatusStore.load()
    }

    private func apply(session: LatticeLoginSession) {
        latticeToken = ""
        latticeSessionCookie = session.sessionCookie
        latticeCSRFToken = session.csrfToken
    }

    private func sendBarkNotifications(for events: [MonitorEvent]) async throws {
        guard !events.isEmpty else {
            return
        }
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
        guard !newEvents.isEmpty else {
            return
        }
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
