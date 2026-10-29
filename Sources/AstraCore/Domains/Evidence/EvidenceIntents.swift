import Foundation

/// The two Evidence writes (parity matrix 3.2), both T2. The server gates a
/// capture on log:admin for every node it names (`createTraceSession`,
/// `handleTraceSessionStop`), because a capture reads user traffic metadata.
public enum EvidenceIntents {
    public static func object(nodeID: String, nodeName: String) -> ObjectRef {
        ObjectRef(kind: "node", id: nodeID, name: nodeName)
    }

    public static func object(_ session: EvidenceTraceSession) -> ObjectRef {
        ObjectRef(kind: "capture", id: session.id, name: session.name)
    }

    /// T2. Starts a capture on one node for a preset duration, with the
    /// console's capture level. It stops by itself; the server and the agent
    /// both enforce the deadline.
    public static func startCapture(nodeID: String, nodeName: String, preset: EvidenceCapturePreset, now: Date) -> WriteIntent {
        let node = object(nodeID: nodeID, nodeName: nodeName)
        let request = EvidenceCapture.request(nodeID: nodeID, nodeName: nodeName, preset: preset, now: now)
        return WriteIntent(
            tier: .t2, verb: "Capture \(preset.title) on", object: node, scopes: [EvidenceCapture.adminScope],
            consequence: "Records connection metadata for users on \(nodeName) for \(preset.spoken), then stops by itself.",
            verify: { client in
                let sessions = try await client.evidenceListSessions()
                return sessions.contains { $0.name == request.name && $0.isActive(now: Date()) }
                    ? "A capture is running on \(nodeName)." : "No capture named \(request.name) is running."
            },
            idempotent: false, changes: [.evidence],
            perform: { client, _ in
                let session = try await client.evidenceStartCapture(request)
                return .done("Capturing on \(nodeName) for \(preset.spoken)" + (session.filter.nodeIDs == [nodeID] ? "" : " on \(session.filter.nodeIDs.count) nodes"))
            }
        )
    }

    /// T2. Ends a running capture now; what it kept stays until its retention.
    public static func stopCapture(_ session: EvidenceTraceSession, nodeNames: [String]) -> WriteIntent {
        let capture = object(session)
        let where_ = nodeNames.isEmpty ? "every node it covers" : nodeNames.joined(separator: ", ")
        return WriteIntent(
            tier: .t2, verb: "Stop capture", object: capture, scopes: [EvidenceCapture.adminScope],
            consequence: "Stops recording connection metadata on \(where_) now. Records already kept stay.",
            verify: { client in
                let sessions = try await client.evidenceListSessions()
                guard let fresh = sessions.first(where: { $0.id == session.id }) else { return "\(capture.name) is no longer listed." }
                return fresh.isActive(now: Date()) ? "\(capture.name) is still running." : "\(capture.name) is \(fresh.state)."
            },
            idempotent: true, changes: [.evidence],
            perform: { client, _ in
                let stopped = try await client.evidenceStopCapture(id: session.id)
                return stopped.state == EvidenceTraceSession.running
                    ? .refused(.validation("The server still reports \(capture.name) running."), "The server still reports \(capture.name) running.")
                    : .done("Stopped \(capture.name)")
            }
        )
    }
}
