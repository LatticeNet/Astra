import Foundation

// Self-host DNS, Geo-Routing, Tunnels, and the pure parts of DDNS the
// phone adds to the Shared profile: the record preview of Run now.

public struct NetworkingDNSRecord: Decodable, Hashable, Sendable {
    public var name: String
    public var type: String
    public var value: String
    public var ttl: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        name = c.networkingString("name")
        type = c.networkingString("type")
        value = c.networkingString("value")
        ttl = c.networkingInt("ttl")
    }
}

public struct NetworkingDNSZone: Decodable, Hashable, Sendable {
    public var suffix: String
    /// forward, static or block.
    public var mode: String
    public var upstreams: [String]
    public var records: [NetworkingDNSRecord]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        suffix = c.networkingString("suffix")
        mode = c.networkingString("mode")
        upstreams = c.networkingStrings("upstreams")
        records = try c.networkingList(NetworkingDNSRecord.self, "records")
    }

    /// "forward to 1.1.1.1, 9.9.9.9", "3 static records", "blocked".
    public var summary: String {
        switch mode {
        case "forward": upstreams.isEmpty ? "forward" : "forward to \(upstreams.joined(separator: ", "))"
        case "static": records.count == 1 ? "1 static record" : "\(records.count) static records"
        case "block": "blocked"
        default: mode
        }
    }
}

public struct NetworkingDNSListener: Decodable, Hashable, Sendable {
    public var proto: String
    public var port: Int
    public var process: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        proto = c.networkingString("protocol")
        port = c.networkingInt("port")
        process = c.networkingString("process")
    }

    /// "tcp/853 (dnsproxy)".
    public var text: String {
        process.isEmpty ? "\(proto)/\(port)" : "\(proto)/\(port) (\(process))"
    }
}

/// The read-time comparison of an external engine's listeners with the node's latest guard reality.
public struct NetworkingDNSDrift: Decodable, Hashable, Sendable {
    /// ok, drift or unknown.
    public var status: String
    public var findings: [String]
    public var realityCollectedAt: Date?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        status = c.networkingString("status")
        findings = c.networkingStrings("findings")
        realityCollectedAt = c.networkingDate("reality_collected_at")
    }
}

/// A tls check linked to an external engine.
public struct NetworkingDNSCertCheck: Decodable, Hashable, Sendable {
    public var monitorID: String
    public var name: String
    public var target: String
    public var thresholdDays: Int
    public var enabled: Bool
    public var certNotAfter: Date?
    public var measuredAt: Date?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        monitorID = c.networkingString("monitor_id")
        name = c.networkingString("name")
        target = c.networkingString("target")
        thresholdDays = c.networkingInt("threshold_days")
        enabled = c.networkingBool("enabled")
        certNotAfter = c.networkingDate("cert_not_after")
        measuredAt = c.networkingDate("measured_at")
    }
}

public struct NetworkingDNSCertExpiry: Decodable, Hashable, Sendable {
    public var notAfter: Date?
    /// measured or typed.
    public var source: String
    public var monitorID: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        notAfter = c.networkingDate("not_after")
        source = c.networkingString("source")
        monitorID = c.networkingString("monitor_id")
    }
}

