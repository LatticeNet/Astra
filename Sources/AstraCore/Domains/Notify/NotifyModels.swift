import Foundation

public struct NotifyChannel: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var configKeys: [String]
    public var enabled: Bool
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(id: String, name: String = "", kind: String = "", configKeys: [String] = [], enabled: Bool = false, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.configKeys = configKeys
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayName: String { name.isEmpty ? id : name }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, enabled
        case configKeys = "config_keys"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        configKeys = try container.decodeIfPresent([String].self, forKey: .configKeys) ?? []
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        createdAt = try DateValue.decodeIfPresent(from: container, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: container, forKey: .updatedAt)
    }
}

public struct NotifyRule: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var eventTypes: [String]
    public var channelIDs: [String]
    public var titleTemplate: String
    public var bodyTemplate: String
    public var enabled: Bool
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(id: String, name: String = "", eventTypes: [String] = [], channelIDs: [String] = [], titleTemplate: String = "", bodyTemplate: String = "", enabled: Bool = false, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.eventTypes = eventTypes
        self.channelIDs = channelIDs
        self.titleTemplate = titleTemplate
        self.bodyTemplate = bodyTemplate
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayName: String { name.isEmpty ? id : name }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled
        case eventTypes = "event_types"
        case channelIDs = "channel_ids"
        case titleTemplate = "title_template"
        case bodyTemplate = "body_template"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        eventTypes = try container.decodeIfPresent([String].self, forKey: .eventTypes) ?? []
        channelIDs = try container.decodeIfPresent([String].self, forKey: .channelIDs) ?? []
        titleTemplate = try container.decodeIfPresent(String.self, forKey: .titleTemplate) ?? ""
        bodyTemplate = try container.decodeIfPresent(String.self, forKey: .bodyTemplate) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        createdAt = try DateValue.decodeIfPresent(from: container, forKey: .createdAt)
        updatedAt = try DateValue.decodeIfPresent(from: container, forKey: .updatedAt)
    }
}
