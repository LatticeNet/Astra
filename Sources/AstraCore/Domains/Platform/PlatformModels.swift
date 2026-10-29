import Foundation

// Plugins, publishing, storage, the store and the control plane's own health
// (M8). Every decoder is tolerant: unknown fields are ignored and missing
// ones take a neutral default, so an additive server change never breaks a
// read. Go writes a zero `time.Time` without `omitzero` as year 1, which
// reads as no date here.

/// A date from a Go `time.Time`, or nil for a missing or zero one.
func platformDate<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Date? {
    guard let date = try? DateValue.decodeIfPresent(from: container, forKey: key),
          date.timeIntervalSince1970 > 0 else { return nil }
    return date
}

// MARK: - Plugins

/// One method of a plugin interface. Older manifests list bare names; v2
/// manifests list `{name, effect, scopes}`.
public struct PlatformInterfaceMethod: Decodable, Hashable, Sendable {
    public var name: String
    /// "read", "write" or "plan"; empty for a bare name.
    public var effect: String
    public var scopes: [String]

    public init(name: String, effect: String = "", scopes: [String] = []) {
        self.name = name
        self.effect = effect
        self.scopes = scopes
    }

    enum CodingKeys: String, CodingKey { case name, effect, scopes }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let bare = try? single.decode(String.self) {
            self.init(name: bare)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
                  effect: try c.decodeIfPresent(String.self, forKey: .effect) ?? "",
                  scopes: try c.decodeIfPresent([String].self, forKey: .scopes) ?? [])
    }
}

/// An interface a plugin exposes through `/api/plugins/call`.
public struct PlatformInterface: Decodable, Hashable, Sendable {
    public var service: String
    public var methods: [PlatformInterfaceMethod]
    public var scopes: [String]
    /// "runtime" (the plugin's own artifact) or "core"; empty on old manifests.
    public var backing: String

    public init(service: String, methods: [PlatformInterfaceMethod] = [], scopes: [String] = [], backing: String = "") {
        self.service = service
        self.methods = methods
        self.scopes = scopes
        self.backing = backing
    }

    enum CodingKeys: String, CodingKey { case service, methods, scopes, backing }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        service = try c.decodeIfPresent(String.self, forKey: .service) ?? ""
        methods = try c.decodeIfPresent([PlatformInterfaceMethod].self, forKey: .methods) ?? []
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
        backing = try c.decodeIfPresent(String.self, forKey: .backing) ?? ""
    }

    /// The console's `interfaceMethodScopes`: a typed method's own scopes,
    /// else the interface's.
    public func scopes(for method: String) -> [String] {
        if let typed = methods.first(where: { $0.name == method }), !typed.scopes.isEmpty {
            return typed.scopes
        }
        return scopes
    }
}

/// A sidebar entry a plugin contributes, mounted at `/plugins/<id>/<route>`.
public struct PlatformNavEntry: Decodable, Hashable, Sendable {
    public var section: String
    public var sectionTitle: String
    public var title: String
    public var route: String
    public var icon: String
    public var scopes: [String]

    public init(section: String = "", sectionTitle: String = "", title: String, route: String, icon: String = "", scopes: [String] = []) {
        self.section = section
        self.sectionTitle = sectionTitle
        self.title = title
        self.route = route
        self.icon = icon
        self.scopes = scopes
    }

    enum CodingKeys: String, CodingKey {
        case section, title, route, icon, scopes
        case sectionTitle = "section_title"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        section = try c.decodeIfPresent(String.self, forKey: .section) ?? ""
        sectionTitle = try c.decodeIfPresent(String.self, forKey: .sectionTitle) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        route = try c.decodeIfPresent(String.self, forKey: .route) ?? ""
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? ""
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
    }
}

/// The interface method a view reads its data from.
public struct PlatformViewSource: Decodable, Hashable, Sendable {
    public var interface: String
    public var method: String

    public init(interface: String, method: String) {
        self.interface = interface
        self.method = method
    }
}

/// One table column; `render` picks a safe formatter.
public struct PlatformViewColumn: Decodable, Hashable, Sendable {
    public var key: String
    public var label: String
    public var render: String

    public init(key: String, label: String = "", render: String = "") {
        self.key = key
        self.label = label
        self.render = render
    }

    enum CodingKeys: String, CodingKey { case key, label, render }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        render = try c.decodeIfPresent(String.self, forKey: .render) ?? ""
    }
}

/// One input of an action form.
public struct PlatformFormField: Decodable, Hashable, Sendable {
    public var key: String
    public var label: String
    public var kind: String
    public var options: [String]

    enum CodingKeys: String, CodingKey { case key, label, kind, options }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
    }
}

/// A button that calls an interface method. The phone never runs these:
/// manifest actions that write stay on the web (section 5.9).
public struct PlatformViewAction: Decodable, Hashable, Sendable {
    public var label: String
    public var interface: String
    public var method: String
    public var form: [PlatformFormField]
    public var scopes: [String]

    public init(label: String, interface: String, method: String, scopes: [String] = []) {
        self.label = label
        self.interface = interface
        self.method = method
        self.form = []
        self.scopes = scopes
    }

    enum CodingKeys: String, CodingKey { case label, interface, method, form, scopes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        interface = try c.decodeIfPresent(String.self, forKey: .interface) ?? ""
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? ""
        form = try c.decodeIfPresent([PlatformFormField].self, forKey: .form) ?? []
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
    }
}