/// One self-hosted DNS service (`dnsDeploymentView`).
public struct NetworkingDNSDeployment: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var nodeID: String
    public var nodeName: String
    /// coredns (deployed by plans) or external (observed only).
    public var engine: String
    public var listenPort: Int
    public var enableUDP: Bool
    public var enableTCP: Bool
    /// mesh or public.
    public var exposure: String
    public var zones: [NetworkingDNSZone]
    public var openResolver: Bool
    public var allowedClients: [String]
    public var hostname: String
    public var listeners: [NetworkingDNSListener]
    public var certNotAfter: Date?
    public var drift: NetworkingDNSDrift?
    public var certChecks: [NetworkingDNSCertCheck]
    public var certExpiry: NetworkingDNSCertExpiry?
    public var publishIPv4: Bool
    public var publishIPv6: Bool
    public var recordTTL: Int
    public var ddnsProfileID: String
    public var hasCredential: Bool
    /// pending, applying, running, failed, disabled or observed.
    public var status: String
    public var engineVersion: String
    public var lastIPv4: String
    public var lastIPv6: String
    public var lastAppliedAt: Date?
    public var lastError: String
    public var lastPublishedAt: Date?
    public var lastPublishError: String
    public var disabled: Bool
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        id = try c.networkingRequired("id")
        name = c.networkingString("name")
        nodeID = c.networkingString("node_id")
        nodeName = c.networkingString("node_name")
        engine = c.networkingString("engine")
        listenPort = c.networkingInt("listen_port")
        enableUDP = c.networkingBool("enable_udp")
        enableTCP = c.networkingBool("enable_tcp")
        exposure = c.networkingString("exposure")
        zones = try c.networkingList(NetworkingDNSZone.self, "zones")
        openResolver = c.networkingBool("open_resolver")
        allowedClients = c.networkingStrings("allowed_clients")
        hostname = c.networkingString("hostname")
        listeners = try c.networkingList(NetworkingDNSListener.self, "listeners")
        certNotAfter = c.networkingDate("cert_not_after")
        drift = try c.networkingObject(NetworkingDNSDrift.self, "drift")
        certChecks = try c.networkingList(NetworkingDNSCertCheck.self, "cert_checks")
        certExpiry = try c.networkingObject(NetworkingDNSCertExpiry.self, "cert_expiry")
        publishIPv4 = c.networkingBool("publish_ipv4")
        publishIPv6 = c.networkingBool("publish_ipv6")
        recordTTL = c.networkingInt("record_ttl")
        ddnsProfileID = c.networkingString("ddns_profile_id")
        hasCredential = c.networkingBool("has_credential")
        status = c.networkingString("status")
        engineVersion = c.networkingString("engine_version")
        lastIPv4 = c.networkingString("last_ipv4")
        lastIPv6 = c.networkingString("last_ipv6")
        lastAppliedAt = c.networkingDate("last_applied_at")
        lastError = c.networkingString("last_error")
        lastPublishedAt = c.networkingDate("last_published_at")
        lastPublishError = c.networkingString("last_publish_error")
        disabled = c.networkingBool("disabled")
        createdAt = c.networkingDate("created_at")
        updatedAt = c.networkingDate("updated_at")
    }

    public var displayName: String { name.isEmpty ? id : name }
    public var nodeDisplayName: String { nodeName.isEmpty ? nodeID : nodeName }

    /// An engine Lattice only observes: never planned, never published.
    public var isExternal: Bool { engine.trimmingCharacters(in: .whitespaces).lowercased() == "external" }

    /// `canPlanDeployment`.
    public var canPlan: Bool { !isExternal }

    /// `canPublishDeployment`: the deployment is one Lattice publishes at all.
    public var publishes: Bool { !isExternal && !hostname.trimmingCharacters(in: .whitespaces).isEmpty }

    /// `publishes`, plus the server's refusals of a disabled deployment and of
    /// one with no stored credential (`dnsPublishProfile`).
    public var canPublish: Bool { publishes && !disabled && hasCredential }

    /// `listenSummary`: "tcp+udp 53, mesh" or the observed sockets.
    public var listenSummary: String {
        if isExternal {
            let sockets = listeners.sorted { ($0.port, $0.proto) < ($1.port, $1.proto) }.map(\.text)
            return sockets.isEmpty ? "No listeners recorded" : sockets.joined(separator: ", ")
        }
        let protos = [enableTCP ? "tcp" : nil, enableUDP ? "udp" : nil].compactMap { $0 }.joined(separator: "+")
        return "\(protos.isEmpty ? "no protocol" : protos) \(listenPort), \(exposure.isEmpty ? "mesh" : exposure)"
    }

    /// Why a certificate cannot be measured, or nil when it can (`measureBlock`).
    public var measureBlock: String? {
        let host = hostname.trimmingCharacters(in: .whitespaces)
        if host.isEmpty { return "The deployment has no hostname to measure a certificate on." }
        if host.contains(":") || host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil {
            return "A certificate is held to a name, and this hostname is an address."
        }
        return nil
    }

    /// `certPortCandidates`: every recorded tcp listener, the likely DoT and
    /// DoH ones (not 53, no udp twin) suggested, with the check already on it.
    public var certPorts: [NetworkingCertPort] {
        let udp = Set(listeners.filter { $0.proto == "udp" }.map(\.port))
        let host = hostname.trimmingCharacters(in: .whitespaces).lowercased()
        let ports = Set(listeners.filter { $0.proto == "tcp" }.map(\.port)).sorted()
        return ports.map { port in
            NetworkingCertPort(
                port: port, suggested: port != 53 && !udp.contains(port),
                measuredBy: certChecks.first { $0.target.trimmingCharacters(in: .whitespaces).lowercased() == "\(host):\(port)" }
            )
        }
    }

    /// The ports Measure certificate sends: suggested ones without a check yet.
    public var portsToMeasure: [Int] {
        certPorts.filter { $0.suggested && $0.measuredBy == nil }.map(\.port)
    }

    /// `certShown`: what a linked check measured over what the operator typed.
    public var certShown: (notAfter: Date, source: String)? {
        if let expiry = certExpiry, expiry.source == "measured", let date = expiry.notAfter { return (date, "measured") }
        if let expiry = certExpiry, expiry.source == "typed", let date = expiry.notAfter { return (date, "typed") }
        if let typed = certNotAfter { return (typed, "typed") }
        return nil
    }

    /// `linkedCertWatch`: the threshold of the check that judges the expiry;
    /// 0 when nothing watches, so only an expiry already past is called out.
    public var certThresholdDays: Int {
        let enabled = certChecks.filter(\.enabled)
        guard let check = enabled.first(where: { $0.monitorID == certExpiry?.monitorID }) ?? enabled.first else { return 0 }
        return check.thresholdDays > 0 ? check.thresholdDays : NetworkingCertState.defaultThresholdDays
    }

    public func certState(now: Date) -> NetworkingCertState {
        guard let shown = certShown else { return .unknown }
        return NetworkingCertState.of(notAfter: shown.notAfter, now: now, thresholdDays: certThresholdDays)
    }

    /// The worst thing about the deployment, for the row and the detail header.
    public func health(now: Date) -> NetworkingDNSHealth {
        if !lastError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || status == "failed" {
            return .failing(lastError.isEmpty ? "The last apply failed." : lastError)
        }
        if case .expired(let days) = certState(now: now) {
            return .failing(days == -1 ? "The certificate expired yesterday." : "The certificate expired \(-days) days ago.")
        }
        if !lastPublishError.isEmpty { return .warning("Publish failed: \(lastPublishError)") }
        if drift?.status == "drift" { return .warning(drift?.findings.first ?? "The node's listeners differ from the record.") }
        if openResolver { return .warning("Answers every client on a public port: an open resolver.") }
        if case .soon(let days) = certState(now: now) {
            return .warning(days == 0 ? "The certificate expires today." : (days == 1 ? "The certificate expires tomorrow." : "The certificate expires in \(days) days."))
        }
        if disabled || status == "disabled" { return .off("disabled") }
        switch status {
        case "observed": return .ok("observed")
        case "running": return .ok("running")
        case "applying": return .pending("applying")
        default: return .pending(status.isEmpty ? "not planned yet" : status)
        }
    }
}

