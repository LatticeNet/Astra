import Foundation
import Security

struct AppSettings: Codable, Equatable {
    var latticeBaseURL: String
    var pollInterval: Double
    var offlineTimeout: Double
    var alertCooldown: Double
    var cpuCritical: Double
    var memoryCritical: Double
    var diskCritical: Double
    var notificationsEnabled: Bool
    var backgroundRefreshEnabled: Bool
    var barkServerURL: String
    var barkGroup: String
    var barkSound: String
    var barkLevel: BarkInterruptionLevel

    init(
        latticeBaseURL: String,
        pollInterval: Double,
        offlineTimeout: Double,
        alertCooldown: Double,
        cpuCritical: Double,
        memoryCritical: Double,
        diskCritical: Double,
        notificationsEnabled: Bool,
        backgroundRefreshEnabled: Bool,
        barkServerURL: String,
        barkGroup: String,
        barkSound: String,
        barkLevel: BarkInterruptionLevel
    ) {
        self.latticeBaseURL = latticeBaseURL
        self.pollInterval = pollInterval
        self.offlineTimeout = offlineTimeout
        self.alertCooldown = alertCooldown
        self.cpuCritical = cpuCritical
        self.memoryCritical = memoryCritical
        self.diskCritical = diskCritical
        self.notificationsEnabled = notificationsEnabled
        self.backgroundRefreshEnabled = backgroundRefreshEnabled
        self.barkServerURL = barkServerURL
        self.barkGroup = barkGroup
        self.barkSound = barkSound
        self.barkLevel = barkLevel
    }

    enum CodingKeys: String, CodingKey {
        case latticeBaseURL
        case legacyNezhaBaseURL = "nezhaBaseURL"
        case pollInterval
        case offlineTimeout
        case alertCooldown
        case cpuCritical
        case memoryCritical
        case diskCritical
        case notificationsEnabled
        case backgroundRefreshEnabled
        case barkServerURL
        case barkGroup
        case barkSound
        case barkLevel
    }

    init(from decoder: Decoder) throws {
        let defaults = AppSettings.defaults
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latticeBaseURL = try container.decodeIfPresent(String.self, forKey: .latticeBaseURL)
            ?? container.decodeIfPresent(String.self, forKey: .legacyNezhaBaseURL)
            ?? defaults.latticeBaseURL
        pollInterval = try container.decodeIfPresent(Double.self, forKey: .pollInterval) ?? defaults.pollInterval
        offlineTimeout = try container.decodeIfPresent(Double.self, forKey: .offlineTimeout) ?? defaults.offlineTimeout
        alertCooldown = try container.decodeIfPresent(Double.self, forKey: .alertCooldown) ?? defaults.alertCooldown
        cpuCritical = try container.decodeIfPresent(Double.self, forKey: .cpuCritical) ?? defaults.cpuCritical
        memoryCritical = try container.decodeIfPresent(Double.self, forKey: .memoryCritical) ?? defaults.memoryCritical
        diskCritical = try container.decodeIfPresent(Double.self, forKey: .diskCritical) ?? defaults.diskCritical
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? defaults.notificationsEnabled
        backgroundRefreshEnabled = try container.decodeIfPresent(Bool.self, forKey: .backgroundRefreshEnabled) ?? defaults.backgroundRefreshEnabled
        barkServerURL = try container.decodeIfPresent(String.self, forKey: .barkServerURL) ?? defaults.barkServerURL
        barkGroup = try container.decodeIfPresent(String.self, forKey: .barkGroup) ?? defaults.barkGroup
        barkSound = try container.decodeIfPresent(String.self, forKey: .barkSound) ?? defaults.barkSound
        barkLevel = try container.decodeIfPresent(BarkInterruptionLevel.self, forKey: .barkLevel) ?? defaults.barkLevel
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(latticeBaseURL, forKey: .latticeBaseURL)
        try container.encode(pollInterval, forKey: .pollInterval)
        try container.encode(offlineTimeout, forKey: .offlineTimeout)
        try container.encode(alertCooldown, forKey: .alertCooldown)
        try container.encode(cpuCritical, forKey: .cpuCritical)
        try container.encode(memoryCritical, forKey: .memoryCritical)
        try container.encode(diskCritical, forKey: .diskCritical)
        try container.encode(notificationsEnabled, forKey: .notificationsEnabled)
        try container.encode(backgroundRefreshEnabled, forKey: .backgroundRefreshEnabled)
        try container.encode(barkServerURL, forKey: .barkServerURL)
        try container.encode(barkGroup, forKey: .barkGroup)
        try container.encode(barkSound, forKey: .barkSound)
        try container.encode(barkLevel, forKey: .barkLevel)
    }

