import Foundation

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
    public var load5: Double
    public var load15: Double
    public var memoryUsed: UInt64
    public var memoryTotal: UInt64
    public var diskUsed: UInt64
    public var diskTotal: UInt64
    public var netRxBytes: UInt64
    public var netTxBytes: UInt64
    public var netRxSpeed: Double
    public var netTxSpeed: Double
    public var uptimeSeconds: UInt64
    public var collectedAt: Date?

    public init(
        cpuPercent: Double = 0,
        load1: Double = 0,
        load5: Double = 0,
        load15: Double = 0,
        memoryUsed: UInt64 = 0,
        memoryTotal: UInt64 = 0,
        diskUsed: UInt64 = 0,
        diskTotal: UInt64 = 0,
        netRxBytes: UInt64 = 0,
        netTxBytes: UInt64 = 0,
        netRxSpeed: Double = 0,
        netTxSpeed: Double = 0,
        uptimeSeconds: UInt64 = 0,
        collectedAt: Date? = nil
    ) {
        self.cpuPercent = cpuPercent
        self.load1 = load1
        self.load5 = load5
        self.load15 = load15
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.diskUsed = diskUsed
        self.diskTotal = diskTotal
        self.netRxBytes = netRxBytes
        self.netTxBytes = netTxBytes
        self.netRxSpeed = netRxSpeed
        self.netTxSpeed = netTxSpeed
        self.uptimeSeconds = uptimeSeconds
        self.collectedAt = collectedAt
    }

    enum CodingKeys: String, CodingKey {
        case cpuPercent = "cpu_percent"
        case load1
        case load5
        case load15
        case memoryUsed = "memory_used"
        case memoryTotal = "memory_total"
        case diskUsed = "disk_used"
        case diskTotal = "disk_total"
        case netRxBytes = "net_rx_bytes"
        case netTxBytes = "net_tx_bytes"
        case netRxSpeed = "net_rx_speed"
        case netTxSpeed = "net_tx_speed"
        case uptimeSeconds = "uptime_seconds"
        case collectedAt = "collected_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpuPercent = try container.decodeIfPresent(Double.self, forKey: .cpuPercent) ?? 0
        load1 = try container.decodeIfPresent(Double.self, forKey: .load1) ?? 0
        load5 = try container.decodeIfPresent(Double.self, forKey: .load5) ?? 0
        load15 = try container.decodeIfPresent(Double.self, forKey: .load15) ?? 0
        memoryUsed = try container.decodeIfPresent(UInt64.self, forKey: .memoryUsed) ?? 0
        memoryTotal = try container.decodeIfPresent(UInt64.self, forKey: .memoryTotal) ?? 0
        diskUsed = try container.decodeIfPresent(UInt64.self, forKey: .diskUsed) ?? 0
        diskTotal = try container.decodeIfPresent(UInt64.self, forKey: .diskTotal) ?? 0
        netRxBytes = try container.decodeIfPresent(UInt64.self, forKey: .netRxBytes) ?? 0
        netTxBytes = try container.decodeIfPresent(UInt64.self, forKey: .netTxBytes) ?? 0
        netRxSpeed = try container.decodeIfPresent(Double.self, forKey: .netRxSpeed) ?? 0
        netTxSpeed = try container.decodeIfPresent(Double.self, forKey: .netTxSpeed) ?? 0
        uptimeSeconds = try container.decodeIfPresent(UInt64.self, forKey: .uptimeSeconds) ?? 0
        collectedAt = try DateValue.decodeIfPresent(from: container, forKey: .collectedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cpuPercent, forKey: .cpuPercent)
        try container.encode(load1, forKey: .load1)
        try container.encode(load5, forKey: .load5)
        try container.encode(load15, forKey: .load15)
        try container.encode(memoryUsed, forKey: .memoryUsed)
        try container.encode(memoryTotal, forKey: .memoryTotal)
        try container.encode(diskUsed, forKey: .diskUsed)
        try container.encode(diskTotal, forKey: .diskTotal)
        try container.encode(netRxBytes, forKey: .netRxBytes)
        try container.encode(netTxBytes, forKey: .netTxBytes)
        try container.encode(netRxSpeed, forKey: .netRxSpeed)
        try container.encode(netTxSpeed, forKey: .netTxSpeed)
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
    /// Server-derived reachability: `online`, `offline`, or `never_reported`.
    public var reachability: String
    /// Console honesty word: `never_reported`, `online`, `degraded`, `offline`, `disabled`.
    public var status: String
    public var statusSince: Date?
    public var statusReason: String
    public var disabled: Bool
    public var lastSeen: Date?
    public var groupIDs: [String]
    public var metrics: LatticeMetrics
    public var hostFacts: LatticeHostFacts
    public var geo: LatticeGeo?
    public var createdAt: Date?
    public var comment: String = ""
    public var internalIP: String = ""
    public var internalIPv6: String = ""
    /// When the node's token last authenticated.
    public var tokenLastUsedAt: Date?
    /// Probe methods the agent can run, and why it refuses the others.
    public var probeMethods: [String] = []
    public var probeRefusals: [String: String] = [:]

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
        reachability: String = "",
        status: String = "",
        statusSince: Date? = nil,
        statusReason: String = "",
        disabled: Bool = false,
        lastSeen: Date? = nil,
        groupIDs: [String] = [],
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
        self.reachability = reachability
        self.status = status
        self.statusSince = statusSince
        self.statusReason = statusReason
        self.disabled = disabled
        self.lastSeen = lastSeen
        self.groupIDs = groupIDs
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
        let word = honestyWord
        if word.isEmpty { return isOffline(timeout: 0) ? "offline" : "online" }
        return word
    }

    /// Console honesty word. Prefers the server `status` field; falls back to
    /// `never_reported` / `disabled` / `offline` / `online` from older payloads.
    public var honestyWord: String {
        if !status.isEmpty { return status }
        if disabled { return "disabled" }
        if lastSeen == nil { return "never_reported" }
        if !online { return "offline" }
        return "online"
    }

    /// Inbox Attention: anything other than a reporting, healthy node.
    public var needsAttention: Bool {
        switch honestyWord {
        case "online": return false
        default: return true
        }
    }

    public func isOffline(referenceDate: Date = Date(), timeout: TimeInterval) -> Bool {
        if honestyWord == "disabled" || honestyWord == "offline" || honestyWord == "never_reported" {
            return true
        }
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
        case reachability
        case status
        case statusSince = "status_since"
        case statusReason = "status_reason"
        case disabled
        case lastSeen = "last_seen"
        case groupIDs = "group_ids"
        case metrics
        case hostFacts = "host_facts"
        case geo
        case createdAt = "created_at"
        case comment
        case internalIP = "internal_ip"
        case internalIPv6 = "internal_ipv6"
        case tokenLastUsedAt = "token_last_used_at"
        case probeMethods = "probe_methods"
        case probeRefusals = "probe_refusals"
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
        reachability = try container.decodeIfPresent(String.self, forKey: .reachability) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        statusSince = try DateValue.decodeIfPresent(from: container, forKey: .statusSince)
        statusReason = try container.decodeIfPresent(String.self, forKey: .statusReason) ?? ""
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        lastSeen = try DateValue.decodeIfPresent(from: container, forKey: .lastSeen)
        groupIDs = try container.decodeIfPresent([String].self, forKey: .groupIDs) ?? []
        metrics = try container.decodeIfPresent(LatticeMetrics.self, forKey: .metrics) ?? LatticeMetrics()
        hostFacts = try container.decodeIfPresent(LatticeHostFacts.self, forKey: .hostFacts) ?? LatticeHostFacts()
        geo = try container.decodeIfPresent(LatticeGeo.self, forKey: .geo)
        createdAt = try DateValue.decodeIfPresent(from: container, forKey: .createdAt)
        comment = try container.decodeIfPresent(String.self, forKey: .comment) ?? ""
        internalIP = try container.decodeIfPresent(String.self, forKey: .internalIP) ?? ""
        internalIPv6 = try container.decodeIfPresent(String.self, forKey: .internalIPv6) ?? ""
        tokenLastUsedAt = try DateValue.decodeIfPresent(from: container, forKey: .tokenLastUsedAt)
        probeMethods = try container.decodeIfPresent([String].self, forKey: .probeMethods) ?? []
        probeRefusals = try container.decodeIfPresent([String: String].self, forKey: .probeRefusals) ?? [:]
    }
}