/// One tcp listener a certificate measure can name.
public struct NetworkingCertPort: Hashable, Sendable {
    public var port: Int
    public var suggested: Bool
    public var measuredBy: NetworkingDNSCertCheck?
}

/// The certificate countdown (`certExpiry`).
public enum NetworkingCertState: Hashable, Sendable {
    case unknown
    case ok(days: Int)
    case soon(days: Int)
    case expired(days: Int)

    /// The tls check default when a check carries none.
    public static let defaultThresholdDays = 14

    public static func of(notAfter: Date, now: Date, thresholdDays: Int) -> NetworkingCertState {
        let days = Int((notAfter.timeIntervalSince(now) / 86_400).rounded(.down))
        if days < 0 { return .expired(days: days) }
        if days <= thresholdDays { return .soon(days: days) }
        return .ok(days: days)
    }

    /// "41 days left", "expires today", "expired 3 days ago".
    public var words: String {
        switch self {
        case .unknown: "no certificate date"
        case .ok(let days), .soon(let days):
            days == 0 ? "expires today" : (days == 1 ? "1 day left" : "\(days) days left")
        case .expired(let days): days == -1 ? "expired 1 day ago" : "expired \(-days) days ago"
        }
    }
}

/// A deployment's standing, worst first.
public enum NetworkingDNSHealth: Hashable, Sendable {
    case failing(String)
    case warning(String)
    case pending(String)
    case off(String)
    case ok(String)

