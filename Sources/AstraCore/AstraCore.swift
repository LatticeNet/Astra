import Foundation

public enum LatticeAPIError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL(String)
    case invalidResponse
    case serverError(String, String)
    case httpStatus(Int)
    case unauthorized
    case missingSessionCookie
    case totpRequired(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            "Invalid URL: \(value)"
        case .invalidResponse:
            "The Lattice response could not be decoded."
        case .serverError(let code, let message):
            message.isEmpty ? code : "\(code): \(message)"
        case .httpStatus(let status):
            "HTTP \(status)"
        case .unauthorized:
            "Lattice credentials are unauthorized or expired."
        case .missingSessionCookie:
            "Lattice login did not return a session cookie."
        case .totpRequired:
            "Lattice requires a TOTP code for this login."
        }
    }
}

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {}

public enum AstraURLNormalizer {
    public static func serviceURL(from rawValue: String, defaultScheme: String = "https") -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.contains("://") {
            return validatedHTTPURL(from: trimmed)
        }
        return validatedHTTPURL(from: "\(defaultScheme)://\(trimmed)")
    }

    public static func latticeDashboardURL(from rawValue: String) -> URL? {
        guard let serviceURL = serviceURL(from: rawValue),
              var components = URLComponents(url: serviceURL, resolvingAgainstBaseURL: false)
        else {
            return nil
        }

        let parts = components.path.pathComponentsForAstraJoin
        if let apiIndex = parts.firstIndex(of: "api") {
            let prefix = Array(parts[..<apiIndex])
            components.path = prefix.isEmpty ? "" : "/" + prefix.joined(separator: "/")
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func validatedHTTPURL(from value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else {
            return nil
        }
        return url
    }
}

public enum BarkDeviceKeyNormalizer {
    public static func deviceKey(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        if trimmed.contains("://"), let url = URL(string: trimmed) {
            return firstBarkPathComponent(in: url.path) ?? ""
        }
        if trimmed.contains("/") {
            return firstBarkPathComponent(in: trimmed) ?? ""
        }
        return trimmed
    }

    private static func firstBarkPathComponent(in path: String) -> String? {
        guard let first = path.split(separator: "/").first.map(String.init),
              first.lowercased() != "push"
        else {
            return nil
        }
        return first.removingPercentEncoding ?? first
    }
}

public struct LatticeGeo: Codable, Equatable, Hashable, Sendable {
    public var country: String?
    public var region: String?
    public var city: String?
    public var lat: Double?
    public var lon: Double?

    public init(country: String? = nil, region: String? = nil, city: String? = nil, lat: Double? = nil, lon: Double? = nil) {
        self.country = country
        self.region = region
        self.city = city
        self.lat = lat
        self.lon = lon
    }
}

public struct LatticeMetrics: Codable, Equatable, Hashable, Sendable {
    public var cpuPercent: Double
    public var load1: Double
    public var memoryUsed: UInt64
    public var memoryTotal: UInt64
    public var diskUsed: UInt64
    public var diskTotal: UInt64
    public var netRxBytes: UInt64
    public var netTxBytes: UInt64
    public var uptimeSeconds: UInt64
    public var collectedAt: Date?

    public init(
        cpuPercent: Double = 0,
        load1: Double = 0,
        memoryUsed: UInt64 = 0,
        memoryTotal: UInt64 = 0,
        diskUsed: UInt64 = 0,
        diskTotal: UInt64 = 0,
        netRxBytes: UInt64 = 0,
        netTxBytes: UInt64 = 0,
        uptimeSeconds: UInt64 = 0,
        collectedAt: Date? = nil
    ) {
        self.cpuPercent = cpuPercent
        self.load1 = load1
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.diskUsed = diskUsed
        self.diskTotal = diskTotal
        self.netRxBytes = netRxBytes
        self.netTxBytes = netTxBytes
        self.uptimeSeconds = uptimeSeconds
        self.collectedAt = collectedAt
    }

    enum CodingKeys: String, CodingKey {
        case cpuPercent = "cpu_percent"
        case load1
        case memoryUsed = "memory_used"
        case memoryTotal = "memory_total"
        case diskUsed = "disk_used"
        case diskTotal = "disk_total"
        case netRxBytes = "net_rx_bytes"
        case netTxBytes = "net_tx_bytes"
        case uptimeSeconds = "uptime_seconds"
        case collectedAt = "collected_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpuPercent = try container.decodeIfPresent(Double.self, forKey: .cpuPercent) ?? 0
        load1 = try container.decodeIfPresent(Double.self, forKey: .load1) ?? 0
        memoryUsed = try container.decodeIfPresent(UInt64.self, forKey: .memoryUsed) ?? 0
        memoryTotal = try container.decodeIfPresent(UInt64.self, forKey: .memoryTotal) ?? 0
        diskUsed = try container.decodeIfPresent(UInt64.self, forKey: .diskUsed) ?? 0
        diskTotal = try container.decodeIfPresent(UInt64.self, forKey: .diskTotal) ?? 0
        netRxBytes = try container.decodeIfPresent(UInt64.self, forKey: .netRxBytes) ?? 0
        netTxBytes = try container.decodeIfPresent(UInt64.self, forKey: .netTxBytes) ?? 0
        uptimeSeconds = try container.decodeIfPresent(UInt64.self, forKey: .uptimeSeconds) ?? 0
        collectedAt = try DateValue.decodeIfPresent(from: container, forKey: .collectedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cpuPercent, forKey: .cpuPercent)
        try container.encode(load1, forKey: .load1)
        try container.encode(memoryUsed, forKey: .memoryUsed)
        try container.encode(memoryTotal, forKey: .memoryTotal)
        try container.encode(diskUsed, forKey: .diskUsed)
        try container.encode(diskTotal, forKey: .diskTotal)
        try container.encode(netRxBytes, forKey: .netRxBytes)
        try container.encode(netTxBytes, forKey: .netTxBytes)
        try container.encode(uptimeSeconds, forKey: .uptimeSeconds)
        if let collectedAt {
            try container.encode(AstraDateParser.string(from: collectedAt), forKey: .collectedAt)
        }
    }
}

public struct LatticeHostFacts: Codable, Equatable, Hashable, Sendable {
    public var hostname: String?
    public var os: String?
    public var platform: String?
    public var platformVersion: String?
    public var kernelVersion: String?
    public var arch: String?
    public var cpuCores: Int
    public var cpuModel: String?
    public var memoryTotal: UInt64
    public var swapTotal: UInt64
    public var virtualization: String?
    public var bootTime: Date?
    public var reportedAt: Date?

    public init(
        hostname: String? = nil,
        os: String? = nil,
        platform: String? = nil,
        platformVersion: String? = nil,
        kernelVersion: String? = nil,
        arch: String? = nil,
        cpuCores: Int = 0,
        cpuModel: String? = nil,
        memoryTotal: UInt64 = 0,
        swapTotal: UInt64 = 0,
        virtualization: String? = nil,
        bootTime: Date? = nil,
        reportedAt: Date? = nil
    ) {
        self.hostname = hostname
        self.os = os
        self.platform = platform
        self.platformVersion = platformVersion
        self.kernelVersion = kernelVersion
        self.arch = arch
        self.cpuCores = cpuCores
        self.cpuModel = cpuModel
        self.memoryTotal = memoryTotal
        self.swapTotal = swapTotal
        self.virtualization = virtualization
        self.bootTime = bootTime
        self.reportedAt = reportedAt
    }

    enum CodingKeys: String, CodingKey {
        case hostname
        case os
        case platform
        case platformVersion = "platform_version"
        case kernelVersion = "kernel_version"
        case arch
        case cpuCores = "cpu_cores"
        case cpuModel = "cpu_model"
        case memoryTotal = "memory_total"
        case swapTotal = "swap_total"
        case virtualization
        case bootTime = "boot_time"
        case reportedAt = "reported_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
        os = try container.decodeIfPresent(String.self, forKey: .os)
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
        platformVersion = try container.decodeIfPresent(String.self, forKey: .platformVersion)
        kernelVersion = try container.decodeIfPresent(String.self, forKey: .kernelVersion)
        arch = try container.decodeIfPresent(String.self, forKey: .arch)
        cpuCores = try container.decodeIfPresent(Int.self, forKey: .cpuCores) ?? 0
        cpuModel = try container.decodeIfPresent(String.self, forKey: .cpuModel)
        memoryTotal = try container.decodeIfPresent(UInt64.self, forKey: .memoryTotal) ?? 0
        swapTotal = try container.decodeIfPresent(UInt64.self, forKey: .swapTotal) ?? 0
        virtualization = try container.decodeIfPresent(String.self, forKey: .virtualization)
        bootTime = try DateValue.decodeIfPresent(from: container, forKey: .bootTime)
        reportedAt = try DateValue.decodeIfPresent(from: container, forKey: .reportedAt)
    }
}

public struct LatticeNode: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var tags: [String]
    public var role: String?
    public var wireGuardIP: String?
    public var wireGuardPublicKey: String?
    public var wireGuardEndpoint: String?
    public var wireGuardPort: Int?
    public var publicIP: String?
    public var publicIPv6: String?
    public var agentVersion: String?
    public var online: Bool
    public var disabled: Bool
    public var lastSeen: Date?
    public var metrics: LatticeMetrics
    public var hostFacts: LatticeHostFacts
    public var geo: LatticeGeo?
    public var createdAt: Date?

    public init(
        id: String,
        name: String,
        tags: [String] = [],
        role: String? = nil,
        wireGuardIP: String? = nil,
        wireGuardPublicKey: String? = nil,
        wireGuardEndpoint: String? = nil,
        wireGuardPort: Int? = nil,
        publicIP: String? = nil,
        publicIPv6: String? = nil,
        agentVersion: String? = nil,
        online: Bool = false,
        disabled: Bool = false,
        lastSeen: Date? = nil,
        metrics: LatticeMetrics = LatticeMetrics(),
        hostFacts: LatticeHostFacts = LatticeHostFacts(),
        geo: LatticeGeo? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.tags = tags
        self.role = role
        self.wireGuardIP = wireGuardIP
        self.wireGuardPublicKey = wireGuardPublicKey
        self.wireGuardEndpoint = wireGuardEndpoint
        self.wireGuardPort = wireGuardPort
        self.publicIP = publicIP
        self.publicIPv6 = publicIPv6
        self.agentVersion = agentVersion
        self.online = online
        self.disabled = disabled
        self.lastSeen = lastSeen
        self.metrics = metrics
        self.hostFacts = hostFacts
        self.geo = geo
        self.createdAt = createdAt
    }

    public var displayName: String {
        name.isEmpty ? id : name
    }

    public var memoryUsedFraction: Double? {
        fraction(used: metrics.memoryUsed, total: metrics.memoryTotal > 0 ? metrics.memoryTotal : hostFacts.memoryTotal)
    }

    public var diskUsedFraction: Double? {
        fraction(used: metrics.diskUsed, total: metrics.diskTotal)
    }

    public var availabilityText: String {
        if disabled {
            return "Disabled"
        }
        return isOffline(timeout: 0) ? "Offline" : "Online"
    }

    public func isOffline(referenceDate: Date = Date(), timeout: TimeInterval) -> Bool {
        if disabled || !online {
            return true
        }
        guard let lastSeen else {
            return true
        }
        return timeout > 0 && referenceDate.timeIntervalSince(lastSeen) > timeout
    }

    private func fraction(used: UInt64, total: UInt64) -> Double? {
        guard total > 0 else {
            return nil
        }
        return Double(used) / Double(total)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case tags
        case role
        case wireGuardIP = "wireguard_ip"
        case wireGuardPublicKey = "wireguard_public_key"
        case wireGuardEndpoint = "wireguard_endpoint"
        case wireGuardPort = "wireguard_port"
        case publicIP = "public_ip"
        case publicIPv6 = "public_ipv6"
        case agentVersion = "agent_version"
        case online
        case disabled
        case lastSeen = "last_seen"
        case metrics
        case hostFacts = "host_facts"
        case geo
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        role = try container.decodeIfPresent(String.self, forKey: .role)
        wireGuardIP = try container.decodeIfPresent(String.self, forKey: .wireGuardIP)
        wireGuardPublicKey = try container.decodeIfPresent(String.self, forKey: .wireGuardPublicKey)
        wireGuardEndpoint = try container.decodeIfPresent(String.self, forKey: .wireGuardEndpoint)
        wireGuardPort = try container.decodeIfPresent(Int.self, forKey: .wireGuardPort)
        publicIP = try container.decodeIfPresent(String.self, forKey: .publicIP)
        publicIPv6 = try container.decodeIfPresent(String.self, forKey: .publicIPv6)
        agentVersion = try container.decodeIfPresent(String.self, forKey: .agentVersion)
        online = try container.decodeIfPresent(Bool.self, forKey: .online) ?? false
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        lastSeen = try DateValue.decodeIfPresent(from: container, forKey: .lastSeen)
        metrics = try container.decodeIfPresent(LatticeMetrics.self, forKey: .metrics) ?? LatticeMetrics()
        hostFacts = try container.decodeIfPresent(LatticeHostFacts.self, forKey: .hostFacts) ?? LatticeHostFacts()
        geo = try container.decodeIfPresent(LatticeGeo.self, forKey: .geo)
        createdAt = try DateValue.decodeIfPresent(from: container, forKey: .createdAt)
    }
}

