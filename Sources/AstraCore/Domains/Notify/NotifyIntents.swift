import Foundation

/// Every notify write the phone makes, at the tier the parity matrix gives
/// it (section 3.2): channel test T2, channel delete T4, witness plan P,
/// webhook test T2, webhook delete T4. Each runs through `ActionRunner`;
/// none is ever sent from a deep link, a launch or a poll. Channel and rule
/// authoring, the notify:send test, and webhook create, edit and rotate are
/// web-only and have no intent.
public enum NotifyIntents {
    /// Every notify read and write requires it (`withAuth("notify:admin")`).
    public static let adminScope = "notify:admin"
    /// Filing a witness plan also needs node:admin and network:plan on the node.
    public static let witnessScopes = ["notify:admin", "node:admin", "network:plan"]

    public static func object(_ channel: NotifyChannel) -> ObjectRef {
        ObjectRef(kind: "channel", id: channel.id, name: channel.displayName)
    }

    public static func object(_ webhook: NotifyWebhook) -> ObjectRef {
        ObjectRef(kind: "webhook", id: webhook.id, name: webhook.displayName)
    }

    // MARK: Channels

    /// T2. The server sends its own fixed message through the stored
    /// channel; the key never leaves the server and no text can be chosen.
    public static func testChannel(_ channel: NotifyChannel) -> WriteIntent {
        let object = object(channel)
        return WriteIntent(
            tier: .t2, verb: "Send a test through", object: object, scopes: [adminScope],
            consequence: "Sends Lattice's fixed test message through \(object.name) now, so whoever it reaches gets a notification. notify:admin.",
            verify: { client in
                let channels = try await client.listNotifyChannels()
                guard let fresh = channels.first(where: { $0.id == channel.id }) else { return "\(object.name) is no longer listed." }
                return "\(object.name) now reads \(NotifyChannelHealthLine.of(fresh.health).state.rawValue)."
            },
            idempotent: false, changes: [.notify],
            perform: { client, _ in
                outcome(ofChannelTest: try await client.notifyTestChannel(id: channel.id), channel: object)
            }
        )
    }

    /// A test the server sent is done; one that did not deliver is the
    /// answer the operator needed, so it is a refusal naming the cause.
    static func outcome(ofChannelTest result: NotifyChannelTestResult, channel: ObjectRef) -> WriteOutcome {
        if result.ok { return .done("Test sent through \(channel.name)") }
        let cause = result.delivery.flatMap(NotifySent.cause) ?? .failed
        let message = "The test did not deliver through \(channel.name): \(cause.sentence)."
        return .refused(.validation(message), message)
    }

    /// T4. Irreversible: rules lose the channel; the operator types the name
    /// when a rule would stop reaching anyone or the rules are unread.
    public static func deleteChannel(_ channel: NotifyChannel, rules: [NotifyRule]?, channels: [NotifyChannel]) -> WriteIntent {
        let object = object(channel)
        let impact = NotifyChannelDeleteImpact.of(channel, rules: rules, channels: channels)
        let consequence = (["Deletes \(object.name) and its stored settings. This cannot be undone."] + impact.sentences(channel: object.name)).joined(separator: " ")
        return WriteIntent(
            tier: .t4, verb: "Delete channel", object: object, scopes: [adminScope],
            consequence: consequence,
            confirmPhrase: impact.typed ? object.name : nil,
            verify: { client in
                try await client.listNotifyChannels().contains { $0.id == channel.id } ? "\(object.name) is still listed." : "\(object.name) is no longer listed."
            },
            idempotent: false, changes: [.notify],
            perform: { client, _ in
                try await client.deleteNotifyChannel(id: channel.id)
                return .done("Deleted channel \(object.name)")
            }
        )
    }

    // MARK: Witness