public struct NodeGeoInfo: Codable, Equatable, Hashable, Sendable {
    public var country: String
    public var region: String
    public var city: String
    public var lat: Double
    public var lon: Double
    public var ip: String
    public var asn: Int
    public var asOrg: String
    public var provider: String
    public var source: String
    public var updatedAt: Date?

    public init(country: String = "", region: String = "", city: String = "", lat: Double = 0, lon: Double = 0, ip: String = "", asn: Int = 0, asOrg: String = "", provider: String = "", source: String = "", updatedAt: Date? = nil) {
        self.country = country
        self.region = region
        self.city = city
        self.lat = lat
        self.lon = lon
        self.ip = ip
        self.asn = asn
        self.asOrg = asOrg
        self.provider = provider
        self.source = source
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case country, region, city, lat, lon, ip, asn, source
        case asOrg = "as_org"
        case provider
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        country = try container.decodeIfPresent(String.self, forKey: .country) ?? ""
        region = try container.decodeIfPresent(String.self, forKey: .region) ?? ""
        city = try container.decodeIfPresent(String.self, forKey: .city) ?? ""
        lat = try container.decodeIfPresent(Double.self, forKey: .lat) ?? 0
        lon = try container.decodeIfPresent(Double.self, forKey: .lon) ?? 0
        ip = try container.decodeIfPresent(String.self, forKey: .ip) ?? ""
        asn = try container.decodeIfPresent(Int.self, forKey: .asn) ?? 0
        asOrg = try container.decodeIfPresent(String.self, forKey: .asOrg) ?? ""
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ""
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        updatedAt = try DateValue.decodeIfPresent(from: container, forKey: .updatedAt)
    }