private struct LatticeErrorEnvelope: Decodable {
    var error: LatticeAPIErrorBody
}

private struct LatticeAPIErrorBody: Decodable {
    var code: String
    var message: String
    var requestID: String?

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case requestID = "request_id"
    }
}

public enum LatticeDecoder {
    public static func decodeNodes(from data: Data) throws -> [LatticeNode] {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(LatticeErrorEnvelope.self, from: data) {
            if envelope.error.code == "unauthorized" {
                throw LatticeAPIError.unauthorized
            }
            throw LatticeAPIError.serverError(envelope.error.code, envelope.error.message)
        }
        if let nodes = try? decoder.decode([LatticeNode].self, from: data) {
            return nodes.sortedByID()
        }
        throw LatticeAPIError.invalidResponse
    }

    static func decodeLogin(from data: Data) throws -> LatticeLoginResponse {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(LatticeErrorEnvelope.self, from: data) {
            if envelope.error.code == "unauthorized" {
                throw LatticeAPIError.unauthorized
            }
            throw LatticeAPIError.serverError(envelope.error.code, envelope.error.message)
        }
        if let response = try? decoder.decode(LatticeLoginResponse.self, from: data) {
            return response
        }
        throw LatticeAPIError.invalidResponse
    }
}

private extension Array where Element == LatticeNode {
    func sortedByID() -> [LatticeNode] {
        sorted {
            $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }
}

public struct LatticeCredential: Codable, Equatable, Hashable, Sendable {
    public var bearerToken: String
    public var sessionCookie: String
    public var csrfToken: String