/// One declarative page a plugin contributes.
public struct PlatformViewContribution: Decodable, Hashable, Sendable {
    public var route: String
    public var title: String
    /// "table", "detail", "form", "kv", "markdown" or "sandbox".
    public var kind: String
    public var source: PlatformViewSource?
    public var columns: [PlatformViewColumn]
    public var actions: [PlatformViewAction]

    public init(route: String, title: String, kind: String, source: PlatformViewSource? = nil, columns: [PlatformViewColumn] = [], actions: [PlatformViewAction] = []) {
        self.route = route
        self.title = title
        self.kind = kind
        self.source = source
        self.columns = columns
        self.actions = actions
    }

    enum CodingKeys: String, CodingKey { case route, title, kind, source, columns, actions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        route = try c.decodeIfPresent(String.self, forKey: .route) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        source = try c.decodeIfPresent(PlatformViewSource.self, forKey: .source)
        columns = try c.decodeIfPresent([PlatformViewColumn].self, forKey: .columns) ?? []
        actions = try c.decodeIfPresent([PlatformViewAction].self, forKey: .actions) ?? []
    }
}

/// A plugin's dashboard contribution set.
public struct PlatformManifestUI: Decodable, Hashable, Sendable {
    public var nav: [PlatformNavEntry]
    public var views: [PlatformViewContribution]

    public init(nav: [PlatformNavEntry] = [], views: [PlatformViewContribution] = []) {
        self.nav = nav
        self.views = views
    }

    enum CodingKeys: String, CodingKey { case nav, views }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nav = try c.decodeIfPresent([PlatformNavEntry].self, forKey: .nav) ?? []
        views = try c.decodeIfPresent([PlatformViewContribution].self, forKey: .views) ?? []
    }
}

/// The sandboxed page runtime of a v2 plugin (web only on the phone).
public struct PlatformUIRuntime: Decodable, Hashable, Sendable {
    public var mode: String
    public var entryURL: String

    enum CodingKeys: String, CodingKey {
        case mode
        case entryURL = "entry_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
        entryURL = try c.decodeIfPresent(String.self, forKey: .entryURL) ?? ""
    }
}

/// `pluginView`: one row of `GET /api/plugins` (audit:read) and of
/// `GET /api/plugin-contributions` (any signed-in caller, active plugins
/// only, nav and views filtered by the caller's scopes).
public struct PlatformPlugin: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// "system", "wasm" or "worker".
    public var type: String
    public var version: String
    public var publisher: String
    public var capabilities: [String]
    public var status: String
    public var active: Bool
    /// Present only while the plugin is active.
    public var ui: PlatformManifestUI?
    public var interfaces: [PlatformInterface]
    public var uiRuntime: PlatformUIRuntime?

    public init(id: String, name: String, type: String = "", version: String = "", publisher: String = "", capabilities: [String] = [],
                status: String = "", active: Bool = false, ui: PlatformManifestUI? = nil, interfaces: [PlatformInterface] = [], uiRuntime: PlatformUIRuntime? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.version = version
        self.publisher = publisher
        self.capabilities = capabilities
        self.status = status
        self.active = active
        self.ui = ui
        self.interfaces = interfaces
        self.uiRuntime = uiRuntime
    }

    enum CodingKeys: String, CodingKey {
        case id, name, type, version, publisher, capabilities, status, active, ui, interfaces
        case uiRuntime = "ui_runtime"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher) ?? ""
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        ui = try c.decodeIfPresent(PlatformManifestUI.self, forKey: .ui)
        interfaces = try c.decodeIfPresent([PlatformInterface].self, forKey: .interfaces) ?? []
        uiRuntime = try c.decodeIfPresent(PlatformUIRuntime.self, forKey: .uiRuntime)
    }
}

/// `plugin.RuntimeStatus`: the public health of one plugin runtime.
public struct PlatformRuntimeStatus: Decodable, Hashable, Sendable {
    /// "armed", "stopping", "stopped", "degraded" or "failed".
    public var state: String
    public var runner: String
    public var message: String
    public var startedAt: Date?
    public var stoppedAt: Date?
    public var updatedAt: Date?

    public init(state: String, runner: String = "", message: String = "", startedAt: Date? = nil, stoppedAt: Date? = nil, updatedAt: Date? = nil) {
        self.state = state
        self.runner = runner
        self.message = message
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case state, runner, message
        case startedAt = "started_at", stoppedAt = "stopped_at", updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        runner = try c.decodeIfPresent(String.self, forKey: .runner) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        startedAt = platformDate(c, .startedAt)
        stoppedAt = platformDate(c, .stoppedAt)
        updatedAt = platformDate(c, .updatedAt)
    }
}