    /// P. Files a configure plan with the server's defaults for everything
    /// but the node, the Bark channel and the local bark-server URL. Nothing
    /// changes on the node until someone approves it.
    public static func planWitness(node: ObjectRef, channel: NotifyChannel, barkURL: String, status: NotifyWitnessStatus) -> WriteIntent {
        let d = status.defaults
        let watches = status.healthURL.isEmpty ? "the URL its plan names" : status.healthURL
        return WriteIntent(
            tier: .plan, verb: "Plan the witness on", object: node, scopes: witnessScopes,
            consequence: "Files a plan that installs the control-plane witness on \(node.name). Every \(d.intervalSeconds) s it asks \(watches); after \(d.holdSeconds) s of failures it pushes one Bark alert (level \(d.barkLevel)) with \(channel.displayName)'s device key through \(barkURL). Nothing changes on the node until the plan is approved.",
            affected: [node], changes: [.approvals, .notify],
            perform: { client, _ in
                try await filed(client.notifyPlanWitness(.configure(nodeID: node.id, channelID: channel.id, barkURL: barkURL)))
            }
        )
    }

    /// P. Files a plan that removes the witness from a node.
    public static func removeWitness(node: ObjectRef) -> WriteIntent {
        WriteIntent(
            tier: .plan, verb: "Plan removing the witness from", object: node, scopes: witnessScopes,
            consequence: "Files a plan that stops the witness on \(node.name) and deletes its unit, config, device key and status. After it is applied, nothing outside watches the control plane from there.",
            affected: [node], changes: [.approvals, .notify],
            perform: { client, _ in
                try await filed(client.notifyPlanWitness(.remove(nodeID: node.id)))
            }
        )
    }

    static func filed(_ approval: Approval) -> WriteOutcome {
        .filed(approvalIDs: [approval.id], refused: [], notes: [])
    }

    // MARK: Webhooks

    /// T2. Fires the webhook through the same path a caller uses, with no
    /// data fields, so the event, the rules and the channels are exercised.
    public static func testWebhook(_ webhook: NotifyWebhook) -> WriteIntent {
        let object = object(webhook)
        return WriteIntent(
            tier: .t2, verb: "Send a test of", object: object, scopes: [adminScope],
            consequence: "Raises \(webhook.eventType) now with no data fields; every channel a rule routes it to gets a notification. notify:admin.",
            idempotent: false, changes: [.webhooks, .notify],
            perform: { client, _ in
                outcome(ofWebhookTest: try await client.notifyTestWebhook(id: webhook.id), webhook: object)
            }
        )
    }

    static func outcome(ofWebhookTest attempt: NotifyWebhookDelivery, webhook: ObjectRef) -> WriteOutcome {
        switch attempt.outcome {
        case "accepted":
            let planned = attempt.channels == 1 ? "1 channel delivery" : "\(attempt.channels) channel deliveries"
            return .done("Test of \(webhook.name) accepted, \(planned) planned")
        case "no_route":
            let message = "Test of \(webhook.name) accepted, but no rule and channel matched, so nothing was sent."
            return .partial(succeeded: [], failed: [ObjectFailure(object: webhook, reason: "No rule and channel matched")], message: message)
        case "partial":
            let message = "Test of \(webhook.name) delivered to \(attempt.delivered) of \(attempt.channels) channels."
            return .partial(succeeded: [], failed: [ObjectFailure(object: webhook, reason: attempt.reason.isEmpty ? "Some channels failed" : attempt.reason)], message: message)
        default:
            let why = attempt.reason.isEmpty ? NotifyWebhookAttempt.word(attempt.outcome) : attempt.reason
            let message = "Test of \(webhook.name) not delivered: \(why)."
            return .refused(.validation(message), message)
        }
    }

    /// T4. Irreversible: the webhook and its attempt history go, and its URL
    /// stops working. The operator types the name, as on the console.
    public static func deleteWebhook(_ webhook: NotifyWebhook) -> WriteIntent {
        let object = object(webhook)
        return WriteIntent(
            tier: .t4, verb: "Delete webhook", object: object, scopes: [adminScope],
            consequence: "\(object.name) and its attempt history are removed, and its URL stops working: every caller using it starts failing. This cannot be undone.",
            confirmPhrase: object.name,
            verify: { client in
                try await client.notifyListWebhooks().contains { $0.id == webhook.id } ? "\(object.name) is still listed." : "\(object.name) is no longer listed."
            },
            idempotent: false, changes: [.webhooks, .notify],
            perform: { client, _ in
                try await client.notifyDeleteWebhook(id: webhook.id)
                return .done("Deleted webhook \(object.name)")
            }
        )
    }
}