    public init(bearerToken: String = "", sessionCookie: String = "", csrfToken: String = "") {
        self.bearerToken = bearerToken
        self.sessionCookie = sessionCookie
        self.csrfToken = csrfToken
    }

    public var hasAuthentication: Bool {
        !bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !sessionCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct LatticeLoginRequest: Encodable {
    var username: String
    var password: String
}

private struct LatticeTOTPRequest: Encodable {
    var challengeID: String
    var code: String
    var recoveryCode: String

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case code
        case recoveryCode = "recovery_code"
    }
}

public struct LatticeLoginResponse: Codable, Equatable, Hashable, Sendable {
    public var csrfToken: String?
    public var actorID: String?
    public var totpRequired: Bool
    public var challengeID: String?

    enum CodingKeys: String, CodingKey {
        case csrfToken = "csrf_token"
        case actorID = "actor_id"
        case totpRequired = "totp_required"
        case challengeID = "challenge_id"
    }

    public init(csrfToken: String? = nil, actorID: String? = nil, totpRequired: Bool = false, challengeID: String? = nil) {
        self.csrfToken = csrfToken
        self.actorID = actorID
        self.totpRequired = totpRequired
        self.challengeID = challengeID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        csrfToken = try container.decodeIfPresent(String.self, forKey: .csrfToken)
        actorID = try container.decodeIfPresent(String.self, forKey: .actorID)
        totpRequired = try container.decodeIfPresent(Bool.self, forKey: .totpRequired) ?? false
        challengeID = try container.decodeIfPresent(String.self, forKey: .challengeID)
    }
}

public struct LatticeLoginSession: Codable, Equatable, Hashable, Sendable {
    public var sessionCookie: String
    public var csrfToken: String
    public var actorID: String?