/// `pluginInstallationView`: one row of `GET /api/plugins/lifecycle`
/// (plugin:admin), and the answer of `POST /api/plugins/lifecycle`.
public struct PlatformInstallation: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var type: String
    public var version: String
    public var publisher: String
    public var capabilities: [String]
    public var artifactSHA256: String
    /// Whether the bundle is in the plugin directory and verified.
    public var available: Bool
    public var status: String
    public var runtime: PlatformRuntimeStatus?
    public var verifiedAt: Date?
    public var installedAt: Date?
    public var activatedAt: Date?
    public var disabledAt: Date?
    public var updatedAt: Date?

    public init(id: String, name: String, status: String, available: Bool = true, runtime: PlatformRuntimeStatus? = nil) {
        self.id = id
        self.name = name
        self.type = ""
        self.version = ""
        self.publisher = ""
        self.capabilities = []
        self.artifactSHA256 = ""
        self.available = available
        self.status = status
        self.runtime = runtime
    }

    enum CodingKeys: String, CodingKey {
        case id, name, type, version, publisher, capabilities, available, status, runtime
        case artifactSHA256 = "artifact_sha256"
        case verifiedAt = "verified_at", installedAt = "installed_at", activatedAt = "activated_at"
        case disabledAt = "disabled_at", updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher) ?? ""
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        artifactSHA256 = try c.decodeIfPresent(String.self, forKey: .artifactSHA256) ?? ""
        available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? false
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        runtime = try c.decodeIfPresent(PlatformRuntimeStatus.self, forKey: .runtime)
        verifiedAt = platformDate(c, .verifiedAt)
        installedAt = platformDate(c, .installedAt)
        activatedAt = platformDate(c, .activatedAt)
        disabledAt = platformDate(c, .disabledAt)
        updatedAt = platformDate(c, .updatedAt)
    }
}

// MARK: - Publishing

/// `publishingRecordView`: one published route.
public struct PlatformPublishingRecord: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    /// "kv", "static" or "plugin" (a subscription share or identity link).
    public var origin: String
    /// A bucket for kv and static; the owning share or identity id for plugin.
    public var bucket: String
    public var hostname: String
    public var anyHost: Bool
    public var pathPrefix: String
    public var enabled: Bool
    public var expiresAt: Date?
    /// Something outside the server depends on it; it cannot be moved or deleted.
    public var reserved: Bool
    public var shareID: String
    public var identityID: String
    /// The scope that edits this route ("kv:admin", "static:admin", "proxy:admin").
    public var adminScope: String

    public init(id: String, origin: String, bucket: String, hostname: String = "", anyHost: Bool = false, pathPrefix: String = "",
                enabled: Bool = true, expiresAt: Date? = nil, reserved: Bool = false, shareID: String = "", identityID: String = "", adminScope: String = "") {
        self.id = id
        self.origin = origin
        self.bucket = bucket
        self.hostname = hostname
        self.anyHost = anyHost
        self.pathPrefix = pathPrefix
        self.enabled = enabled
        self.expiresAt = expiresAt
        self.reserved = reserved
        self.shareID = shareID
        self.identityID = identityID
        self.adminScope = adminScope
    }

    enum CodingKeys: String, CodingKey {
        case id, origin, bucket, hostname, enabled, reserved
        case anyHost = "any_host", pathPrefix = "path_prefix", expiresAt = "expires_at"
        case shareID = "share_id", identityID = "identity_id", adminScope = "admin_scope"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? ""
        bucket = try c.decodeIfPresent(String.self, forKey: .bucket) ?? ""
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        anyHost = try c.decodeIfPresent(Bool.self, forKey: .anyHost) ?? false
        pathPrefix = try c.decodeIfPresent(String.self, forKey: .pathPrefix) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        expiresAt = platformDate(c, .expiresAt)
        reserved = try c.decodeIfPresent(Bool.self, forKey: .reserved) ?? false
        shareID = try c.decodeIfPresent(String.self, forKey: .shareID) ?? ""
        identityID = try c.decodeIfPresent(String.self, forKey: .identityID) ?? ""
        adminScope = try c.decodeIfPresent(String.self, forKey: .adminScope) ?? ""
    }
}

/// `GET /api/publishing/records`: the routes the caller may see, and which
/// origins it may see at all, so "no routes" and "not allowed" differ.
public struct PlatformPublishingList: Decodable, Hashable, Sendable {
    public var records: [PlatformPublishingRecord]
    public var origins: [String]

    public init(records: [PlatformPublishingRecord], origins: [String]) {
        self.records = records
        self.origins = origins
    }

    enum CodingKeys: String, CodingKey { case records, origins }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        records = try c.decodeIfPresent([PlatformPublishingRecord].self, forKey: .records) ?? []
        origins = try c.decodeIfPresent([String].self, forKey: .origins) ?? []
    }
}

/// The two storage kinds.
public enum PlatformStorageKind: String, Sendable, Hashable, CaseIterable, Codable {
    case kv, `static`

    public var title: String { self == .kv ? "KV" : "Static" }
    /// Lists buckets and reads entries.
    public var readScope: String { "\(rawValue):read" }
    /// Lists storage tokens, deletes bindings and revokes tokens (server_storage.go).
    public var adminScope: String { "\(rawValue):admin" }
}

/// A registered bucket (`model.StorageBucket`).
public struct PlatformStorageBucket: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var name: String
    public var displayName: String
    public var description: String
    public var indexDocument: String
    public var notFoundDocument: String
    public var createdAt: Date?
    public var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, kind, name, description
        case displayName = "display_name", indexDocument = "index_document", notFoundDocument = "not_found_document"
        case createdAt = "created_at", updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        indexDocument = try c.decodeIfPresent(String.self, forKey: .indexDocument) ?? ""
        notFoundDocument = try c.decodeIfPresent(String.self, forKey: .notFoundDocument) ?? ""
        createdAt = platformDate(c, .createdAt)
        updatedAt = platformDate(c, .updatedAt)
    }
}

/// Every bucket that exists, registered or not, with how much it holds.
public struct PlatformBucketInventoryEntry: Decodable, Hashable, Sendable, Identifiable {
    public var name: String
    public var kind: String
    public var entries: Int
    public var registered: Bool
    /// Typed private state the server owns; its contents are refused to every scope.
    public var reserved: Bool