    public var rank: Int {
        switch self {
        case .failing: 0
        case .warning: 1
        case .pending: 2
        case .ok: 3
        case .off: 4
        }
    }
}

/// What Publish IPs would send, computed on the phone from the node's
/// reported addresses: the server has no preview. It mirrors the server's
/// `dnsPublishProfile` and `publishableDNSIPs`: neither family set means
/// IPv4, and an enabled family without a valid address refuses the whole
/// publish rather than skipping that family.
public struct NetworkingPublishPreview: Hashable, Sendable {
    public struct Line: Hashable, Sendable {
        /// "A" or "AAAA".
        public var type: String
        public var value: String
        /// What the provider was last given; empty when never published.
        public var previous: String

        public var changes: Bool { value != previous }
    }

    /// Why the server would refuse the publish, with the row label it shows under.
    public struct Refusal: Hashable, Sendable {
        public var label: String
        public var text: String
    }

    public var hostname: String
    /// What would be written; meaningful only when `refusals` is empty.
    public var lines: [Line]
    public var refusals: [Refusal]

    public var blocking: Bool { !refusals.isEmpty || lines.isEmpty }

    public init(deployment: NetworkingDNSDeployment, publicIPv4: String?, publicIPv6: String?) {
        hostname = deployment.hostname
        var lines: [Line] = []
        var refusals: [Refusal] = []
        if deployment.hostname.trimmingCharacters(in: .whitespaces).isEmpty {
            refusals.append(Refusal(label: "Hostname", text: "The deployment has no hostname to publish."))
        }
        if deployment.disabled {
            refusals.append(Refusal(label: "Deployment", text: "The deployment is disabled."))
        }
        if !deployment.hasCredential {
            refusals.append(Refusal(label: "Credential", text: "No provider credential is stored, so the server refuses to publish."))
        }
        let publishV4 = deployment.publishIPv4 || !deployment.publishIPv6
        let v4 = (publicIPv4 ?? "").trimmingCharacters(in: .whitespaces)
        let v6 = (publicIPv6 ?? "").trimmingCharacters(in: .whitespaces)
        if publishV4 {
            if v4.isEmpty {
                refusals.append(Refusal(label: "IPv4", text: "The node has no public IPv4, and the server refuses the whole publish when a family it publishes has no address."))
            } else if !NetworkingIP.isPublishableV4(v4) {
                refusals.append(Refusal(label: "IPv4", text: "The node's public IPv4 \(v4) is not a valid address, so the server refuses the publish."))
            } else {
                lines.append(Line(type: "A", value: v4, previous: deployment.lastIPv4))
            }
        }
        if deployment.publishIPv6 {
            if v6.isEmpty {
                refusals.append(Refusal(label: "IPv6", text: "The node has no public IPv6, and the server refuses the whole publish when a family it publishes has no address."))
            } else if !NetworkingIP.isPublishableV6(v6) {
                refusals.append(Refusal(label: "IPv6", text: "The node's public IPv6 \(v6) is not a valid address, so the server refuses the publish."))
            } else {
                lines.append(Line(type: "AAAA", value: v6, previous: deployment.lastIPv6))
            }
        }
        self.lines = lines
        self.refusals = refusals
    }

    /// "A: will publish the node's current address 203.0.113.15; the provider has 203.0.113.15."
    /// When the server would refuse, only the reasons, since nothing is written.
    public var sentences: [String] {
        if !refusals.isEmpty { return ["Nothing can be published."] + refusals.map(\.text) }
        return lines.map { line in
            let has = line.previous.isEmpty ? "the provider has no \(line.type) record from Lattice yet" : "the provider has \(line.previous)"
            return "\(line.type): will publish the node's current address \(line.value); \(has)."
        }
    }
}

