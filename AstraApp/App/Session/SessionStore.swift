import BackgroundTasks
import Foundation
import UserNotifications

/// Which credential the primary client carries.
enum CredentialKind: String, Sendable {
    case token
    case session
}

/// The result of the password step of sign-in.
enum PasswordSignInStep: Sendable {
    case signedIn(LatticeLoginSession)
    case needsTOTP(challengeID: String)
}

/// Server, credentials, both clients and their scopes (sections 6.12, 7.2, 8.4).
///
/// `client` carries the PAT when one exists, otherwise the session.
/// `revealClient` carries the session only and is nil without one; with a PAT
/// present it serves S intents and session-only account endpoints alone.
@MainActor @Observable
final class SessionStore {
    private enum Key {
        static let serverURL = "session.serverURL"
        static let consoleURL = "session.consoleURL"
        static let credentialKind = "session.credentialKind"
        static let actorID = "session.actorID"
        static let username = "session.username"
        static let keepSession = "session.keepSession"
        static let endAfterReveal = "session.endAfterReveal"
    }

    private(set) var serverURL: URL?
    private(set) var credentialKind: CredentialKind?
    private(set) var client: LatticeClient?
    private(set) var revealClient: LatticeClient?
    /// `/api/me` on `client`.
    private(set) var primaryIdentity: LatticeIdentity?
    /// `/api/me` on `revealClient`.
    private(set) var sessionIdentity: LatticeIdentity?
    private(set) var identityError: LatticeAPIError?
    private(set) var revealSession: LatticeLoginSession?
    private(set) var serverVersion: LatticeServerVersion?
    private(set) var isDemo = false
    private(set) var demoScenario: DemoScenario = .normal
    /// `-AstraDemoToken`: the token preset kept across scenario changes.
    @ObservationIgnored private var demoToken: DemoToken?
    private(set) var demoClock = DemoClock()
    private(set) var demoState = DemoState()
    /// Surfaces whose responses could not be decoded, for Diagnostics.
    private(set) var companionBehind: Set<String> = []
    /// A 401 on `client`: "Your token was rejected".
    private(set) var tokenRejected = false
    /// A 401 on `revealClient`: "Session expired. Sign in again for reveals."
    private(set) var sessionExpired = false
    /// Bumps whenever the credential changes, so stores drop what they hold.
    private(set) var generation = 0

    let diagnostics = DiagnosticsLog()
    private let network: NetworkMonitor

    init(network: NetworkMonitor) {
        self.network = network
    }

    // MARK: Derived state

    var isConnected: Bool { client != nil }

    /// The console origin for "Open on web"; defaults to the server URL.
    var consoleURL: URL? {
        if let raw = UserDefaults.standard.string(forKey: Key.consoleURL), let url = URL(string: raw) { return url }
        return serverURL
    }

    /// The scopes of the primary client (the PAT's when one exists). Nil while
    /// unknown, which is not the same as missing.
    var tokenScopes: ScopeSet? { primaryIdentity?.scopeSet }
    var sessionScopes: ScopeSet? { sessionIdentity?.scopeSet }

    func scopes(for kind: ClientKind) -> ScopeSet? {
        kind == .session ? sessionScopes : tokenScopes
    }

    func client(for kind: ClientKind) -> LatticeClient? {
        kind == .session ? revealClient : client
    }

    /// The scopes `requirement` lacks on that client, or nil when the scopes
    /// are not known yet (the server then decides).
    func missing(_ requirement: ScopeRequirement, on kind: ClientKind = .primary) -> [String]? {
        guard let scopes = scopes(for: kind) else { return nil }
        return scopes.missing(requirement)
    }

    var hostName: String {
        isDemo ? "demo.lattice.invalid" : (serverURL?.host() ?? "the server")
    }