    public var id: String { "\(kind):\(name)" }

    public init(name: String, kind: String, entries: Int = 0, registered: Bool = false, reserved: Bool = false) {
        self.name = name
        self.kind = kind
        self.entries = entries
        self.registered = registered
        self.reserved = reserved
    }

    enum CodingKeys: String, CodingKey { case name, kind, entries, registered, reserved }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        entries = try c.decodeIfPresent(Int.self, forKey: .entries) ?? 0
        registered = try c.decodeIfPresent(Bool.self, forKey: .registered) ?? false
        reserved = try c.decodeIfPresent(Bool.self, forKey: .reserved) ?? false
    }
}

/// `GET /api/storage/buckets?kind=`.
public struct PlatformBucketList: Decodable, Hashable, Sendable {
    public var buckets: [PlatformStorageBucket]
    public var inventory: [PlatformBucketInventoryEntry]

    enum CodingKeys: String, CodingKey { case buckets, inventory }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        buckets = try c.decodeIfPresent([PlatformStorageBucket].self, forKey: .buckets) ?? []
        inventory = try c.decodeIfPresent([PlatformBucketInventoryEntry].self, forKey: .inventory) ?? []
    }

    /// The inventory, falling back to the registered buckets on a server
    /// that predates it (entry counts unknown, shown as zero).
    public var allBuckets: [PlatformBucketInventoryEntry] {
        if !inventory.isEmpty { return inventory }
        return buckets.map { PlatformBucketInventoryEntry(name: $0.name, kind: $0.kind, registered: true) }
    }
}

/// A host binding that publishes a bucket (`model.StorageBinding`).
public struct PlatformStorageBinding: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var bucket: String
    public var hostname: String
    public var pathPrefix: String
    public var enabled: Bool
    public var createdAt: Date?
    public var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, kind, bucket, hostname, enabled
        case pathPrefix = "path_prefix", createdAt = "created_at", updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        bucket = try c.decodeIfPresent(String.self, forKey: .bucket) ?? ""
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        pathPrefix = try c.decodeIfPresent(String.self, forKey: .pathPrefix) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        createdAt = platformDate(c, .createdAt)
        updatedAt = platformDate(c, .updatedAt)
    }
}

/// `storageTokenView`: a bucket-scoped access token, never its secret.
public struct PlatformStorageToken: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String
    /// "read", "write" or "admin".
    public var access: String
    /// Empty means every bucket of the kind.
    public var buckets: [String]
    public var revokedAt: Date?
    public var lastUsedAt: Date?
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(id: String, name: String, kind: String, access: String, buckets: [String] = [], revokedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.access = access
        self.buckets = buckets
        self.revokedAt = revokedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, access, buckets
        case revokedAt = "revoked_at", lastUsedAt = "last_used_at", createdAt = "created_at", updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        access = try c.decodeIfPresent(String.self, forKey: .access) ?? ""
        buckets = try c.decodeIfPresent([String].self, forKey: .buckets) ?? []
        revokedAt = platformDate(c, .revokedAt)
        lastUsedAt = platformDate(c, .lastUsedAt)
        createdAt = platformDate(c, .createdAt)
        updatedAt = platformDate(c, .updatedAt)
    }

    public var isRevoked: Bool { revokedAt != nil }
}

/// Who produces a share's bytes (`model.ShareSource`).
public struct PlatformShareSource: Decodable, Hashable, Sendable {
    /// "plugin" or "core.proxy_user".
    public var kind: String
    public var pluginID: String
    public var subscriptionID: String
    public var proxyUserID: String
    public var identityID: String

    public init(kind: String, pluginID: String = "", subscriptionID: String = "", proxyUserID: String = "", identityID: String = "") {
        self.kind = kind
        self.pluginID = pluginID
        self.subscriptionID = subscriptionID
        self.proxyUserID = proxyUserID
        self.identityID = identityID
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case pluginID = "plugin_id", subscriptionID = "subscription_id", proxyUserID = "proxy_user_id", identityID = "identity_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        pluginID = try c.decodeIfPresent(String.self, forKey: .pluginID) ?? ""
        subscriptionID = try c.decodeIfPresent(String.self, forKey: .subscriptionID) ?? ""
        proxyUserID = try c.decodeIfPresent(String.self, forKey: .proxyUserID) ?? ""
        identityID = try c.decodeIfPresent(String.self, forKey: .identityID) ?? ""
    }

    public var isPlugin: Bool { kind == "plugin" }
}

/// A link's plugin render budget; exhausted means new renders answer a decoy.
public struct PlatformShareRenderBudget: Decodable, Hashable, Sendable {
    public var remaining: Int
    public var burst: Int
    public var perHour: Int
    public var exhausted: Bool
    public var refused: Int
    public var lastRefusedAt: Date?

    public init(remaining: Int, burst: Int, perHour: Int = 0, exhausted: Bool = false, refused: Int = 0) {
        self.remaining = remaining
        self.burst = burst
        self.perHour = perHour
        self.exhausted = exhausted
        self.refused = refused
    }