/// The address checks of the server's `publishableDNSIPs` (netip.ParseAddr,
/// the right family, not unspecified).
enum NetworkingIP {
    static func isPublishableV4(_ value: String) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, value, &address) == 1 else { return false }
        return address.s_addr != 0
    }

    static func isPublishableV6(_ value: String) -> Bool {
        let host = value.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
        return withUnsafeBytes(of: &address) { bytes in bytes.contains { $0 != 0 } }
    }
}

// MARK: Geo-Routing

/// One geo routing (`model.GeoRouting`).
public struct NetworkingGeoRouting: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var hostname: String
    public var nodeIDs: [String]
    public var dnsNodeIDs: [String]
    public var ttl: Int
    /// geoip or all-healthy.
    public var strategy: String
    public var geoIPDBPath: String
    public var publishNS: Bool
    public var ddnsProfileID: String
    public var lastRenderedSHA: String
    public var status: String
    public var lastAppliedAt: Date?
    public var lastDelegatedAt: Date?
    public var lastError: String
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        id = try c.networkingRequired("id")
        name = c.networkingString("name")
        hostname = c.networkingString("hostname")
        nodeIDs = c.networkingStrings("node_ids")
        dnsNodeIDs = c.networkingStrings("dns_node_ids")
        ttl = c.networkingInt("ttl")
        strategy = c.networkingString("strategy")
        geoIPDBPath = c.networkingString("geoip_db_path")
        publishNS = c.networkingBool("publish_ns")
        ddnsProfileID = c.networkingString("ddns_profile_id")
        lastRenderedSHA = c.networkingString("last_rendered_sha")
        status = c.networkingString("status")
        lastAppliedAt = c.networkingDate("last_applied_at")
        lastDelegatedAt = c.networkingDate("last_delegated_at")
        lastError = c.networkingString("last_error")
        createdAt = c.networkingDate("created_at")
        updatedAt = c.networkingDate("updated_at")
    }

    public var displayName: String { name.isEmpty ? hostname : name }

    public var strategyWords: String {
        switch strategy {
        case "geoip": "nearest by GeoIP"
        case "all-healthy": "every healthy node"
        default: strategy.isEmpty ? "nearest by GeoIP" : strategy
        }
    }

    /// `geoDeleteImpact`: an applied routing leaves its zone on each DNS
    /// node, which keeps answering the hostname, so the delete names them and
    /// asks for the typed name. One never applied lives only on the server.
    public func deleteImpact(name nodeName: (String) -> String, time: (Date) -> String) -> NetworkingDeleteImpact {
        guard let applied = lastAppliedAt else {
            return NetworkingDeleteImpact(lines: ["Removes the record for \(hostname).", "Nothing was ever sent to a node, so nothing else changes."], typed: false)
        }
        var lines = dnsNodeIDs.isEmpty
            ? ["The zone for \(hostname) was applied on \(time(applied)), so its DNS nodes keep answering it."]
            : dnsNodeIDs.map { "\(nodeName($0)) keeps answering \(hostname) as applied on \(time(applied))." }
        lines.append("Deleting removes only the record. Nothing removes the zone from a node.")
        return NetworkingDeleteImpact(lines: lines, typed: true)
    }
}

/// `POST /api/geo-routing/plan`: the rendered config, read only.
public struct NetworkingGeoPlan: Decodable, Hashable, Sendable {
    public var geoRoutingID: String
    public var hostname: String
    public var strategy: String
    public var config: String
    public var sha256: String
    public var warnings: [String]
    /// Continent code to the node id answering it.
    public var continentChoice: [String: String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LatticeCodingKey.self)
        geoRoutingID = c.networkingString("geo_routing_id")
        hostname = c.networkingString("hostname")
        strategy = c.networkingString("strategy")
        config = c.networkingString("config")
        sha256 = c.networkingString("sha256")
        warnings = c.networkingStrings("warnings")
        continentChoice = (try? c.decodeIfPresent([String: String].self, forKey: LatticeCodingKey("continent_choice"))) ?? [:]
    }
}