    /// "Keep the session on this iPhone". Demo never touches the Keychain or
    /// the stored preference (7.3), so in demo the choice lives in memory.
    var keepSession: Bool {
        get {
            access(keyPath: \.keepSession)
            return isDemo ? demoKeepSession : UserDefaults.standard.bool(forKey: Key.keepSession)
        }
        set {
            guard !isDemo else {
                withMutation(keyPath: \.keepSession) { demoKeepSession = newValue }
                return
            }
            withMutation(keyPath: \.keepSession) { UserDefaults.standard.set(newValue, forKey: Key.keepSession) }
            if newValue, let revealSession { try? KeychainStore.saveSession(revealSession) } else { KeychainStore.deleteSession() }
        }
    }
    @ObservationIgnored private var demoKeepSession = false

    var endSessionAfterReveal: Bool {
        get {
            access(keyPath: \.endSessionAfterReveal)
            return isDemo ? demoEndSessionAfterReveal : UserDefaults.standard.object(forKey: Key.endAfterReveal) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.endSessionAfterReveal) {
                if isDemo { demoEndSessionAfterReveal = newValue } else { UserDefaults.standard.set(newValue, forKey: Key.endAfterReveal) }
            }
        }
    }
    @ObservationIgnored private var demoEndSessionAfterReveal = true

    // MARK: Launch

    /// Rebuilds the clients from what is stored. A kept session is not read
    /// here: it needs Face ID and is loaded the first time a reveal needs it.
    func restore(launch: LaunchOverrides) {
        if launch.demo {
            demoToken = launch.demoToken
            enterDemo(scenario: launch.scenario ?? .normal, clock: launch.demoNow.flatMap(DemoClock.init(pinned:)) ?? DemoClock())
            return
        }
        network.use(SystemPathSource())
        guard let raw = UserDefaults.standard.string(forKey: Key.serverURL), let url = URL(string: raw),
              AstraURLNormalizer.isAllowedServerURL(url),
              let token = KeychainStore.loadPAT() else { return }
        serverURL = url
        credentialKind = .token
        client = makeClient(url, LatticeCredential(bearerToken: token), kind: .primary)
        Task { await refreshIdentity() }
    }

    // MARK: Onboarding

    /// Server step: normalizes the URL, then reads `/api/health` and `/api/version`.
    func probeServer(_ raw: String) async throws -> (URL, LatticeServerVersion) {
        guard let url = AstraURLNormalizer.serviceURL(from: raw) else {
            throw LatticeAPIError.invalidURL(raw)
        }
        let probe = LatticeClient(baseURL: url)
        let health = try await probe.fetchHealth()
        guard !health.status.isEmpty else { throw LatticeAPIError.invalidResponse }
        let version = try await probe.fetchServerVersion()
        return (url, version)
    }

    /// Credential step with a PAT: validated by `/api/me`, then stored.
    func connect(server: URL, token rawToken: String) async throws -> LatticeIdentity {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = makeClient(server, LatticeCredential(bearerToken: token), kind: .primary)
        let identity = try await candidate.fetchIdentity()
        try KeychainStore.savePAT(token)
        UserDefaults.standard.set(server.absoluteString, forKey: Key.serverURL)
        UserDefaults.standard.set(CredentialKind.token.rawValue, forKey: Key.credentialKind)
        remember(identity)
        serverURL = server
        credentialKind = .token
        client = candidate
        primaryIdentity = identity
        identityError = nil
        tokenRejected = false
        generation += 1
        serverVersion = try? await candidate.fetchServerVersion()
        return identity
    }

    /// The password step, against the configured server or `server`.
    func beginPasswordSignIn(server: URL? = nil, username: String, password: String) async throws -> PasswordSignInStep {
        guard let url = server ?? serverURL else { throw LatticeAPIError.invalidURL("") }
        do {
            return .signedIn(try await sessionProbe(url).login(username: username, password: password))
        } catch LatticeAPIError.totpRequired(let challengeID) {
            return .needsTOTP(challengeID: challengeID)
        }
    }

    func completeTOTP(server: URL? = nil, challengeID: String, code: String, recoveryCode: String = "") async throws -> LatticeLoginSession {
        guard let url = server ?? serverURL else { throw LatticeAPIError.invalidURL("") }
        return try await sessionProbe(url).loginTOTP(challengeID: challengeID, code: code, recoveryCode: recoveryCode)
    }

    /// Takes a signed-in session. Without a PAT it becomes the only
    /// credential; with one it is the reveal session.
    func adopt(_ session: LatticeLoginSession, server: URL? = nil) async throws {
        guard let url = server ?? serverURL else { throw LatticeAPIError.invalidURL("") }
        let sessionClient = makeClient(url, session.credential, kind: .session)
        let identity = try await sessionClient.fetchIdentity()
        if client == nil, !isDemo {
            UserDefaults.standard.set(url.absoluteString, forKey: Key.serverURL)
            UserDefaults.standard.set(CredentialKind.session.rawValue, forKey: Key.credentialKind)
            serverURL = url
            credentialKind = .session
            client = makeClient(url, session.credential, kind: .primary)
            primaryIdentity = identity
            generation += 1
            serverVersion = try? await sessionClient.fetchServerVersion()
        }
        remember(identity)
        revealClient = sessionClient
        sessionIdentity = identity
        revealSession = session
        sessionExpired = false
        if keepSession, !isDemo { try? KeychainStore.saveSession(session) }
    }

    /// Loads the kept session (after Face ID) when a reveal needs it.
    func loadKeptSessionIfNeeded() async {
        guard revealClient == nil, keepSession, !isDemo,
              let session = await KeychainStore.loadSession(reason: "Use your signed-in session for reveals") else { return }
        try? await adopt(session)
    }

    /// Ends the reveal session: `POST /api/logout`, then forgets it. A session
    /// that is the only credential is ended by Sign out instead.
    func endRevealSession() async {
        guard credentialKind == .token, let revealClient else { return }
        if !isDemo { try? await revealClient.logout() }
        self.revealClient = nil
        sessionIdentity = nil
        revealSession = nil
        if !isDemo { KeychainStore.deleteSession() }
    }

    // MARK: Demo

    func enterDemo(scenario: DemoScenario, clock: DemoClock = DemoClock()) {
        isDemo = true
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundRefresh.identifier)
        demoKeepSession = false
        demoEndSessionAfterReveal = true
        demoScenario = scenario
        demoClock = clock
        demoState = DemoState()
        serverURL = DemoWorld.baseURL
        credentialKind = .token
        client = demoClient(.pat, kind: .primary, credential: LatticeCredential(bearerToken: DemoWorld.token))
        if case .noSession = scenario {
            revealClient = nil
        } else {
            revealClient = demoClient(.session, kind: .session, credential: LatticeCredential(sessionCookie: "demo-session", csrfToken: "demo-csrf"))
            revealSession = LatticeLoginSession(sessionCookie: "demo-session", csrfToken: "demo-csrf", actorID: "demo-operator", expiresAt: clock.anchor.addingTimeInterval(12 * 3600))
        }
        if case .offline = scenario {
            network.use(DemoPathSource(satisfied: false))
        } else {
            network.use(DemoPathSource(satisfied: true))
        }
        primaryIdentity = nil
        sessionIdentity = nil
        generation += 1
        Task { await refreshIdentity() }
    }

    func setDemoScenario(_ scenario: DemoScenario) {
        guard isDemo else { return }
        enterDemo(scenario: scenario, clock: demoClock)
    }

    func setDemoClockPinned(_ pinned: Bool) {
        guard isDemo else { return }
        enterDemo(scenario: demoScenario, clock: DemoClock(anchor: demoClock.anchor, isPinned: pinned))
    }

    // MARK: Refresh

    /// Re-reads `/api/me` on each client and `/api/version`.
    func refreshIdentity() async {
        if let client {
            do {
                primaryIdentity = try await client.fetchIdentity()
                identityError = nil
            } catch {
                identityError = LatticeAPIError(error)
            }
            serverVersion = (try? await client.fetchServerVersion()) ?? serverVersion
        }
        if let revealClient {
            // A failed read keeps the last identity, so a passing network
            // error does not read as signed out; only a 401 clears it.
            do {
                sessionIdentity = try await revealClient.fetchIdentity()
            } catch {
                if case .unauthorized = LatticeAPIError(error) { sessionIdentity = nil }
            }
        }
    }

    /// A 403 after load: the scopes may have changed (section 6.7).
    func noteForbidden() {
        Task { await refreshIdentity() }
    }

    func markCompanionBehind(_ surface: String) {
        companionBehind.insert(surface)
    }

    // MARK: Sign out

    /// Ends any session, deletes both Keychain items, clears the badge and
    /// every credential-bound value (section 7.2).
    func signOut() async {
        if !isDemo {
            if let revealClient { try? await revealClient.logout() }
            if credentialKind == .session, revealClient == nil, let client { try? await client.logout() }
            KeychainStore.deleteAll()
            UserDefaults.standard.removeObject(forKey: Key.credentialKind)
            UserDefaults.standard.removeObject(forKey: Key.actorID)
            UserDefaults.standard.removeObject(forKey: Key.username)
        }
        try? await UNUserNotificationCenter.current().setBadgeCount(0)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundRefresh.identifier)
        resetState()
        network.use(SystemPathSource())
    }

    /// Leaves demo mode without touching the Keychain. A server and token
    /// stored before demo mode come back; without them the welcome flow shows.
    func leaveDemo() {
        resetState()
        restore(launch: LaunchOverrides())
    }

    private func resetState() {
        client = nil
        revealClient = nil
        primaryIdentity = nil
        sessionIdentity = nil
        revealSession = nil
        credentialKind = nil
        serverVersion = nil
        identityError = nil
        tokenRejected = false
        sessionExpired = false
        companionBehind = []
        isDemo = false
        serverURL = UserDefaults.standard.string(forKey: Key.serverURL).flatMap(URL.init(string:))
        generation += 1
        Task { await diagnostics.clear() }
    }

    // MARK: Plumbing

    private func remember(_ identity: LatticeIdentity) {
        UserDefaults.standard.set(identity.actorID, forKey: Key.actorID)
        UserDefaults.standard.set(identity.username, forKey: Key.username)
    }

    private func sessionProbe(_ url: URL) -> LatticeClient {
        makeClient(url, LatticeCredential(), kind: .session)
    }

    /// Every client built while demo is on talks to DemoTransport, so a
    /// typed username, password or code never leaves the sandbox.
    private func makeClient(_ url: URL, _ credential: LatticeCredential, kind: ClientKind) -> LatticeClient {
        if isDemo {
            return demoClient(kind == .primary ? .pat : .session, kind: kind, credential: credential)
        }
        return LatticeClient(baseURL: url, credential: credential, transport: DiagnosticsTransport(
            base: URLSession.shared, log: diagnostics, kind: kind, isDemo: false, onStatus: statusHandler()
        ))
    }

    private func demoClient(_ identity: DemoIdentity, kind: ClientKind, credential: LatticeCredential) -> LatticeClient {
        let transport = DemoTransport(identity: identity, scenario: demoScenario, token: demoToken, clock: demoClock, state: demoState)
        return LatticeClient(baseURL: DemoWorld.baseURL, credential: credential, transport: DiagnosticsTransport(
            base: transport, log: diagnostics, kind: kind, isDemo: true, onStatus: statusHandler()
        ))
    }

    /// A 401 on the primary client is a rejected token; on the session it is
    /// an expired session, except from step-up, where it is a wrong code.
    private func statusHandler() -> @Sendable (ClientKind, Int, String) -> Void {
        { [weak self] kind, status, path in
            guard status == 401 else { return }
            Task { @MainActor in
                guard let self else { return }
                switch kind {
                case .primary where !path.hasSuffix("/api/login") && !path.hasSuffix("/api/login/totp"):
                    self.tokenRejected = true
                case .session where !path.hasSuffix("/api/security/step-up") && !path.hasSuffix("/api/login") && !path.hasSuffix("/api/login/totp"):
                    self.sessionExpired = true
                default:
                    break
                }
            }
        }
    }
}