    enum CodingKeys: String, CodingKey {
        case remaining, burst, exhausted, refused
        case perHour = "per_hour", lastRefusedAt = "last_refused_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        remaining = try c.decodeIfPresent(Int.self, forKey: .remaining) ?? 0
        burst = try c.decodeIfPresent(Int.self, forKey: .burst) ?? 0
        perHour = try c.decodeIfPresent(Int.self, forKey: .perHour) ?? 0
        exhausted = try c.decodeIfPresent(Bool.self, forKey: .exhausted) ?? false
        refused = try c.decodeIfPresent(Int.self, forKey: .refused) ?? 0
        lastRefusedAt = platformDate(c, .lastRefusedAt)
    }
}

/// `shareView`: a subscription share. It never carries the token; the URL
/// comes only from the step-up reveal.
public struct PlatformShare: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    public var slug: String
    public var source: PlatformShareSource
    public var defaultFormat: String
    public var enabled: Bool
    public var createdAt: Date?
    public var updatedAt: Date?
    public var rotatedAt: Date?
    public var expiresAt: Date?
    public var updateIntervalHours: Int
    public var publishesFleetCredentials: Bool
    /// "fleet" or "unknown" when the fleet-feed guard found something; empty when clean.
    public var fleetFeedNow: String
    public var renderBudget: PlatformShareRenderBudget?

    public init(id: String, slug: String, source: PlatformShareSource, enabled: Bool = true, expiresAt: Date? = nil, updateIntervalHours: Int = 2) {
        self.id = id
        self.slug = slug
        self.source = source
        self.defaultFormat = ""
        self.enabled = enabled
        self.expiresAt = expiresAt
        self.updateIntervalHours = updateIntervalHours
        self.publishesFleetCredentials = false
        self.fleetFeedNow = ""
    }

    enum CodingKeys: String, CodingKey {
        case id, slug, source, enabled
        case defaultFormat = "default_format", createdAt = "created_at", updatedAt = "updated_at"
        case rotatedAt = "rotated_at", expiresAt = "expires_at", updateIntervalHours = "update_interval_hours"
        case publishesFleetCredentials = "publishes_fleet_credentials", fleetFeedNow = "fleet_feed_now", renderBudget = "render_budget"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        source = try c.decodeIfPresent(PlatformShareSource.self, forKey: .source) ?? PlatformShareSource(kind: "")
        defaultFormat = try c.decodeIfPresent(String.self, forKey: .defaultFormat) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        createdAt = platformDate(c, .createdAt)
        updatedAt = platformDate(c, .updatedAt)
        rotatedAt = platformDate(c, .rotatedAt)
        expiresAt = platformDate(c, .expiresAt)
        updateIntervalHours = try c.decodeIfPresent(Int.self, forKey: .updateIntervalHours) ?? 0
        publishesFleetCredentials = try c.decodeIfPresent(Bool.self, forKey: .publishesFleetCredentials) ?? false
        fleetFeedNow = try c.decodeIfPresent(String.self, forKey: .fleetFeedNow) ?? ""
        renderBudget = try c.decodeIfPresent(PlatformShareRenderBudget.self, forKey: .renderBudget)
    }

    /// The path a share answers on with its token left out.
    public var maskedPath: String { "/sub/\(slug)/…" }
}

/// `linkRevealView`: a share's secret URL, shown once.
public struct PlatformShareReveal: Decodable, Hashable, Sendable {
    public var kind: String
    public var id: String
    public var slug: String
    public var token: String
    public var path: String
    /// Absent when the server has no public URL configured.
    public var url: String

    enum CodingKeys: String, CodingKey { case kind, id, slug, token, path, url }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
    }

    /// The server's URL, else the path on the console origin (`revealedUrl`).
    public func fullURL(origin: URL?) -> String {
        if !url.isEmpty { return url }
        let base = origin?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        return base + path
    }
}

/// The answer of a forced share refresh.
public struct PlatformShareRefresh: Decodable, Hashable, Sendable {
    public var fetchedAt: Date?
    public var bytes: Int
    /// The fetch failed and an older snapshot is still served.
    public var stale: Bool
    public var error: String

    enum CodingKeys: String, CodingKey {
        case bytes, stale, error
        case fetchedAt = "fetched_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = platformDate(c, .fetchedAt)
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
    }
}

// MARK: - Store

/// One KV key as a list row. The value is dropped at decode time and loaded
/// again only when the operator asks for it (M8-10: never cached).
public struct PlatformKVKey: Decodable, Hashable, Sendable, Identifiable {
    public var bucket: String
    public var key: String
    /// The value's size in UTF-8 bytes.
    public var size: Int
    public var updatedAt: Date?

    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case bucket, key, value
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bucket = try c.decodeIfPresent(String.self, forKey: .bucket) ?? ""
        key = try c.decode(String.self, forKey: .key)
        size = (try c.decodeIfPresent(String.self, forKey: .value) ?? "").utf8.count
        updatedAt = platformDate(c, .updatedAt)
    }
}

/// One static object as a list row, without its content.
public struct PlatformStaticObject: Decodable, Hashable, Sendable, Identifiable {
    public var bucket: String
    public var path: String
    public var contentType: String
    public var size: Int
    public var updatedAt: Date?
    /// False when the server stripped the bytes (the agent release bucket).
    public var hasContent: Bool

    public var id: String { path }

    enum CodingKeys: String, CodingKey {
        case bucket, path, content, size
        case contentType = "content_type", updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bucket = try c.decodeIfPresent(String.self, forKey: .bucket) ?? ""
        path = try c.decode(String.self, forKey: .path)
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType) ?? ""
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        updatedAt = platformDate(c, .updatedAt)
        hasContent = !(try c.decodeIfPresent(String.self, forKey: .content) ?? "").isEmpty
    }
}

