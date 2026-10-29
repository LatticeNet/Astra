import Foundation

// M9's endpoints (section 8.4): the notify reads and the five writes the
// phone makes (channel test and delete, witness plan, webhook test and
// delete). Channel and rule authoring, the notify:send test, and webhook
// create, edit and rotate stay on the web, so no client call exists for them.

private struct RulesEnvelope: Decodable { var rules: [NotifyRule] }
private struct WebhooksEnvelope: Decodable { var webhooks: [NotifyWebhook] }
private struct WebhookDeliveriesEnvelope: Decodable { var deliveries: [NotifyWebhookDelivery] }

public extension LatticeClient {
    func listNotifyChannels() async throws -> [NotifyChannel] {
        try await perform([NotifyChannel].self, path: "/api/notify/channels")
    }

    /// The rules envelope. An undecodable body is the companion-behind
    /// case, never an empty list.
    func listNotifyRules() async throws -> [NotifyRule] {
        try await perform(RulesEnvelope.self, path: "/api/notify/rules").rules
    }

    func deleteNotifyChannel(id: String) async throws {
        try await performVoid(path: "/api/notify/channels/delete", body: IDBody(id: id))
    }

    func notifyFetchCatalogue() async throws -> NotifyCatalogue {
        try await perform(NotifyCatalogue.self, path: "/api/notify/catalogue")
    }

    func notifyFetchWitness() async throws -> NotifyWitnessStatus {
        try await perform(NotifyWitnessStatus.self, path: "/api/notify/witness")
    }

    func notifyListWebhooks() async throws -> [NotifyWebhook] {
        try await perform(WebhooksEnvelope.self, path: "/api/notify/webhooks").webhooks
    }

    /// One webhook's retained attempts, newest first (the server keeps at most 50).
    func notifyWebhookDeliveries(id: String, limit: Int? = nil) async throws -> [NotifyWebhookDelivery] {
        var query = [URLQueryItem(name: "id", value: id)]
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await perform(WebhookDeliveriesEnvelope.self, path: "/api/notify/webhooks/deliveries", query: query).deliveries
    }

    /// Sends the server's fixed test message through a stored channel.
    func notifyTestChannel(id: String) async throws -> NotifyChannelTestResult {
        try await perform(NotifyChannelTestResult.self, path: "/api/notify/channels/test", method: "POST", body: IDBody(id: id))
    }

    func notifyDeleteWebhook(id: String) async throws {
        try await performVoid(path: "/api/notify/webhooks/delete", body: IDBody(id: id))
    }

    /// Fires a webhook through the same path a caller uses; the answer is
    /// the attempt it recorded.
    func notifyTestWebhook(id: String, data: [String: String] = [:]) async throws -> NotifyWebhookDelivery {
        try await perform(NotifyWebhookDelivery.self, path: "/api/notify/webhooks/test", method: "POST", body: NotifyWebhookTestBody(id: id, data: data))
    }

    /// Files a witness plan; the answer is `{approval}`.
    func notifyPlanWitness(_ request: NotifyWitnessPlanRequest) async throws -> Approval {
        let data = try await performData(path: "/api/notify/witness/plan", method: "POST", body: request)
        return try ApprovalReviewDecoder.decodeEnvelope(data)
    }
}