    public init(sessionCookie: String, csrfToken: String, actorID: String? = nil) {
        self.sessionCookie = sessionCookie
        self.csrfToken = csrfToken
        self.actorID = actorID
    }

    public var credential: LatticeCredential {
        LatticeCredential(sessionCookie: sessionCookie, csrfToken: csrfToken)
    }
}

public struct LatticeClient: Sendable {
    public var baseURL: URL
    public var credential: LatticeCredential
    public var timeout: TimeInterval
    private let transport: any HTTPTransport

    public init(
        baseURL: URL,
        credential: LatticeCredential = LatticeCredential(),
        timeout: TimeInterval = 15,
        transport: any HTTPTransport = URLSession.shared
    ) {
        self.baseURL = baseURL
        self.credential = credential
        self.timeout = timeout
        self.transport = transport
    }

    public func fetchNodes() async throws -> [LatticeNode] {
        let request = try buildRequest(path: "/api/nodes")
        let (data, response) = try await transport.data(for: request)
        try validate(response: response, data: data)
        return try LatticeDecoder.decodeNodes(from: data)
    }

    public func login(username: String, password: String) async throws -> LatticeLoginSession {
        let request = try buildLoginRequest(username: username, password: password)
        let (data, response) = try await transport.data(for: request)
        try validate(response: response, data: data)
        let login = try LatticeDecoder.decodeLogin(from: data)
        if login.totpRequired {
            throw LatticeAPIError.totpRequired(login.challengeID ?? "")
        }
        return try session(from: login, response: response)
    }

    public func loginTOTP(challengeID: String, code: String, recoveryCode: String = "") async throws -> LatticeLoginSession {
        let request = try buildTOTPRequest(challengeID: challengeID, code: code, recoveryCode: recoveryCode)
        let (data, response) = try await transport.data(for: request)
        try validate(response: response, data: data)
        let login = try LatticeDecoder.decodeLogin(from: data)
        return try session(from: login, response: response)
    }