/// A value loaded on tap for M8-10, held by the screen and nowhere else.
public struct PlatformStoreValue: Sendable, Hashable {
    public var text: String
    public var contentType: String
    public var size: Int

    public init(text: String, contentType: String, size: Int) {
        self.text = text
        self.contentType = contentType
        self.size = size
    }
}

// MARK: - System

/// The latest reading of the server process.
public struct PlatformSystemProcess: Decodable, Hashable, Sendable {
    public var startedAt: Date?
    public var uptimeSeconds: Int64
    public var version: String
    public var commit: String
    public var goVersion: String
    public var cpus: Int
    public var cpuPercent: Double?
    public var rssBytes: UInt64?
    public var heapBytes: UInt64
    public var goTotalBytes: UInt64
    public var goroutines: Int
    public var gcPauseMaxSeconds: Double
    public var openFDs: Int?

    enum CodingKeys: String, CodingKey {
        case version, commit, cpus, goroutines
        case startedAt = "started_at", uptimeSeconds = "uptime_seconds", goVersion = "go_version"
        case cpuPercent = "cpu_percent", rssBytes = "rss_bytes", heapBytes = "heap_bytes", goTotalBytes = "go_total_bytes"
        case gcPauseMaxSeconds = "gc_pause_max_seconds", openFDs = "open_fds"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = platformDate(c, .startedAt)
        uptimeSeconds = try c.decodeIfPresent(Int64.self, forKey: .uptimeSeconds) ?? 0
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        commit = try c.decodeIfPresent(String.self, forKey: .commit) ?? ""
        goVersion = try c.decodeIfPresent(String.self, forKey: .goVersion) ?? ""
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus) ?? 0
        cpuPercent = try c.decodeIfPresent(Double.self, forKey: .cpuPercent)
        rssBytes = try c.decodeIfPresent(UInt64.self, forKey: .rssBytes)
        heapBytes = try c.decodeIfPresent(UInt64.self, forKey: .heapBytes) ?? 0
        goTotalBytes = try c.decodeIfPresent(UInt64.self, forKey: .goTotalBytes) ?? 0
        goroutines = try c.decodeIfPresent(Int.self, forKey: .goroutines) ?? 0
        gcPauseMaxSeconds = try c.decodeIfPresent(Double.self, forKey: .gcPauseMaxSeconds) ?? 0
        openFDs = try c.decodeIfPresent(Int.self, forKey: .openFDs)
    }
}

/// The host the control plane runs on; each reading is absent where the
/// platform does not report it.
public struct PlatformSystemHost: Decodable, Hashable, Sendable {
    public var load1: Double?
    public var load5: Double?
    public var load15: Double?
    public var memTotalBytes: UInt64?
    public var memAvailableBytes: UInt64?
    public var dataDir: String
    public var diskTotalBytes: UInt64?
    public var diskFreeBytes: UInt64?
    public var diskUsedBytes: UInt64?

    enum CodingKeys: String, CodingKey {
        case load1, load5, load15
        case memTotalBytes = "mem_total_bytes", memAvailableBytes = "mem_available_bytes", dataDir = "data_dir"
        case diskTotalBytes = "disk_total_bytes", diskFreeBytes = "disk_free_bytes", diskUsedBytes = "disk_used_bytes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        load1 = try c.decodeIfPresent(Double.self, forKey: .load1)
        load5 = try c.decodeIfPresent(Double.self, forKey: .load5)
        load15 = try c.decodeIfPresent(Double.self, forKey: .load15)
        memTotalBytes = try c.decodeIfPresent(UInt64.self, forKey: .memTotalBytes)
        memAvailableBytes = try c.decodeIfPresent(UInt64.self, forKey: .memAvailableBytes)
        dataDir = try c.decodeIfPresent(String.self, forKey: .dataDir) ?? ""
        diskTotalBytes = try c.decodeIfPresent(UInt64.self, forKey: .diskTotalBytes)
        diskFreeBytes = try c.decodeIfPresent(UInt64.self, forKey: .diskFreeBytes)
        diskUsedBytes = try c.decodeIfPresent(UInt64.self, forKey: .diskUsedBytes)
    }

    /// Used memory as a fraction, when both readings exist.
    public var memoryFraction: Double? {
        guard let total = memTotalBytes, let available = memAvailableBytes, total > 0 else { return nil }
        return Double(total - min(available, total)) / Double(total)
    }

    public var diskFraction: Double? {
        guard let total = diskTotalBytes, let used = diskUsedBytes, total > 0 else { return nil }
        return Double(used) / Double(total)
    }
}

/// A 48-bucket sparkline of a table row. Null values decode as nil.
public struct PlatformSystemSpark: Decodable, Hashable, Sendable {
    public var stepSeconds: Int64
    public var t: [Int64]
    public var n: [UInt32]
    public var e: [UInt32]
    public var p95: [Double?]
    public var avg: [Double?]

    public init(stepSeconds: Int64 = 0) {
        self.stepSeconds = stepSeconds
        t = []
        n = []
        e = []
        p95 = []
        avg = []
    }

