import Foundation
import AstraCore

public func checkNotify() async throws {
    try await checkNotifyDecoding()
    try await checkNotifyRequestBodies()
    try await checkNotifyIntentOutcomes()
    try checkNotifySentLog()
    try checkNotifyChannelHealth()
    try checkNotifyDeleteImpact()
    try checkNotifyRules()
    try checkNotifyWebhookRouting()
    try checkNotifyWitness()
    try await checkNotifyDemo()
}

private let notifyBase = "https://lattice.example.com"

private func notifyClient(_ responses: [String: (Int, Data)]) -> (LatticeClient, MockTransport) {
    let transport = MockTransport(responses: responses)
    let client = LatticeClient(baseURL: URL(string: notifyBase)!, credential: LatticeCredential(bearerToken: "lat_check.notasecret"), transport: transport)
    return (client, transport)
}

private func notifyInstant(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

private func notifyDelivery(_ text: String) throws -> NotifyDelivery {
    try JSONDecoder().decode(NotifyDelivery.self, from: json(text))
}

// MARK: Decoding

private func checkNotifyDecoding() async throws {
    let channels = json(#"""
    [{"id":"ch_bark","name":"Phone","kind":"bark","config_keys":["base_url","key"],"enabled":true,"created_at":"2026-09-01T10:00:00Z","updated_at":"2026-10-01T10:00:00Z",
      "health":{"state":"failing","last_attempt_at":"2026-10-28T11:50:00Z","last_ok_at":"2026-10-27T09:00:00Z","last_failure_at":"2026-10-28T11:50:00Z","last_failure_kind":"upstream_4xx","last_status_code":401,"consecutive_failures":4,"failing_since":"2026-10-28T09:00:00Z","last_fallback_at":"2026-10-28T09:05:00Z","last_fallback_channel_id":"ch_tg","fallbacks":2},
      "fallback_channel_id":"ch_tg","critical_event_types":["node.offline","service.down"]},
     {"id":"ch_old","name":"","kind":"discord","config_keys":[],"enabled":false,"created_at":"2026-09-01T10:00:00Z","updated_at":"2026-09-01T10:00:00Z"}]
    """#)
    let rules = json(#"""
    {"rules":[{"id":"r1","name":"Incidents","event_types":["node.offline"],"channel_ids":["ch_bark"],"enabled":true,"created_at":"2026-09-01T10:00:00Z","updated_at":"2026-09-01T10:00:00Z",
      "fallback_channel_id":"ch_tg","escalation_off":false,"escalate_after_minutes":30,"escalation_bark_level":"critical","quiet_hours":{"start":"23:00","end":"07:00","time_zone":"Asia/Shanghai"}},
     {"id":"r2","name":"All","enabled":false,"created_at":"2026-09-01T10:00:00Z","updated_at":"2026-09-01T10:00:00Z","escalation_off":true,"escalate_after_minutes":30,"escalation_bark_level":"critical","quiet_hours":null}]}
    """#)
    let catalogue = json(#"""
    {"categories":[{"id":"nodes","label":"Nodes"}],"types":[{"type":"node.offline","category":"nodes","severity":"critical","recovery":false,"icon":"server-off","description":"Node offline"}],
     "patterns":[{"pattern":"plugin.<id>.message","type":"plugin.<id>.message","category":"plugins","severity":"info","recovery":false,"icon":"puzzle","description":"Plugin message"}],
     "webhook_types":[{"type":"backup.finished","category":"webhooks","severity":"info","recovery":false,"icon":"webhook","description":"Inbound webhook event"}]}
    """#)
    let witness = json(#"""
    {"health_url":"https://lattice.example.com/readyz","nodes":[{"node_id":"n1","node_name":"home-nas","capable":true,
      "configured":{"approval_id":"a1","action":"configure","status":"applied","config_sha256":"abc","channel_id":"ch_bark","channel_name":"Phone","key_sha256_prefix":"9c41e07a","created_at":"2026-10-01T10:00:00Z","updated_at":"2026-10-01T11:00:00Z","health_url":"https://lattice.example.com/readyz"},
      "report":{"version":1,"config_sha256":"abc","started_at":"2026-10-01T11:00:00Z","phase":"down","last_check_at":"2026-10-28T11:59:30Z","last_check_ok":false,"last_check_detail":"timeout","failing_since":"2026-10-28T11:50:00Z","consecutive_failures":20,"alerted":true,"alerted_at":"2026-10-28T11:53:00Z","down_since":"2026-10-28T11:50:00Z","last_push_at":"2026-10-28T11:53:00Z","last_push_kind":"down","last_push_ok":false,"last_push_error":"http 500","pushes":3,"relayed_at":"2026-10-28T11:59:40Z"},
      "reported_at":"2026-10-28T11:59:45Z","report_fresh":true,"check_stale":false,"config_matches":true}],
     "capable_nodes":[{"node_id":"n1","node_name":"home-nas","online":true}],
     "defaults":{"reference_urls":["https://www.example.com/"],"interval_seconds":30,"hold_seconds":180,"recover_seconds":60,"bark_level":"critical","bark_levels":["active","critical"],"key_file":"/etc/k","config_file":"/etc/c","unit":"lattice-witness.service"}}
    """#)
    let webhooks = json(#"{"webhooks":[{"id":"wh_1","name":"Backup","event_type":"backup.finished","title_template":"Backup {{data.host}}","body_template":"","enabled":true,"path":"/api/hooks/wh_1","created_at":"2026-09-01T10:00:00Z","updated_at":"2026-09-02T10:00:00Z"}]}"#)
    let webhookDeliveries = json(#"{"deliveries":[{"id":"d1","webhook_id":"wh_1","event_type":"backup.finished","outcome":"partial","reason":"some channel sends failed","title":"Backup","source_ip":"192.0.2.1","fields":2,"bytes":40,"channels":2,"delivered":1,"created_at":"2026-10-28T10:00:00Z"},{"id":"d2","webhook_id":"wh_1","event_type":"backup.finished","outcome":"accepted","fields":0,"bytes":0,"channels":1,"delivered":1,"test":true,"created_at":"2026-10-27T10:00:00Z"}]}"#)
    let (client, transport) = notifyClient([
        "\(notifyBase)/api/notify/channels": (200, channels),
        "\(notifyBase)/api/notify/rules": (200, rules),
        "\(notifyBase)/api/notify/catalogue": (200, catalogue),
        "\(notifyBase)/api/notify/witness": (200, witness),
        "\(notifyBase)/api/notify/webhooks": (200, webhooks),
        "\(notifyBase)/api/notify/webhooks/deliveries?id=wh_1": (200, webhookDeliveries),
    ])

    let decodedChannels = try await client.listNotifyChannels()
    try expectEqual(decodedChannels.map(\.id), ["ch_bark", "ch_old"], "channels decode as a bare array")
    let bark = decodedChannels[0]
    try expectEqual(bark.health?.state, "failing", "channel health state")
    try expectEqual(bark.health?.consecutiveFailures, 4, "channel failure run")
    try expectEqual(bark.health?.lastStatusCode, 401, "channel last status code")
    try expectEqual(bark.health?.failingSince, notifyInstant("2026-10-28T09:00:00Z"), "channel failing since")
    try expectEqual(bark.health?.lastFallbackChannelID, "ch_tg", "last fallback channel")
    try expectEqual(bark.fallbackChannelID, "ch_tg", "channel fallback")
    try expectEqual(bark.criticalEventTypes, ["node.offline", "service.down"], "critical types come from the server")
    try expect(decodedChannels[1].health == nil, "a server without health reads as unreported")
    try expectEqual(decodedChannels[1].displayName, "ch_old", "an unnamed channel shows its id")

    let decodedRules = try await client.listNotifyRules()
    try expectEqual(decodedRules.map(\.id), ["r1", "r2"], "rules unwrapped from the envelope")
    try expectEqual(decodedRules[0].quietHours, NotifyQuietHours(start: "23:00", end: "07:00", timeZone: "Asia/Shanghai"), "quiet hours")
    try expect(decodedRules[1].quietHours == nil && decodedRules[1].escalationOff, "null quiet hours and escalation off")
    try expectEqual(decodedRules[1].eventTypes, [], "an omitted event list matches everything")

    let decodedCatalogue = try await client.notifyFetchCatalogue()
    try expectEqual(decodedCatalogue.label(for: "node.offline"), "Node offline", "exact catalogue entry")
    try expectEqual(decodedCatalogue.entry(for: "plugin.example-labs.reports.message")?.category, "plugins", "a plugin message uses the pattern")
    try expectEqual(decodedCatalogue.entry(for: "backup.finished")?.category, "webhooks", "a webhook type")
    try expectEqual(decodedCatalogue.label(for: "made.up"), "made.up", "an unknown type shows itself")
    try expect(NotifyCatalogue.isPluginMessage("plugin.message") && !NotifyCatalogue.isPluginMessage("plugin..message") && !NotifyCatalogue.isPluginMessage("plugin.health"), "plugin message shapes")

    let decodedWitness = try await client.notifyFetchWitness()
    try expectEqual(decodedWitness.nodes.first?.report?.phase, "down", "witness report phase")
    try expectEqual(decodedWitness.nodes.first?.configured?.keySHA256Prefix, "9c41e07a", "witness key prefix")
    try expectEqual(decodedWitness.capableNodes.map(\.nodeName), ["home-nas"], "capable nodes")
    try expectEqual(decodedWitness.defaults.holdSeconds, 180, "witness defaults")

    let decodedWebhooks = try await client.notifyListWebhooks()
    try expectEqual(decodedWebhooks.first?.path, "/api/hooks/wh_1", "webhook path")
    try expect(decodedWebhooks.first?.lastUsedAt == nil, "a never-called webhook has no last use")
    let attempts = try await client.notifyWebhookDeliveries(id: "wh_1")
    try expectEqual(attempts.map(\.outcome), ["partial", "accepted"], "webhook attempts newest first")
    try expect(attempts[1].test && attempts[0].sourceIP == "192.0.2.1", "webhook attempt fields")
    let urls = await transport.requestURLs
    try expect(urls.contains("\(notifyBase)/api/notify/webhooks/deliveries?id=wh_1"), "webhook deliveries name the webhook by id")

    // A body the app cannot read is companion behind, never an empty list.
    let (broken, _) = notifyClient(["\(notifyBase)/api/notify/rules": (200, json(#"<!doctype html>"#))])
    do {
        _ = try await broken.listNotifyRules()
        throw CheckFailure.failed("an undecodable rules body must throw")
    } catch let error as LatticeAPIError {
        try expectEqual(error, .invalidResponse, "an undecodable rules body is invalidResponse")
    }
}

// MARK: Request bodies

private func checkNotifyRequestBodies() async throws {
    let approval = json(#"{"approval":{"id":"approval_w1","node_id":"n1","plugin":"controlplane-witness","action":"witness-configure:v1","status":"pending","plan":"x","plan_sha256":"2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881","created_at":"2026-10-28T10:00:00Z"}}"#)
    let (client, transport) = notifyClient([
        "\(notifyBase)/api/notify/channels/test": (200, json(#"{"ok":true,"delivery":{"id":"nd_1","event_type":"notify.test","outcome":"sent","role":"test","attempts":[{"at":"2026-10-28T10:00:00Z","ok":true,"duration_ms":300}],"created_at":"2026-10-28T10:00:00Z"},"health":{"state":"ok","consecutive_failures":0}}"#)),
        "\(notifyBase)/api/notify/channels/delete": (200, json(#"{"ok":true}"#)),
        "\(notifyBase)/api/notify/webhooks/test": (200, json(#"{"id":"whd_1","webhook_id":"wh_1","event_type":"backup.finished","outcome":"accepted","fields":0,"bytes":2,"channels":2,"delivered":0,"test":true,"created_at":"2026-10-28T10:00:00Z"}"#)),
        "\(notifyBase)/api/notify/webhooks/delete": (200, json(#"{"ok":true}"#)),
        "\(notifyBase)/api/notify/witness/plan": (200, approval),
    ])

    let test = try await client.notifyTestChannel(id: "ch_bark")
    try expect(test.ok && test.delivery?.role == "test" && test.health?.state == "ok", "channel test answer")
    try expectEqual(try bodyObject(await transport.lastBody) as NSDictionary, ["id": "ch_bark"] as NSDictionary, "channel test body golden")
    try expectEqual(await transport.methods.last ?? nil, "POST", "channel test is a POST")

    try await client.deleteNotifyChannel(id: "ch_bark")
    try expectEqual(try bodyObject(await transport.lastBody) as NSDictionary, ["id": "ch_bark"] as NSDictionary, "channel delete body golden")

    let attempt = try await client.notifyTestWebhook(id: "wh_1")
    try expectEqual(attempt.outcome, "accepted", "webhook test answers the attempt")
    try expectEqual(try bodyObject(await transport.lastBody) as NSDictionary, ["id": "wh_1", "data": [String: String]()] as NSDictionary, "webhook test body golden")

    try await client.notifyDeleteWebhook(id: "wh_1")
    try expectEqual(try bodyObject(await transport.lastBody) as NSDictionary, ["id": "wh_1"] as NSDictionary, "webhook delete body golden")

    let filed = try await client.notifyPlanWitness(.configure(nodeID: "n1", channelID: "ch_bark", barkURL: " http://127.0.0.1:8080/ "))
    try expectEqual(filed.id, "approval_w1", "the witness plan answers {approval}")
    try expectEqual(try bodyObject(await transport.lastBody) as NSDictionary,
                    ["node_id": "n1", "channel_id": "ch_bark", "bark_url": "http://127.0.0.1:8080"] as NSDictionary,
                    "witness configure body golden: the server's defaults for the rest")
    let (changeClient, changeTransport) = notifyClient(["\(notifyBase)/api/notify/witness/plan": (200, approval)])
    _ = try await changeClient.notifyPlanWitness(.configure(nodeID: "n1", channelID: "ch_bark", barkURL: "http://127.0.0.1:8080", healthURL: "https://edge.example.com/readyz"))
    try expectEqual(try bodyObject(await changeTransport.lastBody) as NSDictionary,
                    ["node_id": "n1", "channel_id": "ch_bark", "bark_url": "http://127.0.0.1:8080", "health_url": "https://edge.example.com/readyz"] as NSDictionary,
                    "witness change body golden: a watch URL set on the web is sent again")
    let (removeClient, removeTransport) = notifyClient(["\(notifyBase)/api/notify/witness/plan": (200, approval)])
    _ = try await removeClient.notifyPlanWitness(.remove(nodeID: "n1"))
    try expectEqual(try bodyObject(await removeTransport.lastBody) as NSDictionary, ["node_id": "n1", "remove": true] as NSDictionary, "witness remove body golden")

    let urls = await transport.requestURLs
    try expect(!urls.contains { $0.hasSuffix("/api/notify/test") }, "the phone never calls the notify:send test")
}

// MARK: Intent outcomes

private func checkNotifyIntentOutcomes() async throws {
    let channel = NotifyChannel(id: "ch_mail", name: "Ops mail", kind: "webhook", enabled: true)
    let failedTest = json(#"{"ok":false,"delivery":{"id":"nd_2","event_type":"notify.test","outcome":"failed","attempts":[{"at":"2026-10-28T10:00:00Z","ok":false,"kind":"upstream_4xx","status":401,"duration_ms":300}],"created_at":"2026-10-28T10:00:00Z"},"health":{"state":"degraded"}}"#)
    let (client, transport) = notifyClient([
        "\(notifyBase)/api/notify/channels/test": (200, failedTest),
        "\(notifyBase)/api/notify/webhooks/test": (200, json(#"{"id":"whd_2","webhook_id":"wh_1","event_type":"ups.on_battery","outcome":"no_route","channels":0,"delivered":0,"test":true}"#)),
    ])

    let testIntent = NotifyIntents.testChannel(channel)
    try expectEqual(testIntent.tier, .t2, "channel test is T2")
    try expectEqual(testIntent.scopes, ["notify:admin"], "channel test needs notify:admin, never notify:send")
    guard case .refused(_, let message) = try await testIntent.perform(client, ConfirmChoices()) else {
        throw CheckFailure.failed("a test that did not deliver is not a success")
    }
    try expect(message.contains("refused it (HTTP 401)"), "the refusal names the cause from the receipt")

    let hook = NotifyWebhook(id: "wh_1", name: "UPS", eventType: "ups.on_battery")
    guard case .partial = try await NotifyIntents.testWebhook(hook).perform(client, ConfirmChoices()) else {
        throw CheckFailure.failed("a webhook test that reached nobody is a warning, not a success")
    }
    try expectEqual(NotifyIntents.deleteWebhook(hook).confirmPhrase, "UPS", "deleting a webhook asks for its typed name")
    try expectEqual(NotifyIntents.deleteWebhook(hook).tier, .t4, "webhook delete is T4")

    let silencing = NotifyIntents.deleteChannel(channel, rules: [NotifyRule(id: "r", name: "Mail", channelIDs: ["ch_mail"], enabled: true)], channels: [channel])
    try expectEqual(silencing.confirmPhrase, "Ops mail", "deleting the only channel of a rule asks for the name")
    try expect(silencing.consequence.contains("Rule Mail stops reaching anyone"), "the consequence names the silenced rule")
    let harmless = NotifyIntents.deleteChannel(channel, rules: [], channels: [channel])
    try expect(harmless.confirmPhrase == nil && harmless.tier == .t4, "with no rules the delete is T4 without a typed name")

    let witness = NotifyIntents.removeWitness(node: ObjectRef(kind: "node", id: "n1", name: "home-nas"))
    try expectEqual(witness.tier, .plan, "a witness plan is P")
    try expectEqual(Set(witness.scopes), ["notify:admin", "node:admin", "network:plan"], "witness plan scopes")

    let calls = await transport.requestURLs.count
    try expectEqual(calls, 2, "building intents sends nothing; only perform does")
}

// MARK: Sent log

private func checkNotifySentLog() throws {
    let now = notifyInstant("2026-10-28T12:00:00Z")
    func row(_ outcome: String, attempts: String = "[]", held: String? = nil, reason: String = "", repeats: Int = 0) throws -> NotifyDelivery {
        let heldField = held.map { #","held_until":"\#($0)""# } ?? ""
        return try notifyDelivery(#"{"id":"d","outcome":"\#(outcome)","attempts":\#(attempts),"reason":"\#(reason)","repeats":\#(repeats)\#(heldField),"created_at":"2026-10-28T11:00:00Z"}"#)
    }
    let failedAttempt = #"[{"at":"2026-10-28T11:00:00Z","ok":true,"duration_ms":1},{"at":"2026-10-28T11:01:00Z","ok":false,"kind":"rate_limited","duration_ms":1}]"#

    try expectEqual(NotifySentState.of(try row("sent"), now: now), .sent, "sent")
    try expectEqual(NotifySentState.of(try row("failed"), now: now), .failed, "failed")
    try expectEqual(NotifySentState.of(try row("no_route"), now: now), .notRouted, "not routed")
    try expectEqual(NotifySentState.of(try row("suppressed"), now: now), .held, "suppressed reads as held")
    try expectEqual(NotifySentState.of(try row("planned", held: "2026-10-28T18:00:00Z"), now: now), .held, "quiet hours ahead hold a planned row")
    try expectEqual(NotifySentState.of(try row("planned", held: "2026-10-28T10:00:00Z"), now: now), .queued, "quiet hours over: queued")
    try expectEqual(NotifySentState.of(try row("planned", attempts: failedAttempt), now: now), .retrying, "an attempted planned row is retrying")
    try expectEqual(NotifySentState.notRouted.word, "not routed", "the not-routed word")

    // A queued row is ordinary until it is a minute past due, then overdue.
    let queued = try row("planned")
    try expect(NotifySent.isOverdue(queued, now: now), "queued an hour ago is overdue")
    try expect(!NotifySent.isOverdue(queued, now: notifyInstant("2026-10-28T11:00:30Z")), "queued 30 seconds ago is not overdue")
    let retrying = try row("planned", attempts: failedAttempt)
    let sent = try row("sent")
    try expect(!NotifySent.isOverdue(retrying, now: now), "a retrying row is never overdue")
    try expect(!NotifySent.isOverdue(sent, now: now), "a sent row is never overdue")

    try expectEqual(NotifySent.cause(try row("failed", attempts: failedAttempt)), .rateLimited(status: 429), "the cause is the last failed attempt, rate limit defaults to 429")
    try expectEqual(NotifyFailureCause.of(kind: "upstream_4xx", status: 401).sentence, "the endpoint refused it (HTTP 401), so the key, token or chat id is likely wrong", "refused sentence")
    try expectEqual(NotifyFailureCause.of(kind: "weird", status: nil), .failed, "an unknown kind is a plain failure")
    try expectEqual(NotifySent.occurrences(try row("no_route", repeats: 3)), 4, "repeats fold into occurrences")
    let single = try row("no_route")
    try expect(NotifySent.occurrences(single) == nil, "a single occurrence shows no count")

    try expectEqual(NotifySentNote.of(try row("no_route", reason: "no enabled rule routes this event type")), .noRule, "known reason")
    let maintenance = NotifySentNote.of(try row("suppressed", reason: #"held by maintenance window \"Home lab\" until 2026-10-29T08:00:00Z"#))
    try expectEqual(maintenance, .heldMaintenance(name: "Home lab", until: notifyInstant("2026-10-29T08:00:00Z")), "maintenance hold")
    try expectEqual(NotifySentNote.of(try row("suppressed", reason: "flapping (5 reopenings within 1h0m0s), at most one message an hour")), .heldFlapping(reopenings: 5), "flapping hold")
    try expectEqual(NotifySentNote.of(try row("suppressed", reason: "snoozed until 2026-10-28T13:00:00Z")), .heldSnoozed(until: notifyInstant("2026-10-28T13:00:00Z")), "snoozed hold")
    try expectEqual(NotifySentNote.of(try row("planned", held: "2026-10-28T18:00:00Z")), .quietHours(until: notifyInstant("2026-10-28T18:00:00Z")), "quiet hours note")
    let failedSentence = try row("failed", reason: "upstream status 503 after 4 attempts")
    let retryingSentence = try row("failed", reason: "upstream status 429 after 2 attempts, retrying")
    try expect(NotifySentNote.of(failedSentence) == nil, "a failure sentence needs no note")
    try expect(NotifySentNote.of(retryingSentence) == nil, "a retrying sentence needs no note")
    try expectEqual(NotifySentNote.of(try row("failed", reason: "something new")), .raw("something new"), "an unknown reason shows as sent")
    let locale = Locale(identifier: "en_US_POSIX")
    try expectEqual(NotifySentNote.heldFlapping(reopenings: 5).sentence(mode: .utc, locale: locale), "Held because the incident keeps reopening (5 times): at most one message an hour.", "flapping sentence")
    try expect(NotifySentNote.quietHours(until: notifyInstant("2026-10-28T18:00:00Z")).sentence(mode: .utc, locale: locale).hasSuffix("UTC."), "a note's time says UTC in UTC mode")

    let filters = NotifySentFilters(outcome: .failed, channelID: "ch_bark", eventType: "node.offline")
    let items = Dictionary(uniqueKeysWithValues: filters.query().queryItems.map { ($0.name, $0.value ?? "") })
    try expectEqual(items, ["outcome": "failed", "channel_id": "ch_bark", "event_type": "node.offline", "limit": "500"], "Sent filters send the server's names")
    try expectEqual(NotifySentFilters().query(limit: 200).queryItems.map(\.name), ["limit"], "no filter sends only the limit")
    try expectEqual(NotifySentOutcomeFilter.planned.rawValue, "planned", "in progress is the planned outcome")
    try expectEqual(NotifySentOutcomeFilter.titled("Not routed"), .noRoute, "filter titles map back")

    let rows = [try row("failed"), try row("sent"), try notifyDelivery(#"{"id":"x","outcome":"sent","channel_name":"Phone","event_type":"node.offline","title":"relay down","created_at":"2026-10-28T11:00:00Z"}"#)]
    guard case .success(let failedQuery) = LatticeQueryEngine.compile("state:failed", provider: NotifySentQueryFields.self) else {
        throw CheckFailure.failed("state:failed compiles")
    }
    try expectEqual(LatticeQueryEngine.apply(failedQuery, to: rows, now: now).count, 1, "state:failed keeps the failed row")
    guard case .success(let channelQuery) = LatticeQueryEngine.compile("channel:phone relay", provider: NotifySentQueryFields.self) else {
        throw CheckFailure.failed("channel query compiles")
    }
    try expectEqual(LatticeQueryEngine.apply(channelQuery, to: rows, now: now).map(\.id), ["x"], "channel by name and a bare word")
    guard case .failure = LatticeQueryEngine.compile("chanel:phone", provider: NotifySentQueryFields.self) else {
        throw CheckFailure.failed("a misspelt field is an error, not an empty list")
    }

    try expectEqual(NotifySent.origin(try notifyDelivery(#"{"id":"d","source":"webhook","source_id":"wh_ups"}"#)), "Inbound webhook wh_ups", "webhook origin")
    try expectEqual(NotifySent.severityWord(try notifyDelivery(#"{"id":"d","severity":"critical","recovery":true}"#)), "Recovered", "a recovery reads recovered whatever its severity")
}

// MARK: Channel health

private func checkNotifyChannelHealth() throws {
    let failing = NotifyChannelHealth(state: "failing", lastFailureAt: notifyInstant("2026-10-28T11:00:00Z"), lastFailureKind: "upstream_5xx", lastStatusCode: 503, consecutiveFailures: 5, failingSince: notifyInstant("2026-10-28T09:00:00Z"))
    let line = NotifyChannelHealthLine.of(failing)
    try expectEqual(line.state, .failing, "failing line")
    try expectEqual(line.at, notifyInstant("2026-10-28T09:00:00Z"), "a failing line dates from failing since")
    try expectEqual(line.cause, .serverError(status: 503), "the cause comes from the kind and status")
    try expectEqual(NotifyChannelHealthLine.of(nil).state, .unreported, "no health is unreported, not unused")
    try expectEqual(NotifyChannelHealthLine.of(NotifyChannelHealth(state: "ok", lastAttemptAt: notifyInstant("2026-10-28T10:00:00Z"))).at, notifyInstant("2026-10-28T10:00:00Z"), "ok falls back to the last attempt")
    try expectEqual(NotifyChannelHealthLine.of(NotifyChannelHealth(state: "weird")).state, .unknown, "an unknown state reads unknown")

    let a = NotifyChannel(id: "a", name: "A", enabled: true, health: NotifyChannelHealth(state: "failing", consecutiveFailures: 2, failingSince: notifyInstant("2026-10-28T08:00:00Z")))
    let b = NotifyChannel(id: "b", name: "B", enabled: true, health: NotifyChannelHealth(state: "failing", consecutiveFailures: 7, failingSince: notifyInstant("2026-10-28T10:00:00Z")))
    let c = NotifyChannel(id: "c", name: "C", enabled: true, health: NotifyChannelHealth(state: "failing", consecutiveFailures: 2, failingSince: notifyInstant("2026-10-28T07:00:00Z")))
    let off = NotifyChannel(id: "d", name: "D", enabled: false, health: NotifyChannelHealth(state: "failing", consecutiveFailures: 9))
    try expectEqual(NotifyChannels.failing([a, b, c, off]).map(\.id), ["b", "c", "a"], "failing channels worst first, disabled ones left out")
    try expectEqual(NotifyChannels.bark([NotifyChannel(id: "z", name: "Zed", kind: "bark"), NotifyChannel(id: "t", kind: "telegram"), NotifyChannel(id: "y", name: "Alpha", kind: "bark")]).map(\.id), ["y", "z"], "Bark channels by name")
    try expectEqual(NotifyKind.label("telegram"), "Telegram", "kind label")
}

// MARK: Delete impact (notificationsModel.test.ts cases)

private func checkNotifyDeleteImpact() throws {
    let target = NotifyChannel(id: "ch1", name: "Phone", enabled: true)
    let other = NotifyChannel(id: "ch2", name: "Mail", enabled: true)
    let offOther = NotifyChannel(id: "ch3", name: "Old", enabled: false)
    let channels = [target, other, offOther]

    try expectEqual(NotifyChannelDeleteImpact.of(target, rules: nil, channels: channels), NotifyChannelDeleteImpact(lines: [.rulesUnread], typed: true), "unread rules claim nothing and ask for the name")
    try expectEqual(NotifyChannelDeleteImpact.of(target, rules: [NotifyRule(id: "r", name: "Off", channelIDs: ["ch1"], enabled: false)], channels: channels),
                    NotifyChannelDeleteImpact(lines: [.noRules], typed: false), "with no enabled rule the channel just stops receiving")
    try expectEqual(NotifyChannelDeleteImpact.of(offOther, rules: [], channels: channels), NotifyChannelDeleteImpact(lines: [], typed: false), "a disabled channel with no rules stops nothing")
    let rules = [
        NotifyRule(id: "r1", name: "Zulu", eventTypes: ["node.offline"], channelIDs: ["ch1", "ch3"], enabled: true),
        NotifyRule(id: "r2", name: "Alpha", channelIDs: ["ch1", "ch2"], enabled: true),
        NotifyRule(id: "r3", name: "Other", channelIDs: ["ch2"], enabled: true),
    ]
    let impact = NotifyChannelDeleteImpact.of(target, rules: rules, channels: channels)
    try expectEqual(impact.lines, [.silenced(rule: "Zulu", events: "node.offline"), .kept(rule: "Alpha", others: ["Mail"])], "silenced first, then kept, each sorted by name")
    try expect(impact.typed, "a silenced rule asks for the typed name")
    try expectEqual(NotifyChannelDeleteImpact.of(target, rules: [rules[2]], channels: channels), NotifyChannelDeleteImpact(lines: [.unrouted], typed: false), "no enabled rule sends to it")
    try expectEqual(NotifyChannelDeleteImpact.of(target, rules: [NotifyRule(id: "r", name: "All", channelIDs: ["ch1"], enabled: true)], channels: channels).lines,
                    [.silenced(rule: "All", events: "*")], "a rule with no event types matches every event")

    // The server clears every fallback that pointed at the deleted channel.
    let leaning = [
        NotifyRule(id: "r4", name: "Incidents", channelIDs: ["ch2"], enabled: true, fallbackChannelID: "ch1"),
        NotifyRule(id: "r5", name: "Paused", channelIDs: ["ch2"], enabled: false, fallbackChannelID: "ch1"),
    ]
    let fallbackChannels = channels + [NotifyChannel(id: "ch4", name: "Chat", enabled: true, fallbackChannelID: "ch1")]
    let lost = NotifyChannelDeleteImpact.of(target, rules: leaning, channels: fallbackChannels)
    try expectEqual(lost, NotifyChannelDeleteImpact(lines: [.unrouted, .fallbackLost(rule: "Incidents", primary: ["Mail"]), .channelFallbackLost(channel: "Chat")], typed: true),
                    "an enabled rule losing its fallback is named and asks for the typed name; a disabled one is not")
    try expectEqual(lost.sentences(channel: "Phone")[1], "Rule Incidents loses its fallback: when Mail fails, nothing takes over.", "the lost fallback sentence")
    try expectEqual(NotifyChannelDeleteImpact.of(target, rules: [], channels: fallbackChannels).lines, [.noRules, .channelFallbackLost(channel: "Chat")],
                    "a channel's fallback is lost even when no rule exists")
}

// MARK: Rules

private func checkNotifyRules() throws {
    let rule = NotifyRule(id: "r", name: "R", eventTypes: [], channelIDs: ["ch_off"], enabled: true, escalateAfterMinutes: 30, escalationBarkLevel: "critical", quietHours: NotifyQuietHours(start: "23:00", end: "07:00", timeZone: "Europe/Zurich"))
    try expect(NotifyRules.matchesEverything(rule), "no event types match everything")
    try expect(NotifyRules.matchesEverything(NotifyRule(id: "s", eventTypes: ["*"])), "a star matches everything")
    try expect(NotifyRules.reachesNoChannel(rule, channels: [NotifyChannel(id: "ch_off", enabled: false)]), "an enabled rule with only disabled channels reaches none")
    try expect(!NotifyRules.reachesNoChannel(rule, channels: [NotifyChannel(id: "ch_off", enabled: true)]), "an enabled channel reaches")
    try expectEqual(NotifyRules.quietHoursText(rule), "23:00 to 07:00, Europe/Zurich", "quiet hours text")
    try expectEqual(NotifyRules.escalationText(rule), "Re-sends an unacknowledged critical incident after 30 minutes, at Bark level critical (default)", "default escalation")
    try expectEqual(NotifyRules.escalationText(NotifyRule(id: "s", escalateAfterMinutes: 15, escalationBarkLevel: "timeSensitive")), "Re-sends an unacknowledged critical incident after 15 minutes, at Bark level timeSensitive", "custom escalation")
    try expectEqual(NotifyRules.escalationText(NotifyRule(id: "s", escalationOff: true)), "Off", "escalation off")
    try expectEqual(NotifyRules.escalationText(NotifyRule(id: "s")), "Re-sends an unacknowledged critical incident after 30 minutes, at Bark level critical (default)", "an older server's zero values read as the defaults")
}

// MARK: Webhook routing

private func checkNotifyWebhookRouting() throws {
    let hook = NotifyWebhook(id: "wh", name: "UPS", eventType: "ups.on_battery")
    let on = NotifyChannel(id: "c", enabled: true)
    let routing = NotifyRule(id: "r1", eventTypes: ["backup.finished"], channelIDs: ["c"], enabled: true)
    try expectEqual(NotifyWebhookRouting.of(hook, channels: nil, rules: nil), .unknown, "unread channels claim nothing")
    try expectEqual(NotifyWebhookRouting.of(hook, channels: [NotifyChannel(id: "c", enabled: false)], rules: nil), .noChannel, "no enabled channel")
    try expectEqual(NotifyWebhookRouting.of(hook, channels: [on], rules: nil), .unknown, "channels but unread rules claim nothing")
    try expectEqual(NotifyWebhookRouting.of(hook, channels: [on], rules: [routing]), .noRule, "rules exist but none routes the event")
    try expectEqual(NotifyWebhookRouting.of(hook, channels: [on], rules: []), .ok, "with no enabled rule every channel gets every event")
    try expectEqual(NotifyWebhookRouting.of(hook, channels: [on], rules: [routing, NotifyRule(id: "r2", eventTypes: [], enabled: true)]), .ok, "a rule with no types routes everything")
    try expect(NotifyWebhookRouting.reachesNobody(hook, channels: [on], rules: [routing]), "an enabled unrouted webhook reaches nobody")
    var off = hook
    off.enabled = false
    try expect(!NotifyWebhookRouting.reachesNobody(off, channels: [on], rules: [routing]), "a disabled webhook is not called unreachable")
    try expect(!NotifyWebhookRouting.reachesNobody(hook, channels: [on], rules: nil), "nothing is claimed before the rules land")

    try expectEqual(NotifyWebhookHealth.of([]), .never, "no attempts: never called")
    try expectEqual(NotifyWebhookHealth.of([NotifyWebhookDelivery(id: "1", webhookID: "wh", eventType: "x", outcome: "rejected"), NotifyWebhookDelivery(id: "2", webhookID: "wh", eventType: "x", outcome: "accepted")]), .rejecting, "health from the newest attempt")
    try expectEqual(NotifyWebhookHealth.of([NotifyWebhookDelivery(id: "1", webhookID: "wh", eventType: "x", outcome: "partial")]), .failing, "partial counts as failing")
    var detail = NotifyWebhookDelivery(id: "1", webhookID: "wh", eventType: "x", outcome: "accepted", channels: 2, delivered: 1)
    detail.fields = 1
    detail.sourceIP = "192.0.2.4"
    try expectEqual(NotifyWebhookAttempt.detail(detail), "delivered to 1 of 2 channels, 1 field, from 192.0.2.4", "attempt detail")
    try expectEqual(NotifyWebhookAttempt.word("no_route"), "reached nobody", "attempt word")
}

// MARK: Witness (witnessModel.test.ts cases)

private func checkNotifyWitness() throws {
    let configured = NotifyWitnessApproval(approvalID: "a1", action: "configure", status: "applied", healthURL: "https://cdn.example.com/readyz")
    func report(_ phase: String) -> NotifyWitnessReport {
        var r = NotifyWitnessReport(phase: phase)
        r.lastCheckAt = notifyInstant("2026-10-28T11:59:00Z")
        r.configSHA256 = "abc"
        return r
    }
    try expectEqual(NotifyWitnessLine.of(NotifyWitnessNode(nodeID: "n", nodeName: "n")).key, .notConfigured, "nothing at all")
    try expectEqual(NotifyWitnessLine.of(NotifyWitnessNode(nodeID: "n", nodeName: "n", pending: NotifyWitnessApproval(approvalID: "p", action: "configure", status: "pending"))).key, .planned, "a plan waiting")
    try expectEqual(NotifyWitnessLine.of(NotifyWitnessNode(nodeID: "n", nodeName: "n", configured: configured)).key, .neverReported, "applied with no report")
    try expectEqual(NotifyWitnessLine.of(NotifyWitnessNode(nodeID: "n", nodeName: "n", configured: configured, report: report("watching"), reportFresh: false)).key, .notReporting, "a stale relay")
    try expectEqual(NotifyWitnessLine.of(NotifyWitnessNode(nodeID: "n", nodeName: "n", configured: configured, report: report("watching"), reportFresh: true, checkStale: true)).key, .stopped, "a fresh relay of a dead witness")
    let down = NotifyWitnessLine.of(NotifyWitnessNode(nodeID: "n", nodeName: "n", configured: configured, report: report("down"), reportFresh: true))
    try expect(down.key == .down && down.tone == .fail, "down is a failure")
    try expectEqual(NotifyWitnessLine.of(NotifyWitnessNode(nodeID: "n", nodeName: "n", report: report("watching"), reportFresh: true)).key, .watching, "a fresh report without a plan still reads")
    try expectEqual(NotifyWitnessLine.of(NotifyWitnessNode(nodeID: "n", nodeName: "n", configured: configured, report: report("bogus"), reportFresh: true)).key, .unknown, "an unknown phase")

    var failingReport = report("failing")
    failingReport.consecutiveFailures = 2
    failingReport.lastCheckDetail = "http 503"
    failingReport.failingSince = notifyInstant("2026-10-28T11:58:00Z")
    let failing = NotifyWitnessLine.of(NotifyWitnessNode(nodeID: "n", nodeName: "n", configured: configured, report: failingReport, reportFresh: true))
    try expectEqual(failing.sentence(mode: .utc, locale: Locale(identifier: "en_GB"), now: notifyInstant("2026-10-28T12:00:00Z")),
                    "Not answering since 11:58 UTC, 2 checks in a row (http 503). It pushes once the hold passes.", "failing sentence")

    var pushed = report("watching")
    pushed.lastPushAt = notifyInstant("2026-10-28T10:00:00Z")
    pushed.lastPushKind = "down"
    pushed.lastPushOK = false
    let nodes = [
        NotifyWitnessNode(nodeID: "1", nodeName: "a", configured: configured, report: failingReport, reportFresh: true, configMatches: false),
        NotifyWitnessNode(nodeID: "2", nodeName: "b", configured: configured, report: report("down"), reportFresh: true, configMatches: true),
        NotifyWitnessNode(nodeID: "3", nodeName: "c", configured: configured, lastFailed: NotifyWitnessApproval(approvalID: "f", action: "configure", status: "rejected", reason: "exit 1"), report: pushed, reportFresh: true, configMatches: true),
    ]
    try expectEqual(NotifyWitness.attention(nodes).map(\.kind), [.down, .failing, .differs, .pushFailed, .planFailed], "failures first, the rest in node order")
    try expectEqual(NotifyWitness.configState(nodes[0]), .differs, "a different config")
    try expectEqual(NotifyWitness.configState(NotifyWitnessNode(nodeID: "x", nodeName: "x", configured: configured)), .unknown, "nothing to compare")
    try expectEqual(NotifyWitness.shownNodes(NotifyWitnessStatus(nodes: [NotifyWitnessNode(nodeID: "x", nodeName: "x")] + nodes)).map(\.nodeID), ["1", "2", "3"], "a node with no witness is not listed")
    try expect(NotifyWitness.watch(nodes[0], defaultURL: "https://lattice.example.com/readyz")! == ("https://cdn.example.com/readyz", true), "the plan's own watch URL is custom")
    try expect(NotifyWitness.watch(NotifyWitnessNode(nodeID: "x", nodeName: "x"), defaultURL: "") == nil, "nothing to name")
    var timed = nodes[0]
    timed.report?.intervalSeconds = 30
    timed.report?.holdSeconds = 180
    timed.report?.referenceCount = 3
    var basisStatus = NotifyWitnessStatus(nodes: [timed])
    basisStatus.healthURL = "https://lattice.example.com/readyz"
    basisStatus.defaults.intervalSeconds = 30
    basisStatus.defaults.holdSeconds = 180
    basisStatus.defaults.referenceURLs = Array(repeating: "https://example.com/", count: 3)
    try expectEqual(NotifyWitness.changeBasis(timed, status: basisStatus), NotifyWitness.ChangeBasis(healthURL: "https://cdn.example.com/readyz", customSettings: false),
                    "a change keeps the watch URL set on the web")
    try expectEqual(NotifyWitness.changeBasis(nil, status: basisStatus), NotifyWitness.ChangeBasis(), "a new witness starts from the defaults")
    try expect(!NotifyWitness.changeBasis(nodes[0], status: basisStatus).customSettings, "an agent that reports no timing claims nothing")
    basisStatus.defaults.intervalSeconds = 60
    try expect(NotifyWitness.changeBasis(timed, status: basisStatus).customSettings, "custom timing is noticed")
    try expectEqual(NotifyWitness.formProblems(nodeID: "n", channelID: "c", barkURL: "http://127.0.0.1:8080", defaultHealthURL: "",
                                               basis: NotifyWitness.ChangeBasis(healthURL: "https://cdn.example.com/readyz", customSettings: true)),
                    [.customSettings], "custom settings refuse the phone's plan; a kept watch URL needs no public URL")
    try expectEqual(NotifyWitness.pushLine(pushed, mode: .utc, locale: Locale(identifier: "en_US_POSIX"), now: notifyInstant("2026-10-28T12:00:00Z"))?.hasPrefix("Unreachable alert, not accepted"), true, "push line")

    for good in ["http://127.0.0.1:8080", "http://localhost:8080/", "https://[::1]:8443", "http://127.0.0.2"] {
        try expect(NotifyWitness.isLoopbackBaseURL(good), "\(good) is a loopback base URL")
    }
    for bad in ["http://192.0.2.1:8080", "ftp://127.0.0.1", "http://127.0.0.1:8080?x=1", "http://user@127.0.0.1", "127.0.0.1:8080", "http://127.0.0.1#a", "http://localhost.example.com"] {
        try expect(!NotifyWitness.isLoopbackBaseURL(bad), "\(bad) is refused")
    }
    try expectEqual(NotifyWitness.formProblems(nodeID: "", channelID: "", barkURL: "", defaultHealthURL: ""), [.node, .channel, .barkURL, .healthURLRequired], "every problem")
    try expectEqual(NotifyWitness.formProblems(nodeID: "n", channelID: "c", barkURL: "http://192.0.2.1", defaultHealthURL: "https://x/readyz"), [.barkURLLoopback], "a remote bark-server")
    try expectEqual(NotifyWitness.formProblems(nodeID: "n", channelID: "c", barkURL: "http://127.0.0.1:8080", defaultHealthURL: "https://x/readyz"), [], "ready to file")
}

// MARK: Demo

private func checkNotifyDemo() async throws {
    let state = DemoState()
    let clock = DemoClock(pinned: "2026-10-28T12:00:00Z")!
    func client(_ scenario: DemoScenario = .normal) -> LatticeClient {
        LatticeClient(baseURL: DemoWorld.baseURL, credential: LatticeCredential(bearerToken: DemoWorld.token), transport: DemoTransport(identity: .pat, scenario: scenario, clock: clock, state: state))
    }
    let channels = try await client().listNotifyChannels()
    try expectEqual(Set(channels.compactMap { $0.health?.state }), ["ok", "failing", "degraded", "unknown"], "the demo covers every channel health")
    try expect(channels.allSatisfy { NotifyKind.all.contains($0.kind) }, "demo channels use the server's kinds")
    let rules = try await client().listNotifyRules()
    try expect(rules.contains { $0.quietHours != nil } && rules.contains { !$0.enabled }, "quiet hours and a disabled rule")
    let catalogue = try await client().notifyFetchCatalogue()
    try expectEqual(catalogue.types.count, 21, "the server's catalogue")
    let witness = try await client().notifyFetchWitness()
    try expectEqual(Set(NotifyWitness.shownNodes(witness).map { NotifyWitnessLine.of($0).key }), [.watching, .failing], "a watching and a failing witness")
    try expect(witness.nodes.contains { $0.pending != nil }, "a witness plan waiting")

    let webhooks = try await client().notifyListWebhooks()
    try expectEqual(webhooks.filter { NotifyWebhookRouting.reachesNobody($0, channels: channels, rules: rules) }.map(\.id), ["wh_ups"], "one webhook reaches nobody")
    try expectEqual(NotifyWebhookHealth.of(try await client().notifyWebhookDeliveries(id: "wh_backup")), .ok, "the backup webhook is delivering")

    let sent = try await client().fetchDeliveries(query: NotifySentFilters().query())
    let now = clock.anchor
    try expectEqual(Set(sent.deliveries.map { NotifySentState.of($0, now: now) }), Set(NotifySentState.allCases), "the Sent log covers every state")
    try expect(sent.deliveries.contains { $0.attempts.count >= 3 } && sent.deliveries.contains { $0.repeats > 0 }, "several attempts and a folded row")
    let createdTimes = sent.deliveries.compactMap(\.createdAt)
    try expectEqual(createdTimes, createdTimes.sorted(by: >), "newest first")
    let failed = try await client().fetchDeliveries(query: NotifySentFilters(outcome: .failed).query())
    try expect(!failed.deliveries.isEmpty && failed.deliveries.allSatisfy { $0.outcome == "failed" }, "the outcome filter reaches the demo server")
    let byChannel = try await client().fetchDeliveries(query: NotifySentFilters(channelID: "ch_tg").query())
    try expect(!byChannel.deliveries.isEmpty && byChannel.deliveries.allSatisfy { $0.channelID == "ch_tg" }, "the channel filter")
    let linked = try await client().fetchDeliveries(query: DeliveryQuery(limit: 200))
    try expect(linked.deliveries.contains { $0.id == "dlv_n02" }, "a link opens a rich delivery by id")

    let test = try await client().notifyTestChannel(id: "ch_mail")
    try expect(!test.ok && test.delivery?.outcome == "failed", "testing the failing channel fails")
    let filed = try await client().notifyPlanWitness(.configure(nodeID: DemoWorld.node("studio-mac").id, channelID: "ch_bark", barkURL: "http://127.0.0.1:8080"))
    try expect(filed.planHashMatchesServer, "the filed witness plan hashes to its plan_sha256")
    let readBack = try await client().fetchApproval(id: filed.id)
    try expectEqual(readBack.plugin, "controlplane-witness", "the filed plan reads back by id")
    let pending = try await client().fetchApproval(id: "approval_nw01")
    try expect(pending.planHashMatchesServer, "the waiting witness plan hashes to its plan_sha256")
    do {
        _ = try await client().notifyPlanWitness(.configure(nodeID: DemoWorld.node("studio-mac").id, channelID: "ch_tg", barkURL: "http://127.0.0.1:8080"))
        throw CheckFailure.failed("a non-Bark channel must be refused")
    } catch let error as LatticeAPIError {
        guard case .server(let status, _, _) = error, status == 400 else { throw CheckFailure.failed("400 for a non-Bark channel, got \(error)") }
    }

    try await client().notifyDeleteWebhook(id: "wh_ci")
    let afterDelete = try await client().notifyListWebhooks()
    try expect(!afterDelete.contains { $0.id == "wh_ci" }, "a deleted webhook leaves the list")

    do {
        _ = try await client(.confinedToken).listNotifyChannels()
        throw CheckFailure.failed("a confined token must be refused the notify surface")
    } catch let error as LatticeAPIError {
        guard case .forbidden(let code, _) = error, code == "capability_denied" else { throw CheckFailure.failed("capability_denied, got \(error)") }
    }
    let empty = try await client(.empty).fetchDeliveries(query: NotifySentFilters().query())
    try expectEqual(empty.deliveries.count, 0, "the Empty scenario empties the Sent log")
}