/// What a delete leaves behind, as the console's destructive classes say it.
public struct NetworkingDeleteImpact: Hashable, Sendable {
    public var lines: [String]
    /// The operator types the object's name before Delete enables.
    public var typed: Bool
}

// MARK: Tunnels

public extension TunnelProfile {
    /// The tunnels page's delete: cloudflared keeps running with its
    /// config, so the hostnames keep resolving through the tunnel.
    func networkingDeleteImpact(nodeName: String) -> NetworkingDeleteImpact {
        var lines = ["cloudflared keeps running on \(nodeName) with the last config it was given."]
        let hosts = ingress.map(\.hostname).filter { !$0.isEmpty }
        if !hosts.isEmpty {
            lines.append(hosts.count == 1 ? "\(hosts[0]) keeps reaching the node through the tunnel." : "\(hosts.joined(separator: ", ")) keep reaching the node through the tunnel.")
        }
        lines.append("Deleting removes only the profile. Nothing stops cloudflared or removes its config.")
        return NetworkingDeleteImpact(lines: lines, typed: true)
    }
}

// MARK: DDNS

/// One record Run now writes (`ddnsRunPreview`).
public struct NetworkingDDNSRecordPreview: Hashable, Sendable {
    public var domain: String
    /// A, AAAA or CNAME.
    public var type: String
    public var value: String
    /// What the profile last wrote; empty when it never wrote.
    public var previous: String

    /// "home.example.net A 192.0.2.202 (was 192.0.2.10)".
    public var sentence: String {
        let was = previous.isEmpty ? "not written before" : (previous == value ? "unchanged" : "was \(previous)")
        return "\(domain) \(type) \(value) (\(was))"
    }
}

public enum NetworkingDDNSPreview {
    /// The server publishes the node's current address for each enabled
    /// family to every domain and skips a family with no address; a CNAME
    /// profile points every domain at its target.
    public static func records(_ profile: DDNSProfile, publicIPv4: String?, publicIPv6: String?) -> [NetworkingDDNSRecordPreview] {
        if profile.isCNAME {
            let target = DDNSProfile.normalizeHost(profile.cnameTarget)
            return profile.domains.map { NetworkingDDNSRecordPreview(domain: $0, type: "CNAME", value: target, previous: profile.lastTarget.trimmingCharacters(in: .whitespaces)) }
        }
        let v4 = profile.enableIPv4 ? (publicIPv4 ?? "").trimmingCharacters(in: .whitespaces) : ""
        let v6 = profile.enableIPv6 ? (publicIPv6 ?? "").trimmingCharacters(in: .whitespaces) : ""
        var out: [NetworkingDDNSRecordPreview] = []
        for domain in profile.domains {
            if !v4.isEmpty { out.append(NetworkingDDNSRecordPreview(domain: domain, type: "A", value: v4, previous: profile.lastIPv4.trimmingCharacters(in: .whitespaces))) }
            if !v6.isEmpty { out.append(NetworkingDDNSRecordPreview(domain: domain, type: "AAAA", value: v6, previous: profile.lastIPv6.trimmingCharacters(in: .whitespaces))) }
        }
        return out
    }

    /// `ddnsErrorText`: Cloudflare's JSON error lists read as sentences.
    public static func errorText(_ lastError: String) -> String {
        lastError.split(separator: "\n").map { raw -> String in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let match = line.range(of: #"HTTP (\d{3}): (\[.*\])"#, options: .regularExpression) else { return line }
            let found = String(line[match])
            guard let status = found.range(of: #"\d{3}"#, options: .regularExpression),
                  let open = found.firstIndex(of: "["),
                  let items = try? JSONSerialization.jsonObject(with: Data(found[open...].utf8)) as? [[String: Any]], !items.isEmpty else { return line }
            let said = items.compactMap { item -> String? in
                guard let message = (item["message"] as? String)?.trimmingCharacters(in: .whitespaces), !message.isEmpty else { return nil }
                if let code = item["code"] as? Int { return "\(message) (code \(code))" }
                return message
            }.joined(separator: "; ")
            guard !said.isEmpty else { return line }
            return String(line[..<match.lowerBound]) + "Cloudflare refused it, HTTP \(found[status]): \(said)"
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