    enum CodingKeys: String, CodingKey {
        case t, n, e, p95, avg
        case stepSeconds = "step_seconds"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stepSeconds = try c.decodeIfPresent(Int64.self, forKey: .stepSeconds) ?? 0
        t = try c.decodeIfPresent([Int64].self, forKey: .t) ?? []
        n = try c.decodeIfPresent([UInt32].self, forKey: .n) ?? []
        e = try c.decodeIfPresent([UInt32].self, forKey: .e) ?? []
        p95 = try c.decodeIfPresent([Double?].self, forKey: .p95) ?? []
        avg = try c.decodeIfPresent([Double?].self, forKey: .avg) ?? []
    }
}

/// Calls, failures and latency of one HTTP route group, store caller or plugin method.
public struct PlatformSystemEventRow: Decodable, Hashable, Sendable, Identifiable {
    public var plugin: String
    public var name: String
    public var calls: UInt64
    public var errors: UInt64
    public var perMinute: Double
    public var p50Seconds: Double
    public var p95Seconds: Double
    public var maxSeconds: Double
    public var avgSeconds: Double
    public var spark: PlatformSystemSpark

    public var id: String { plugin.isEmpty ? name : "\(plugin)/\(name)" }

    enum CodingKeys: String, CodingKey {
        case plugin, name, calls, errors, spark
        case perMinute = "per_minute", p50Seconds = "p50_seconds", p95Seconds = "p95_seconds"
        case maxSeconds = "max_seconds", avgSeconds = "avg_seconds"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plugin = try c.decodeIfPresent(String.self, forKey: .plugin) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        calls = try c.decodeIfPresent(UInt64.self, forKey: .calls) ?? 0
        errors = try c.decodeIfPresent(UInt64.self, forKey: .errors) ?? 0
        perMinute = try c.decodeIfPresent(Double.self, forKey: .perMinute) ?? 0
        p50Seconds = try c.decodeIfPresent(Double.self, forKey: .p50Seconds) ?? 0
        p95Seconds = try c.decodeIfPresent(Double.self, forKey: .p95Seconds) ?? 0
        maxSeconds = try c.decodeIfPresent(Double.self, forKey: .maxSeconds) ?? 0
        avgSeconds = try c.decodeIfPresent(Double.self, forKey: .avgSeconds) ?? 0
        spark = try c.decodeIfPresent(PlatformSystemSpark.self, forKey: .spark) ?? PlatformSystemSpark()
    }
}

/// One data file of the control plane.
public struct PlatformSystemFile: Decodable, Hashable, Sendable, Identifiable {
    public var label: String
    public var path: String
    public var sizeBytes: Int64?
    public var spark: PlatformSystemSpark

    public var id: String { label }

    enum CodingKeys: String, CodingKey {
        case label, path, spark
        case sizeBytes = "size_bytes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        spark = try c.decodeIfPresent(PlatformSystemSpark.self, forKey: .spark) ?? PlatformSystemSpark()
    }
}

/// What each plugin's processes used over the range, counted as they exited.
public struct PlatformPluginProcess: Decodable, Hashable, Sendable, Identifiable {
    public var plugin: String
    public var processes: UInt64
    public var cpuSeconds: Double
    public var peakRSSBytes: Double

    public var id: String { plugin }

    enum CodingKeys: String, CodingKey {
        case plugin, processes
        case cpuSeconds = "cpu_seconds", peakRSSBytes = "peak_rss_bytes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plugin = try c.decodeIfPresent(String.self, forKey: .plugin) ?? ""
        processes = try c.decodeIfPresent(UInt64.self, forKey: .processes) ?? 0
        cpuSeconds = try c.decodeIfPresent(Double.self, forKey: .cpuSeconds) ?? 0
        peakRSSBytes = try c.decodeIfPresent(Double.self, forKey: .peakRSSBytes) ?? 0
    }
}

/// The metrics store's account of itself.
public struct PlatformMetricsStore: Decodable, Hashable, Sendable {
    public var path: String
    public var sizeBytes: Int64
    public var series: Int
    public var maxSeries: Int
    public var owners: Int
    public var refusedSamples: UInt64
    public var lateSamples: UInt64
    public var lastWriteAt: Date?
    public var lastWriteError: String
    public var sampleSeconds: Int64

    enum CodingKeys: String, CodingKey {
        case path, series, owners
        case sizeBytes = "size_bytes", maxSeries = "max_series", refusedSamples = "refused_samples", lateSamples = "late_samples"
        case lastWriteAt = "last_write_at", lastWriteError = "last_write_error", sampleSeconds = "sample_seconds"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
        series = try c.decodeIfPresent(Int.self, forKey: .series) ?? 0
        maxSeries = try c.decodeIfPresent(Int.self, forKey: .maxSeries) ?? 0
        owners = try c.decodeIfPresent(Int.self, forKey: .owners) ?? 0
        refusedSamples = try c.decodeIfPresent(UInt64.self, forKey: .refusedSamples) ?? 0
        lateSamples = try c.decodeIfPresent(UInt64.self, forKey: .lateSamples) ?? 0
        lastWriteAt = platformDate(c, .lastWriteAt)
        lastWriteError = try c.decodeIfPresent(String.self, forKey: .lastWriteError) ?? ""
        sampleSeconds = try c.decodeIfPresent(Int64.self, forKey: .sampleSeconds) ?? 0
    }
}

/// lattice-probe's health: available with its versions, or why not.
public struct PlatformProbeHealth: Decodable, Hashable, Sendable {
    public var available: Bool
    public var reason: String
    public var probeVersion: String
    public var engine: String
    public var coreVersion: String
    public var uptimeSeconds: Double
    public var inflight: Int
    public var maxInflight: Int
    public var targets: Int

