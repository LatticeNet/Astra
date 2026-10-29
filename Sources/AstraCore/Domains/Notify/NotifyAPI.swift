import Foundation

private struct RulesEnvelope: Decodable { var rules: [NotifyRule] }

struct NotifyChannelRequest: Encodable {
    var id: String
    var name: String
    var kind: String
    var config: [String: String]
    var enabled: Bool
}

struct NotifyRuleRequest: Encodable {
    var id: String
    var name: String
    var eventTypes: [String]
    var channelIDs: [String]
    var titleTemplate: String
    var bodyTemplate: String
    var enabled: Bool
    enum CodingKeys: String, CodingKey {
        case id, name, enabled
        case eventTypes = "event_types"
        case channelIDs = "channel_ids"
        case titleTemplate = "title_template"
        case bodyTemplate = "body_template"
    }
}

struct NotifyTestRequest: Encodable {
    var channel: String
    var config: [String: String]
    var title: String
    var body: String
}

public extension LatticeClient {
    // Notifications
    func listNotifyChannels() async throws -> [NotifyChannel] {
        try await perform([NotifyChannel].self, path: "/api/notify/channels")
    }

    func listNotifyRules() async throws -> [NotifyRule] {
        let data = try await performData(path: "/api/notify/rules")
        let envelope = (try? JSONDecoder().decode(RulesEnvelope.self, from: data)) ?? RulesEnvelope(rules: [])
        return envelope.rules
    }

    func deleteNotifyChannel(id: String) async throws {
        try await performVoid(path: "/api/notify/channels/delete", body: MachineDeleteRequest(id: id))
    }

    func deleteNotifyRule(id: String) async throws {
        try await performVoid(path: "/api/notify/rules/delete", body: MachineDeleteRequest(id: id))
    }

    func testNotifyChannel(channelID: String, title: String, body: String) async throws {
        try await performVoid(
            path: "/api/notify/test",
            body: NotifyTestRequest(channel: channelID, config: [:], title: title, body: body)
        )
    }
}
