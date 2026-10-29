import SwiftUI
import Synchronization

/// M10 routes on a tab stack (section 2.4). The cases declared in M0 are
/// frozen; M10 may add cases but must not rename or remove these.
enum EvidenceRoute: Hashable, Codable, Sendable {
    case overview
    case connections(filter: String?)
    case connection(id: String)
    case logs(nodeID: String?)
    /// One raw log source by id, for results that name a source rather than a node.
    case logSource(id: String)
}

/// M10's demo intents and sheets for `-AstraPresent`:
/// `confirm:evidence.start:<nodeName>:<minutes>` (5, 15 or 60) and
/// `confirm:evidence.stop:<sessionID>`, and `evidencePush:<page>`, which
/// pushes a page no link reaches (`overview`, `connections[:<filter>]`,
/// `logs[:<nodeName>]`, `logSource:<sourceID>`, `logsFind:<nodeName>:<text>`
/// with the find bar open on `text`) onto the selected tab; pair it with `-AstraTab browse`.
/// Ids are the demo's (`edge-tyo-1`, `trace_s1`).
extension EvidenceRoute: DemoHooks {
    static func demoIntent(_ id: String, session: SessionStore) -> WriteIntent? {
        guard session.isDemo, id.hasPrefix("evidence.") else { return nil }
        let parts = id.dropFirst("evidence.".count).split(separator: ":").map(String.init)
        switch parts.first {
        case "start":
            guard parts.count >= 2, let node = DemoWorld.nodes.first(where: { $0.name == parts[1] }) else { return nil }
            let minutes = parts.count > 2 ? Int(parts[2]) ?? 15 : 15
            let preset = EvidenceCapturePreset(rawValue: minutes * 60) ?? .fifteenMinutes
            return EvidenceIntents.startCapture(nodeID: node.id, nodeName: node.name, preset: preset, now: Date())
        case "stop":
            guard parts.count >= 2 else { return nil }
            let node = parts[1] == "trace_s2" ? DemoWorld.node("edge-iad-1") : DemoWorld.node("edge-tyo-1")
            let name = parts[1] == "trace_s2" ? "console capture edge-iad-1" : "debug handshake edge-tyo-1"
            return EvidenceIntents.stopCapture(EvidenceTraceSession(id: parts[1], name: name, filter: EvidenceTraceFilter(nodeIDs: [node.id])), nodeNames: [node.name])
        default:
            return nil
        }
    }

    static func demoSheet(_ name: String, argument: String?) -> AnyView? {
        guard name == "evidencePush" else { return nil }
        let parts = (argument ?? "overview").split(separator: ":", maxSplits: 1).map(String.init)
        let detail = parts.count > 1 ? parts[1] : nil
        let route: EvidenceRoute? = switch parts.first {
        case "overview": .overview
        case "connections": .connections(filter: detail)
        case "logs": .logs(nodeID: detail.flatMap { name in DemoWorld.nodes.first { $0.name == name }?.id })
        case "logSource": detail.map { .logSource(id: $0) }
        case "logsFind":
            evidenceLogsFind(detail)
        default: nil
        }
        return route.map { AnyView(EvidenceDemoPusher(route: $0)) }
    }

    private static func evidenceLogsFind(_ detail: String?) -> EvidenceRoute? {
        let parts = (detail ?? "").split(separator: ":", maxSplits: 1).map(String.init)
        guard let name = parts.first, let node = DemoWorld.nodes.first(where: { $0.name == name }) else { return nil }
        EvidenceDemoFind.pending.withLock { $0 = parts.count > 1 ? parts[1] : nil }
        return .logs(nodeID: node.id)
    }
}

/// A find text the next log explorer opens with (demo screenshots only).
enum EvidenceDemoFind {
    static let pending = Mutex<String?>(nil)

    static func take() -> String? {
        pending.withLock { value in
            defer { value = nil }
            return value
        }
    }
}