    enum CodingKeys: String, CodingKey {
        case available, reason, engine, inflight, targets
        case probeVersion = "probe_version", coreVersion = "core_version", uptimeSeconds = "uptime_s", maxInflight = "max_inflight"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        probeVersion = try c.decodeIfPresent(String.self, forKey: .probeVersion) ?? ""
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? ""
        coreVersion = try c.decodeIfPresent(String.self, forKey: .coreVersion) ?? ""
        uptimeSeconds = try c.decodeIfPresent(Double.self, forKey: .uptimeSeconds) ?? 0
        inflight = try c.decodeIfPresent(Int.self, forKey: .inflight) ?? 0
        maxInflight = try c.decodeIfPresent(Int.self, forKey: .maxInflight) ?? 0
        targets = try c.decodeIfPresent(Int.self, forKey: .targets) ?? 0
    }
}

/// `GET /api/system/health`: the control plane's own health (full administrator only).
public struct PlatformSystemHealth: Decodable, Hashable, Sendable {
    public var observedAt: Date?
    public var range: String
    public var process: PlatformSystemProcess?
    public var host: PlatformSystemHost?
    public var files: [PlatformSystemFile]
    public var store: [PlatformSystemEventRow]
    public var http: [PlatformSystemEventRow]
    public var plugins: [PlatformSystemEventRow]
    public var pluginProcesses: [PlatformPluginProcess]
    public var metricsStore: PlatformMetricsStore?
    public var probe: PlatformProbeHealth?

    enum CodingKeys: String, CodingKey {
        case range, process, host, files, store, http, plugins, probe
        case observedAt = "observed_at", pluginProcesses = "plugin_processes", metricsStore = "metrics_store"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        observedAt = platformDate(c, .observedAt)
        range = try c.decodeIfPresent(String.self, forKey: .range) ?? ""
        process = try c.decodeIfPresent(PlatformSystemProcess.self, forKey: .process)
        host = try c.decodeIfPresent(PlatformSystemHost.self, forKey: .host)
        files = try c.decodeIfPresent([PlatformSystemFile].self, forKey: .files) ?? []
        store = try c.decodeIfPresent([PlatformSystemEventRow].self, forKey: .store) ?? []
        http = try c.decodeIfPresent([PlatformSystemEventRow].self, forKey: .http) ?? []
        plugins = try c.decodeIfPresent([PlatformSystemEventRow].self, forKey: .plugins) ?? []
        pluginProcesses = try c.decodeIfPresent([PlatformPluginProcess].self, forKey: .pluginProcesses) ?? []
        metricsStore = try c.decodeIfPresent(PlatformMetricsStore.self, forKey: .metricsStore)
        probe = try c.decodeIfPresent(PlatformProbeHealth.self, forKey: .probe)
    }
}

/// One columnar series of `GET /api/system/series`. A bucket nothing was
/// recorded in is absent, so `t` values further apart than the step are a gap.
public struct PlatformMetricSeries: Decodable, Hashable, Sendable, Identifiable {
    public var name: String
    /// "gauge" or "event".
    public var kind: String
    public var unit: String
    public var t: [Int64]
    public var avg: [Double?]
    public var min: [Double?]
    public var max: [Double?]
    public var n: [UInt32]

    public var id: String { name }

    public init(name: String, kind: String = "gauge", unit: String = "", t: [Int64], avg: [Double?]) {
        self.name = name
        self.kind = kind
        self.unit = unit
        self.t = t
        self.avg = avg
        self.min = avg
        self.max = avg
        self.n = Array(repeating: 1, count: t.count)
    }

    enum CodingKeys: String, CodingKey { case name, kind, unit, t, avg, min, max, n }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        t = try c.decodeIfPresent([Int64].self, forKey: .t) ?? []
        avg = try c.decodeIfPresent([Double?].self, forKey: .avg) ?? []
        min = try c.decodeIfPresent([Double?].self, forKey: .min) ?? []
        max = try c.decodeIfPresent([Double?].self, forKey: .max) ?? []
        n = try c.decodeIfPresent([UInt32].self, forKey: .n) ?? []
    }
}

/// `metricsQueryView`.
public struct PlatformMetricsQuery: Decodable, Hashable, Sendable {
    public var owner: String
    public var tier: String
    public var resolutionSeconds: Int64
    public var stepSeconds: Int64
    public var from: Date?
    public var to: Date?
    public var retainedFrom: Date?
    public var series: [PlatformMetricSeries]

    enum CodingKeys: String, CodingKey {
        case owner, tier, from, to, series
        case resolutionSeconds = "resolution_seconds", stepSeconds = "step_seconds", retainedFrom = "retained_from"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
        tier = try c.decodeIfPresent(String.self, forKey: .tier) ?? ""
        resolutionSeconds = try c.decodeIfPresent(Int64.self, forKey: .resolutionSeconds) ?? 0
        stepSeconds = try c.decodeIfPresent(Int64.self, forKey: .stepSeconds) ?? 0
        from = platformDate(c, .from)
        to = platformDate(c, .to)
        retainedFrom = platformDate(c, .retainedFrom)
        series = try c.decodeIfPresent([PlatformMetricSeries].self, forKey: .series) ?? []
    }

    public func series(named name: String) -> PlatformMetricSeries? {
        series.first { $0.name == name }
    }
}