    public func buildRequest(path: String, method: String = "GET") throws -> URLRequest {
        guard let url = baseURL.latticeAPIBaseURL.appendingAstraPath(path) else {
            throw LatticeAPIError.invalidURL(baseURL.absoluteString + path)
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuthentication(to: &request)
        return request
    }

    public func buildLoginRequest(username: String, password: String) throws -> URLRequest {
        guard let url = baseURL.latticeAPIBaseURL.appendingAstraPath("/api/login") else {
            throw LatticeAPIError.invalidURL(baseURL.absoluteString + "/api/login")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(LatticeLoginRequest(username: username, password: password))
        return request
    }

    public func buildTOTPRequest(challengeID: String, code: String, recoveryCode: String = "") throws -> URLRequest {
        guard let url = baseURL.latticeAPIBaseURL.appendingAstraPath("/api/login/totp") else {
            throw LatticeAPIError.invalidURL(baseURL.absoluteString + "/api/login/totp")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(LatticeTOTPRequest(challengeID: challengeID, code: code, recoveryCode: recoveryCode))
        return request
    }

    private func applyAuthentication(to request: inout URLRequest) {
        let bearer = credential.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            return
        }

        let session = credential.sessionCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if !session.isEmpty {
            request.setValue("lattice_session=\(session)", forHTTPHeaderField: "Cookie")
        }
        let csrf = credential.csrfToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !csrf.isEmpty {
            request.setValue(csrf, forHTTPHeaderField: "X-Lattice-CSRF")
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            return
        }
        guard (200...299).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(LatticeErrorEnvelope.self, from: data) {
                if envelope.error.code == "unauthorized" || http.statusCode == 401 {
                    throw LatticeAPIError.unauthorized
                }
                throw LatticeAPIError.serverError(envelope.error.code, envelope.error.message)
            }
            if http.statusCode == 401 {
                throw LatticeAPIError.unauthorized
            }
            throw LatticeAPIError.httpStatus(http.statusCode)
        }
    }

    private func session(from response: LatticeLoginResponse, response urlResponse: URLResponse) throws -> LatticeLoginSession {
        guard let csrf = response.csrfToken?.trimmingCharacters(in: .whitespacesAndNewlines), !csrf.isEmpty else {
            throw LatticeAPIError.invalidResponse
        }
        guard let sessionCookie = Self.sessionCookie(from: urlResponse) else {
            throw LatticeAPIError.missingSessionCookie
        }
        return LatticeLoginSession(sessionCookie: sessionCookie, csrfToken: csrf, actorID: response.actorID)
    }

    private static func sessionCookie(from response: URLResponse) -> String? {
        guard let http = response as? HTTPURLResponse else {
            return nil
        }
        for (key, value) in http.allHeaderFields {
            guard String(describing: key).lowercased() == "set-cookie",
                  let cookieHeader = value as? String
            else {
                continue
            }
            for part in cookieHeader.components(separatedBy: ",") {
                let fields = part.components(separatedBy: ";")
                guard let first = fields.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                      first.hasPrefix("lattice_session=")
                else {
                    continue
                }
                let value = String(first.dropFirst("lattice_session=".count))
                if !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }
}

public struct MonitorConfiguration: Codable, Equatable, Hashable, Sendable {
    public var offlineTimeout: TimeInterval
    public var alertCooldown: TimeInterval
    public var cpuCritical: Double
    public var memoryCritical: Double
    public var diskCritical: Double

    public init(
        offlineTimeout: TimeInterval = 180,
        alertCooldown: TimeInterval = 600,
        cpuCritical: Double = 90,
        memoryCritical: Double = 90,
        diskCritical: Double = 90
    ) {
        self.offlineTimeout = offlineTimeout
        self.alertCooldown = alertCooldown
        self.cpuCritical = cpuCritical
        self.memoryCritical = memoryCritical
        self.diskCritical = diskCritical
    }
}

public enum MonitorEventKind: String, Codable, Equatable, Hashable, CaseIterable, Sendable {
    case offline
    case recovered
    case cpuCritical
    case memoryCritical
    case diskCritical
}

public struct MonitorEvent: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var occurrenceID: String
    public var nodeID: String
    public var nodeName: String
    public var kind: MonitorEventKind
    public var title: String
    public var body: String
    public var date: Date

    public init(
        id: String,
        occurrenceID: String = UUID().uuidString,
        nodeID: String,
        nodeName: String,
        kind: MonitorEventKind,
        title: String,
        body: String,
        date: Date
    ) {
        self.id = id
        self.occurrenceID = occurrenceID
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.kind = kind
        self.title = title
        self.body = body
        self.date = date
    }

    public var timelineID: String {
        "\(id).\(occurrenceID)"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case occurrenceID = "occurrence_id"
        case nodeID = "node_id"
        case nodeName = "node_name"
        case legacyServerID = "serverID"
        case legacyServerName = "serverName"
        case kind
        case title
        case body
        case date
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        occurrenceID = try container.decodeIfPresent(String.self, forKey: .occurrenceID) ?? UUID().uuidString
        if let value = try container.decodeIfPresent(String.self, forKey: .nodeID) {
            nodeID = value
        } else if let value = try container.decodeIfPresent(UInt64.self, forKey: .legacyServerID) {
            nodeID = String(value)
        } else {
            nodeID = ""
        }
        nodeName = try container.decodeIfPresent(String.self, forKey: .nodeName)
            ?? container.decodeIfPresent(String.self, forKey: .legacyServerName)
            ?? nodeID
        kind = try container.decode(MonitorEventKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        date = try DateValue.decodeRequired(from: container, forKey: .date)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(occurrenceID, forKey: .occurrenceID)
        try container.encode(nodeID, forKey: .nodeID)
        try container.encode(nodeName, forKey: .nodeName)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encode(AstraDateParser.string(from: date), forKey: .date)
    }
}

public struct MonitorEngineState: Codable, Equatable, Hashable, Sendable {
    public var lastSentAt: [String: Date]
    public var activeAlertIDs: Set<String>

    public init(lastSentAt: [String: Date] = [:], activeAlertIDs: Set<String> = []) {
        self.lastSentAt = lastSentAt
        self.activeAlertIDs = activeAlertIDs
    }
}

public struct MonitorEngine: Sendable {
    public var configuration: MonitorConfiguration
    private var lastSentAt: [String: Date]
    private var activeAlertIDs: Set<String>

    public init(
        configuration: MonitorConfiguration = MonitorConfiguration(),
        lastSentAt: [String: Date] = [:],
        activeAlertIDs: Set<String> = []
    ) {
        self.configuration = configuration
        self.lastSentAt = lastSentAt
        self.activeAlertIDs = activeAlertIDs
    }

    public init(configuration: MonitorConfiguration = MonitorConfiguration(), state: MonitorEngineState) {
        self.configuration = configuration
        self.lastSentAt = state.lastSentAt
        self.activeAlertIDs = state.activeAlertIDs
    }

    public var state: MonitorEngineState {
        MonitorEngineState(lastSentAt: lastSentAt, activeAlertIDs: activeAlertIDs)
    }

    public mutating func markDeliveryFailed(events: [MonitorEvent]) {
        for event in events {
            lastSentAt.removeValue(forKey: event.id)
        }
    }

    public mutating func evaluate(nodes: [LatticeNode], now: Date = Date()) -> [MonitorEvent] {
        var events: [MonitorEvent] = []
        removeMissingNodeState(currentAlertPrefixes: Set(nodes.map { alertPrefix(for: $0) }))

        for node in nodes {
            let previousNodeAlerts = activeAlertIDs.filter { $0.hasPrefix(alertPrefix(for: node)) }
            var currentNodeAlerts = Set<String>()

            let candidates = alertCandidates(for: node, now: now)
            for candidate in candidates {
                currentNodeAlerts.insert(candidate.id)
                activeAlertIDs.insert(candidate.id)
                if shouldSendAlert(id: candidate.id, now: now) {
                    lastSentAt[candidate.id] = now
                    events.append(candidate)
                }
            }

            for cleared in previousNodeAlerts.subtracting(currentNodeAlerts) {
                activeAlertIDs.remove(cleared)
            }

            if !previousNodeAlerts.isEmpty && currentNodeAlerts.isEmpty {
                let recoveryID = "\(alertPrefix(for: node))recovered"
                if shouldSendAlert(id: recoveryID, now: now) {
                    lastSentAt[recoveryID] = now
                    events.append(MonitorEvent(
                        id: recoveryID,
                        nodeID: node.id,
                        nodeName: node.displayName,
                        kind: .recovered,
                        title: "\(node.displayName) recovered",
                        body: "\(node.displayName) is back within the configured Lattice thresholds.",
                        date: now
                    ))
                }
            }
        }

        return events
    }

    private func alertCandidates(for node: LatticeNode, now: Date) -> [MonitorEvent] {
        var events: [MonitorEvent] = []

        if node.isOffline(referenceDate: now, timeout: configuration.offlineTimeout) {
            let body: String
            if node.disabled {
                body = "\(node.displayName) is disabled in Lattice."
            } else if !node.online {
                body = "\(node.displayName) is marked offline by Lattice."
            } else {
                body = "\(node.displayName) has not reported for \(DurationFormatter.seconds(configuration.offlineTimeout))."
            }
            events.append(MonitorEvent(
                id: "\(alertPrefix(for: node))offline",
                nodeID: node.id,
                nodeName: node.displayName,
                kind: .offline,
                title: "\(node.displayName) offline",
                body: body,
                date: now
            ))
            return events
        }

        if node.metrics.cpuPercent >= configuration.cpuCritical {
            events.append(MonitorEvent(
                id: "\(alertPrefix(for: node))cpu",
                nodeID: node.id,
                nodeName: node.displayName,
                kind: .cpuCritical,
                title: "\(node.displayName) CPU high",
                body: "CPU \(PercentFormatter.percent(node.metrics.cpuPercent)) exceeds \(PercentFormatter.percent(configuration.cpuCritical)).",
                date: now
            ))
        }

        if let memory = node.memoryUsedFraction.map({ $0 * 100 }), memory >= configuration.memoryCritical {
            events.append(MonitorEvent(
                id: "\(alertPrefix(for: node))memory",
                nodeID: node.id,
                nodeName: node.displayName,
                kind: .memoryCritical,
                title: "\(node.displayName) memory high",
                body: "Memory \(PercentFormatter.percent(memory)) exceeds \(PercentFormatter.percent(configuration.memoryCritical)).",
                date: now
            ))
        }

        if let disk = node.diskUsedFraction.map({ $0 * 100 }), disk >= configuration.diskCritical {
            events.append(MonitorEvent(
                id: "\(alertPrefix(for: node))disk",
                nodeID: node.id,
                nodeName: node.displayName,
                kind: .diskCritical,
                title: "\(node.displayName) disk high",
                body: "Disk \(PercentFormatter.percent(disk)) exceeds \(PercentFormatter.percent(configuration.diskCritical)).",
                date: now
            ))
        }

        return events
    }

    private func shouldSendAlert(id: String, now: Date) -> Bool {
        guard let lastSent = lastSentAt[id] else {
            return true
        }
        return now.timeIntervalSince(lastSent) >= configuration.alertCooldown
    }

    private func alertPrefix(for node: LatticeNode) -> String {
        "node-\(node.id)."
    }

    private mutating func removeMissingNodeState(currentAlertPrefixes: Set<String>) {
        let staleActiveAlertIDs = activeAlertIDs.filter { alertID in
            guard let prefix = alertPrefix(from: alertID) else {
                return false
            }
            return !currentAlertPrefixes.contains(prefix)
        }
        for alertID in staleActiveAlertIDs {
            activeAlertIDs.remove(alertID)
        }

        let staleSentAlertIDs = lastSentAt.keys.filter { alertID in
            guard let prefix = alertPrefix(from: alertID) else {
                return false
            }
            return !currentAlertPrefixes.contains(prefix)
        }
        for alertID in staleSentAlertIDs {
            lastSentAt.removeValue(forKey: alertID)
        }
    }

    private func alertPrefix(from alertID: String) -> String? {
        guard let dotIndex = alertID.firstIndex(of: ".") else {
            return nil
        }
        return String(alertID[...dotIndex])
    }
}

public struct BarkConfiguration: Codable, Equatable, Hashable, Sendable {
    public var serverURL: URL
    public var deviceKey: String
    public var defaultGroup: String
    public var sound: String?
    public var icon: URL?
    public var url: URL?
    public var level: BarkInterruptionLevel

    public init(
        serverURL: URL,
        deviceKey: String,
        defaultGroup: String = "Lattice",
        sound: String? = nil,
        icon: URL? = nil,
        url: URL? = nil,
        level: BarkInterruptionLevel = .timeSensitive
    ) {
        self.serverURL = serverURL
        self.deviceKey = deviceKey
        self.defaultGroup = defaultGroup
        self.sound = sound
        self.icon = icon
        self.url = url
        self.level = level
    }
}

public enum BarkInterruptionLevel: String, Codable, Equatable, Hashable, CaseIterable, Sendable {
    case passive
    case active
    case timeSensitive
    case critical
}

public enum BarkError: Error, Equatable, LocalizedError, Sendable {
    case missingDeviceKey
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case serverCode(Int, String?)

    public var errorDescription: String? {
        switch self {
        case .missingDeviceKey:
            "Bark device key is empty."
        case .invalidURL:
            "Bark server URL is invalid."
        case .invalidResponse:
            "Bark response could not be validated."
        case .httpStatus(let status):
            "Bark returned HTTP \(status)."
        case .serverCode(let code, let message):
            if let message, !message.isEmpty {
                "Bark returned code \(code): \(message)"
            } else {
                "Bark returned code \(code)."
            }
        }
    }
}

public struct BarkDeliveryFailure: Error, Equatable, LocalizedError, Sendable {
    public var deliveredCount: Int
    public var undeliveredEvents: [MonitorEvent]
    public var underlyingMessage: String

    public init(deliveredCount: Int, undeliveredEvents: [MonitorEvent], underlyingMessage: String) {
        self.deliveredCount = deliveredCount
        self.undeliveredEvents = undeliveredEvents
        self.underlyingMessage = underlyingMessage
    }

    public var errorDescription: String? {
        let count = undeliveredEvents.count
        if count == 1, let event = undeliveredEvents.first {
            return "Bark delivery failed for \(event.title): \(underlyingMessage)"
        }
        return "Bark delivery failed for \(count) notifications: \(underlyingMessage)"
    }
}

private struct BarkResponse: Decodable {
    var code: Int?
    var message: String?
}

public struct BarkClient: Sendable {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSession.shared) {
        self.transport = transport
    }

    public func send(configuration: BarkConfiguration, event: MonitorEvent) async throws {
        let request = try Self.buildRequest(configuration: configuration, event: event)
        let (data, response) = try await transport.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw BarkError.httpStatus(http.statusCode)
        }
        guard let barkResponse = try? JSONDecoder().decode(BarkResponse.self, from: data),
              let code = barkResponse.code
        else {
            throw BarkError.invalidResponse
        }
        if code != 200 {
            throw BarkError.serverCode(code, barkResponse.message)
        }
    }

    public func sendAll(configuration: BarkConfiguration, events: [MonitorEvent]) async throws {
        guard !events.isEmpty else {
            return
        }

        for index in events.indices {
            do {
                try await send(configuration: configuration, event: events[index])
            } catch {
                throw BarkDeliveryFailure(
                    deliveredCount: index,
                    undeliveredEvents: Array(events[index...]),
                    underlyingMessage: error.localizedDescription
                )
            }
        }
    }

    public static func buildRequest(configuration: BarkConfiguration, event: MonitorEvent) throws -> URLRequest {
        let key = BarkDeviceKeyNormalizer.deviceKey(from: configuration.deviceKey)
        guard !key.isEmpty else {
            throw BarkError.missingDeviceKey
        }
        guard let url = configuration.serverURL.appendingAstraPath("/push") else {
            throw BarkError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: barkPayload(configuration: configuration, event: event, key: key))
        return request
    }

    private static func barkPayload(configuration: BarkConfiguration, event: MonitorEvent, key: String) -> [String: Any] {
        var payload: [String: Any] = [
            "device_key": key,
            "title": event.title,
            "body": event.body,
            "group": configuration.defaultGroup,
            "level": configuration.level.rawValue,
            "id": event.id,
            "isArchive": "1"
        ]
        if let sound = configuration.sound, !sound.isEmpty {
            payload["sound"] = sound
        }
        if let icon = configuration.icon {
            payload["icon"] = icon.absoluteString
        }
        if let url = configuration.url {
            payload["url"] = url.absoluteString
        }
        return payload
    }
}

public enum ByteFormatter {
    public static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var amount = Double(value)
        var index = 0
        while amount >= 1024, index < units.count - 1 {
            amount /= 1024
            index += 1
        }
        if index == 0 {
            return "\(value) \(units[index])"
        }
        return String(format: "%.1f %@", amount, units[index])
    }