    static let defaults = AppSettings(
        latticeBaseURL: "",
        pollInterval: 30,
        offlineTimeout: 180,
        alertCooldown: 600,
        cpuCritical: 90,
        memoryCritical: 90,
        diskCritical: 90,
        notificationsEnabled: true,
        backgroundRefreshEnabled: true,
        barkServerURL: "http://bark.roobli.org",
        barkGroup: "Lattice",
        barkSound: "minuet",
        barkLevel: .timeSensitive
    )

    var monitorConfiguration: MonitorConfiguration {
        MonitorConfiguration(
            offlineTimeout: offlineTimeout,
            alertCooldown: alertCooldown,
            cpuCritical: cpuCritical,
            memoryCritical: memoryCritical,
            diskCritical: diskCritical
        )
    }
}

enum SettingsStore {
    private static let key = "astra.settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .defaults
        }
        return settings
    }

    static func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum MonitorEngineStateStore {
    private static let key = "astra.monitorEngineState.v1"

    static func load() -> MonitorEngineState {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(MonitorEngineState.self, from: data)
        else {
            return MonitorEngineState()
        }
        return state
    }

    static func save(_ state: MonitorEngineState) {
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum EventStore {
    private static let key = "astra.events.v1"

    static func load() -> [MonitorEvent] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let events = try? JSONDecoder().decode([MonitorEvent].self, from: data)
        else {
            return []
        }
        return events
    }

    static func save(_ events: [MonitorEvent]) {
        let trimmed = Array(events.prefix(100))
        guard let data = try? JSONEncoder().encode(trimmed) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum NodeStore {
    private static let key = "astra.nodes.v1"

    struct Snapshot: Codable, Equatable {
        var nodes: [LatticeNode]
        var refreshedAt: Date?
    }

    static func load() -> Snapshot {
        guard let data = UserDefaults.standard.data(forKey: key),
              !data.isEmpty
        else {
            return Snapshot(nodes: [], refreshedAt: nil)
        }

        let decoder = JSONDecoder()
        if let snapshot = try? decoder.decode(Snapshot.self, from: data) {
            return snapshot
        }
        if let nodes = try? decoder.decode([LatticeNode].self, from: data) {
            return Snapshot(nodes: nodes, refreshedAt: nil)
        }
        return Snapshot(nodes: [], refreshedAt: nil)
    }

    static func save(_ nodes: [LatticeNode], refreshedAt: Date = Date()) {
        let snapshot = Snapshot(nodes: nodes, refreshedAt: refreshedAt)
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}

struct BackgroundRefreshStatus: Codable, Equatable {
    var lastStartedAt: Date?
    var lastCompletedAt: Date?
    var lastSuccess: Bool?
    var lastError: String?

    static let empty = BackgroundRefreshStatus(
        lastStartedAt: nil,
        lastCompletedAt: nil,
        lastSuccess: nil,
        lastError: nil
    )
}

enum BackgroundRefreshStatusStore {
    private static let key = "astra.backgroundRefreshStatus.v1"

    static func load() -> BackgroundRefreshStatus {
        guard let data = UserDefaults.standard.data(forKey: key),
              let status = try? JSONDecoder().decode(BackgroundRefreshStatus.self, from: data)
        else {
            return .empty
        }
        return status
    }

    static func recordStarted(at date: Date = Date()) {
        var status = load()
        status.lastStartedAt = date
        status.lastCompletedAt = nil
        status.lastSuccess = nil
        status.lastError = nil
        save(status)
    }

    static func recordCompleted(success: Bool, error: String? = nil, at date: Date = Date()) {
        var status = load()
        status.lastCompletedAt = date
        status.lastSuccess = success
        status.lastError = error
        save(status)
    }

    private static func save(_ status: BackgroundRefreshStatus) {
        guard let data = try? JSONEncoder().encode(status) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum SecretStore {
    private static let service = "org.roobli.astra"

    static func load(_ account: String) -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        query.removeAll()
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return value
    }

    static func save(_ value: String, account: String) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard !trimmedValue.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(trimmedValue.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var create = query
            create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(create as CFDictionary, nil)
        }
    }
}

enum AppSecretAccount {
    static let latticeToken = "lattice.token"
    static let latticeSessionCookie = "lattice.sessionCookie"
    static let latticeCSRFToken = "lattice.csrfToken"
    static let barkDeviceKey = "bark.deviceKey"
}