    /// Finite, in-range, and not the (0, 0) empty sentinel MapKit rejects as a region.
    public var isMapCoordinate: Bool {
        lat.isFinite && lon.isFinite
            && lat >= -90 && lat <= 90
            && lon >= -180 && lon <= 180
            && !(lat == 0 && lon == 0)
    }
}

/// `nodeGeoView` returned by `GET /api/nodes/geo`: a node plus its map metadata.
public struct NodeGeoView: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var role: String
    public var online: Bool
    public var publicIP: String
    public var publicIPv6: String
    public var status: String
    public var statusReason: String
    public var geo: NodeGeoInfo?

    public init(id: String, name: String = "", role: String = "", online: Bool = false, publicIP: String = "", publicIPv6: String = "", status: String = "", statusReason: String = "", geo: NodeGeoInfo? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.online = online
        self.publicIP = publicIP
        self.publicIPv6 = publicIPv6
        self.status = status
        self.statusReason = statusReason
        self.geo = geo
    }

    public var displayName: String { name.isEmpty ? id : name }

    /// Whether this node has a usable map coordinate.
    /// NaN compares unequal to 0, so a raw `lat != 0` would treat garbage as a pin.
    public var hasCoordinate: Bool {
        guard let geo else { return false }
        return geo.isMapCoordinate
    }

    enum CodingKeys: String, CodingKey {
        case id, name, role, online, geo
        case publicIP = "public_ip"
        case publicIPv6 = "public_ipv6"
        case status
        case statusReason = "status_reason"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        online = try container.decodeIfPresent(Bool.self, forKey: .online) ?? false
        publicIP = try container.decodeIfPresent(String.self, forKey: .publicIP) ?? ""
        publicIPv6 = try container.decodeIfPresent(String.self, forKey: .publicIPv6) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        statusReason = try container.decodeIfPresent(String.self, forKey: .statusReason) ?? ""
        geo = try container.decodeIfPresent(NodeGeoInfo.self, forKey: .geo)
    }
}

public extension LatticeClient {
    // Geo / fleet map
    func fetchNodeGeo() async throws -> [NodeGeoView] {
        try await perform([NodeGeoView].self, path: "/api/nodes/geo")
    }
}

public extension LatticeNode {
    /// The honesty state `StatusStyle` renders (section 4.2).
    var honesty: NodeHonesty {
        NodeHonesty(serverValue: honestyWord)
    }
}

public extension LatticeClient {
    func fetchNodes() async throws -> [LatticeNode] {
        let request = try buildRequest(path: "/api/nodes")
        let (data, response) = try await send(request)
        try validate(response: response, data: data)
        return try LatticeDecoder.decodeNodes(from: data)
    }
}
