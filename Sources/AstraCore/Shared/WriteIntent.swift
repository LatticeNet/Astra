import Foundation

/// The confirmation tier of a write (section 6.5). Decisions and reveals do
/// not use `WriteIntent`.
public enum WriteTier: Sendable, Hashable {
    case t1, t2, t3, t4, plan
}

/// Which client a write or reveal runs on: the PAT client, or the signed-in
/// session (step-up reveals and session-only account endpoints).
public enum ClientKind: Sendable, Hashable {
    case primary, session
}

/// The object a write names, shown before the request and in the outcome.
public struct ObjectRef: Sendable, Hashable, Identifiable {
    /// "node", "incident", "check", "approval" and so on.
    public var kind: String
    public var id: String
    /// The name the operator recognizes ("edge-tyo-3"); falls back to the id.
    public var name: String

    public init(kind: String, id: String, name: String? = nil) {
        self.kind = kind
        self.id = id
        self.name = (name?.isEmpty == false ? name : nil) ?? id
    }
}

/// An explicit acceptance the operator must tick ("Accept lockout risk").
public struct ConfirmToggle: Sendable, Hashable {
    /// The flag the request sends when checked: "accept_lockout_risk".
    public var id: String
    public var label: String
    public var consequence: String
    /// Shown only after a 409 with findings.
    public var revealedByConflict: Bool

    public init(id: String, label: String, consequence: String, revealedByConflict: Bool = false) {
        self.id = id
        self.label = label
        self.consequence = consequence
        self.revealedByConflict = revealedByConflict
    }
}

/// The ids of the toggles the operator checked.
public struct ConfirmChoices: Sendable, Hashable {
    public var accepted: Set<String>

    public init(accepted: Set<String> = []) {
        self.accepted = accepted
    }

    public func isAccepted(_ toggleID: String) -> Bool {
        accepted.contains(toggleID)
    }
}

/// One line of a dry run: a label, its value, and the consequence group it
/// is listed under ("Services", "Configuration", "History").
public struct DetailLine: Sendable, Hashable {
    public var label: String
    public var value: String
    public var group: String?

    public init(label: String, value: String, group: String? = nil) {
        self.label = label
        self.value = value
        self.group = group
    }
}

/// What a write would change, from the server's dry run where it has one.
public struct DryRunReport: Sendable, Hashable {
    public var lines: [DetailLine]
    /// True disables the primary action.
    public var blocking: Bool
    /// Re-checked immediately before send; a change stops the write.
    public var fingerprint: String

    public init(lines: [DetailLine], blocking: Bool = false, fingerprint: String) {
        self.lines = lines
        self.blocking = blocking
        self.fingerprint = fingerprint
    }
}

/// What a write invalidates. `ActionRunner` bumps the kinds an intent
/// declares and screens refetch (sections 6.8 and 8.4).
public enum ChangeKind: String, Sendable, Hashable, CaseIterable {
    case approvals, incidents, maintenance, nodes, groups, gates, paths, checks, definitions
    case tasks, audit, machines, upcoming, policies, dns, ddns, geo, tunnels, netguard
    case sshguard, agentUpdates, plugins, publishing, store, notify, webhooks, evidence
    case account, tokens, terminal, vpn, session
}

/// Every write the app makes, run by one `ActionRunner` (section 8.3).
public struct WriteIntent: Sendable {
    public var tier: WriteTier
    public var client: ClientKind
    /// "Disable node".
    public var verb: String
    public var object: ObjectRef
    /// Every scope the write needs, evaluated on `client`.
    public var scopes: [String]
    /// One sentence.
    public var consequence: String
    /// Blast radius; for plan filing, the nodes the server will try.
    public var affected: [ObjectRef]
    public var toggles: [ConfirmToggle]
    /// T4: the operator types this (the object name).
    public var confirmPhrase: String?
    public var dryRun: (@Sendable (LatticeClient) async throws -> DryRunReport)?
    /// The post-state sentence for an `.unknown` outcome.
    public var verify: (@Sendable (LatticeClient) async throws -> String)?
    /// Verified inverses only (section 6.6).
    public var inverse: (@Sendable () -> WriteIntent)?
    public var idempotent: Bool
    public var changes: [ChangeKind]
    public var perform: @Sendable (LatticeClient, ConfirmChoices) async throws -> WriteOutcome

    public init(
        tier: WriteTier,
        client: ClientKind = .primary,
        verb: String,
        object: ObjectRef,
        scopes: [String],
        consequence: String,
        affected: [ObjectRef] = [],
        toggles: [ConfirmToggle] = [],
        confirmPhrase: String? = nil,
        dryRun: (@Sendable (LatticeClient) async throws -> DryRunReport)? = nil,
        verify: (@Sendable (LatticeClient) async throws -> String)? = nil,
        inverse: (@Sendable () -> WriteIntent)? = nil,
        idempotent: Bool = false,
        changes: [ChangeKind],
        perform: @escaping @Sendable (LatticeClient, ConfirmChoices) async throws -> WriteOutcome
    ) {
        self.tier = tier
        self.client = client
        self.verb = verb
        self.object = object
        self.scopes = scopes
        self.consequence = consequence
        self.affected = affected
        self.toggles = toggles
        self.confirmPhrase = confirmPhrase
        self.dryRun = dryRun
        self.verify = verify
        self.inverse = inverse
        self.idempotent = idempotent
        self.changes = changes
        self.perform = perform
    }

    /// The title of the confirmation and the Face ID reason: "Disable edge-tyo-3".
    public var title: String {
        "\(verb) \(object.name)"
    }

    public var requirement: ScopeRequirement {
        ScopeRequirement(groups: scopes.map { [$0] })
    }
}

/// Every reveal the app makes, run by `ActionRunner.reveal` (sections 6.4 and 8.3).
public struct RevealIntent: Sendable {
    public var purpose: StepUpPurpose
    public var object: ObjectRef
    /// Evaluated on the session's scopes.
    public var scopes: [String]
    /// Share URLs and VPN subscription links only.
    public var shareable: Bool
    public var perform: @Sendable (LatticeClient, StepUpGrant) async throws -> RevealedSecret

    public init(
        purpose: StepUpPurpose,
        object: ObjectRef,
        scopes: [String],
        shareable: Bool = false,
        perform: @escaping @Sendable (LatticeClient, StepUpGrant) async throws -> RevealedSecret
    ) {
        self.purpose = purpose
        self.object = object
        self.scopes = scopes
        self.shareable = shareable
        self.perform = perform
    }

    /// "Reveal the knock sequence for edge-tyo-3".
    public var title: String {
        "Reveal the \(purpose.secretName) for \(object.name)"
    }
}