    public static func speed(_ value: UInt64) -> String {
        "\(bytes(value))/s"
    }
}

public enum PercentFormatter {
    public static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    public static func fraction(_ value: Double?) -> String {
        guard let value else {
            return "--"
        }
        return percent(value * 100)
    }
}

public enum DurationFormatter {
    public static func seconds(_ value: TimeInterval) -> String {
        let seconds = Int(value.rounded())
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        return "\(hours)h \(minutes % 60)m"
    }
}

private enum DateValue {
    static func decodeIfPresent<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> Date? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return AstraDateParser.date(from: value)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            let seconds = value > 10_000_000_000 ? value / 1_000 : value
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    static func decodeRequired<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> Date {
        if let value = try decodeIfPresent(from: container, forKey: key) {
            return value
        }
        return Date(timeIntervalSince1970: 0)
    }
}

private enum AstraDateParser {
    static func date(from value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("0001-01-01") else {
            return nil
        }
        return fractionalDateFormatter().date(from: trimmed)
            ?? internetDateFormatter().date(from: trimmed)
    }

    static func string(from date: Date) -> String {
        internetDateFormatter().string(from: date)
    }

    private static func internetDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private static func fractionalDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

private extension URL {
    var latticeAPIBaseURL: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.query = nil
        components.fragment = nil
        return components.url ?? self
    }

    func appendingAstraPath(_ path: String) -> URL? {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        let existingParts = components?.path.pathComponentsForAstraJoin ?? []
        let newParts = path.pathComponentsForAstraJoin
        let mergedParts = existingParts.mergingAstraPathOverlap(with: newParts)
        components?.path = mergedParts.isEmpty ? "" : "/" + mergedParts.joined(separator: "/")
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }
}

private extension String {
    var pathComponentsForAstraJoin: [String] {
        split(separator: "/").map(String.init)
    }
}

private extension Array where Element == String {
    func mergingAstraPathOverlap(with appendedParts: [String]) -> [String] {
        guard !isEmpty else {
            return appendedParts
        }
        guard !appendedParts.isEmpty else {
            return self
        }

        let maximumOverlap = Swift.min(count, appendedParts.count)
        for overlap in stride(from: maximumOverlap, through: 1, by: -1) {
            if suffix(overlap) == appendedParts.prefix(overlap) {
                return self + appendedParts.dropFirst(overlap)
            }
        }
        return self + appendedParts
    }
}
