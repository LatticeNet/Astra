import Foundation
import AstraCore

public func checkVPN() async throws {
    try checkVPNDecoding()
    try checkVPNIdentityDerivations()
    try checkVPNLinkDerivations()
    try checkVPNLineDerivations()
    try await checkVPNRequests()
    try await checkVPNIntents()
    try await checkVPNDemo()
}

private let vpnBase = "https://lattice.example.com"

private struct VPNAuthStub: WriteAuthenticator {
    var outcome: DeviceAuthOutcome = .confirmed
    func authenticate(reason: String) async -> DeviceAuthOutcome { outcome }
}

private func vpnClient(_ responses: [String: (Int, Data)], session: Bool = false) -> (LatticeClient, MockTransport) {
    let transport = MockTransport(responses: responses)
    let credential = session
        ? LatticeCredential(sessionCookie: "s-check", csrfToken: "csrf-check")
        : LatticeCredential(bearerToken: "lat_check.notasecret")
    return (LatticeClient(baseURL: URL(string: vpnBase)!, credential: credential, transport: transport), transport)
}

private func vpnInstant(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

// `users.list` as `vpnUserUsageView` marshals it: the embedded view's
// fields flattened, omitempty fields absent, Go's zero expiry left out by
// omitzero, the usage figures and the policy added.
private let vpnUsersJSON = #"""
{"users":[
 {"id":"vu_a","email":"a@example.org","name":"A","enabled":true,
  "credentials":[{"protocol":"vless","flow":"xtls-rprx-vision","has_secret":true},{"protocol":"trojan","has_secret":false}],
  "bindings":[{"line_hash_id":"line_1","enabled":true,"credential":"current"},{"line_hash_id":"line_2","enabled":false,"credential":"stale"}],
  "quota_bytes":107374182400,"quota_period":"monthly","quota_reset_day":1,"expires_at":"2026-11-02T00:00:00Z","group":"family",
  "migrated":false,"link":{"slug":"u-abc","enabled":true,"issued_at":"2026-08-01T00:00:00Z","rotated_at":"2026-10-01T10:00:00Z","update_interval_hours":12},
  "created_at":"2026-06-01T00:00:00Z","updated_at":"2026-10-20T00:00:00Z",
  "used_total_bytes":99000000000,"used_total_from":"2026-01-01T00:00:00Z","used_period_bytes":41000000000,
  "period_start":"2026-10-01T00:00:00Z","period_end":"2026-11-01T00:00:00Z","last_7d":[1,2,3,4,5,6,7],"last_seen_at":"2026-10-28T11:00:00Z",
  "allocated_nodes":[{"node_id":"n-tyo","node_name":"edge-tyo-1","collector_state":"ok","lines":[
    {"line_hash_id":"line_1","tag":"tyo","role":"entry","allocation":"binding","period_uplink":100,"period_downlink":900,"last_seen_at":"2026-10-28T11:00:00Z","counted":true}]}],
  "policy":{"status":"active","quota":{"limit_bytes":107374182400,"used_bytes":41000000000,"proof_bytes":40000000000,"period":"monthly","period_start":"2026-10-01T00:00:00Z","period_end":"2026-11-01T00:00:00Z"}}},
 {"id":"vu_b","email":"b@example.org","enabled":false,"credentials":[],"bindings":[],"migrated":true,"created_at":"2026-06-01T00:00:00Z","updated_at":"2026-06-01T00:00:00Z",
  "used_total_bytes":0,"used_period_bytes":0,"last_7d":[0,0,0,0,0,0,0],"allocated_nodes":[],
  "policy":{"status":"disabled","reason":"disabled","suspended_by":"u-ops","suspended_since":"2026-10-01T00:00:00Z"}}
],"count":2}
"""#

private let vpnLinkStatusJSON = #"""
{"identity_id":"vu_a","issued":true,
 "link":{"slug":"u-abc","enabled":true,"issued_at":"2026-08-01T00:00:00Z","rotated_at":"2026-10-01T10:00:00Z","update_interval_hours":12},
 "answer":"nodes","answer_reason":"active","subscription_userinfo":"upload=1073741824; download=9663676416; total=107374182400",
 "included":[{"line_hash_id":"line_1","node_id":"n-tyo","node_name":"edge-tyo-1","line_name":"tyo","protocol":"vless"}],
 "excluded":[{"line_hash_id":"line_3","node_id":"n-tyo2","node_name":"edge-tyo-2","line_name":"anytls","protocol":"anytls","reason":"rotation_not_applied","fix":"plan_update"}],
 "formats":{"native":["URI","V2Ray"],"converted":[],"convert_available":false,"fallback":"base64_uri"},
 "last_fetch":{"at":"2026-10-28T09:00:00Z","ua_class":"shadowrocket","answer":"nodes"}}
"""#

private let vpnNotIssuedJSON = #"{"identity_id":"vu_b","issued":false,"answer":"decoy","answer_reason":"not_issued","included":[],"excluded":[],"formats":{"native":["URI","V2Ray"],"converted":[],"convert_available":false,"fallback":"base64_uri"}}"#

private let vpnLinesJSON = #"""
{"groups":[
 {"node_id":"n-tyo","node_name":"edge-tyo-1","lines":[
  {"id":"line_1","line_hash_id":"line_1","node_id":"n-tyo","line_uuid":"7a1c0e52-0000-4000-8000-000000000001","core":"sing-box","source":"managed","managed":true,
   "name":"tyo","tag":"tyo","type":"vless","transport":"tcp","security":"reality","listen_host":"::","listen_port":443,"public_host":"edge-tyo-1.example.net",
   "outbound_ref":"relay-hkg-1/hk","outbound_server":"relay-hkg-1.example.net","outbound_port":8443,"jump_edges":["line_2"],
   "user_count":6,"user_known":true,"status":"ok","service_state":"running","service_checked_at":"2026-10-28T11:58:00Z"}]},
 {"node_id":"n-hkg","node_name":"relay-hkg-1","lines":[
  {"id":"line_2","line_hash_id":"line_2","node_id":"n-hkg","core":"sing-box","source":"discovered","managed":false,"name":"hk","type":"vless",
   "listen_port":8443,"outbound_ref":"direct","user_count":0,"user_known":false,"service_note":"no process holds :8443"}]}
],"count":2}
"""#

// MARK: Decoding

private func checkVPNDecoding() throws {
    let list = try JSONDecoder().decode(VPNUserList.self, from: json(vpnUsersJSON))
    try expectEqual(list.count, 2, "count")
    let a = list.users[0]
    try expectEqual(a.email, "a@example.org", "email")
    try expectEqual(a.credentials.map(\.protocol), ["vless", "trojan"], "credential protocols")
    try expect(a.credentials[0].hasSecret && !a.credentials[1].hasSecret, "has_secret per credential")
    try expectEqual(a.bindings.map(\.credential), ["current", "stale"], "binding credential state")
    try expectEqual(a.quotaBytes, 107_374_182_400, "quota bytes")
    try expectEqual(a.quotaPeriod, "monthly", "quota period")
    try expectEqual(a.expiresAt, vpnInstant("2026-11-02T00:00:00Z"), "expiry")
    try expectEqual(a.link?.slug, "u-abc", "link slug")
    try expectEqual(a.link?.updateIntervalHours, 12, "link refresh hours")
    try expectEqual(a.link?.rotatedAt, vpnInstant("2026-10-01T10:00:00Z"), "rotated at")
    let usage = try expectUnwrapped(a.usage, "usage decodes when reported")
    try expectEqual(usage.usedPeriodBytes, 41_000_000_000, "period bytes")
    try expectEqual(usage.last7d.count, 7, "seven days")
    try expectEqual(usage.allocatedNodes.first?.lines.first?.periodBytes, 1000, "allocated line bytes")
    try expectEqual(a.policy?.quota?.proofBytes, 40_000_000_000, "proof bytes")
    let b = list.users[1]
    try expect(b.expiresAt == nil && b.link == nil && b.quotaBytes == 0, "absent fields read as none")
    try expectEqual(b.policy?.reason, "disabled", "suspension reason")
    try expect(b.migrated, "migrated flag")

    // An older server sends no usage at all, which is not zero bytes.
    let old = try JSONDecoder().decode(VPNUser.self, from: json(#"{"id":"vu_c","email":"c@example.org","enabled":true,"credentials":[],"bindings":[],"migrated":false,"created_at":"2026-06-01T00:00:00Z","updated_at":"2026-06-01T00:00:00Z"}"#))
    try expect(old.usage == nil && old.policy == nil, "no usage read model")
    let envelope = try JSONDecoder().decode(VPNUserEnvelope.self, from: json(#"{"user":{"id":"vu_c","email":"c@example.org","enabled":true,"credentials":[],"bindings":[],"migrated":false}}"#))
    try expectEqual(envelope.user.id, "vu_c", "get envelope")
    try expect((try? JSONDecoder().decode(VPNUserList.self, from: json(#"{"identities":[]}"#))) == nil, "a list without users is not a list")

    let proxy = try JSONDecoder().decode(VPNProxyUserList.self, from: json(#"""
    {"users":[{"id":"alice","name":"alice@example.org","enabled":true,"has_uuid":true,"has_password":true,"traffic_limit_bytes":5368709120,
      "used_bytes":6000000000,"last_seen_at":"2026-10-28T10:00:00Z","status":"over_quota","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-10-01T00:00:00Z"}]}
    """#))
    let legacy = VPNUser(legacy: proxy.users[0])
    try expectEqual(legacy.source, .legacyProxyUser, "legacy source")
    try expectEqual(legacy.credentials.map(\.protocol), ["vless", "trojan"], "legacy credentials from has_uuid and has_password")
    try expectEqual(legacy.quotaBytes, 5_368_709_120, "legacy limit")
    try expectEqual(legacy.usage?.usedPeriodBytes, 6_000_000_000, "legacy used")

    let status = try JSONDecoder().decode(VPNLinkStatus.self, from: json(vpnLinkStatusJSON))
    try expect(status.issued, "issued")
    try expectEqual(status.included.count, 1, "included")
    try expectEqual(status.excluded.first?.reason, "rotation_not_applied", "excluded reason")
    try expectEqual(status.formats.fallback, "base64_uri", "fallback format")
    try expectEqual(status.lastFetch?.uaClass, "shadowrocket", "last fetch client")
    let none = try JSONDecoder().decode(VPNLinkStatus.self, from: json(vpnNotIssuedJSON))
    try expect(!none.issued && none.link == nil, "not issued")
    let sparse = try JSONDecoder().decode(VPNLinkStatus.self, from: json(#"{"identity_id":"vu_x","issued":true}"#))
    try expectEqual(sparse.answer, "decoy", "a missing answer reads as decoy")
    try expectEqual(sparse.answerReason, "active", "a missing reason on an issued link reads active")
    try expect((try? JSONDecoder().decode(VPNLinkStatus.self, from: json(#"{"issued":true}"#))) == nil, "no identity, not a status")

    let reveal = try JSONDecoder().decode(VPNLinkReveal.self, from: json(#"{"kind":"identity","id":"vu_a","slug":"u-abc","token":"tok123","path":"/sub/u-abc/tok123"}"#))
    try expectEqual(reveal.fullURL(origin: URL(string: "https://console.example.net/")), "https://console.example.net/sub/u-abc/tok123", "revealedUrl on the console origin")
    let withURL = try JSONDecoder().decode(VPNLinkReveal.self, from: json(#"{"kind":"identity","id":"vu_a","slug":"u-abc","token":"t","path":"/sub/u-abc/t","url":"https://sub.example.net/sub/u-abc/t"}"#))
    try expectEqual(withURL.fullURL(origin: URL(string: "https://console.example.net")), "https://sub.example.net/sub/u-abc/t", "the server's public URL wins")
    try expect((try? JSONDecoder().decode(VPNLinkReveal.self, from: json(#"{"token":"t","path":"/elsewhere"}"#))) == nil, "not a link path, not a reveal")

    let credentials = try JSONDecoder().decode(VPNCredentialsReveal.self, from: json(#"""
    {"ok":true,"user":{"id":"vu_a","email":"a@example.org","enabled":true,"credentials":[],"bindings":[],"migrated":false},
     "credentials":[{"protocol":"vless","uuid":"u-1","flow":"xtls-rprx-vision"},{"protocol":"trojan","password":"p-1"},{"protocol":"tuic","uuid":"u-2","password":"p-2"}]}
    """#))
    try expectEqual(credentials.text, "vless uuid: u-1\ntrojan password: p-1\ntuic uuid: u-2\ntuic password: p-2", "credential lines")
    try expect(!String(describing: RevealedSecret(title: "x", value: credentials.text)).contains("u-1"), "a revealed value never prints")

    let lines = try JSONDecoder().decode(VPNLineList.self, from: json(vpnLinesJSON))
    try expectEqual(lines.count, 2, "line count")
    let first = lines.groups[0].lines[0]
    try expectEqual(first.lineUUID, "7a1c0e52-0000-4000-8000-000000000001", "line uuid")
    try expectEqual(first.jumpEdges, ["line_2"], "jump edges")
    try expectEqual(first.serviceCheckedAt, vpnInstant("2026-10-28T11:58:00Z"), "service checked at")
    try expect(!lines.groups[1].lines[0].userKnown, "user count not inspected")
    let nullGroups = try JSONDecoder().decode(VPNLineList.self, from: json(#"{"groups":null,"count":0}"#))
    try expect(nullGroups.groups.isEmpty, "null groups read as none")
    try expect((try? JSONDecoder().decode(VPNLineList.self, from: json(#"{"lines":[]}"#))) == nil, "a body without groups is not a line list")
}

// MARK: Identity derivations

private func vpnUser(_ text: String) throws -> VPNUser {
    try JSONDecoder().decode(VPNUser.self, from: json(text))
}

private func checkVPNIdentityDerivations() throws {
    let now = vpnInstant("2026-10-28T12:00:00Z")
    // expiryOf and expiryRelative.
    try expectEqual(VPNExpiry.of(nil, now: now), .none, "no expiry")
    try expectEqual(VPNExpiry.of(now, now: now), .expired(now), "the moment it passes is expired")
    let soon = now.addingTimeInterval(20 * 86_400 + 3_600)
    try expectEqual(VPNExpiry.of(soon, now: now), .soon(soon), "20 days is soon")
    try expectEqual(VPNExpiry.of(soon, now: now).relative(now: now), "in 20 days", "relative, rounded toward the event")
    let later = now.addingTimeInterval(31 * 86_400)
    try expectEqual(VPNExpiry.of(later, now: now), .later(later), "31 days is later")
    try expectEqual(VPNExpiry.of(now.addingTimeInterval(3_600), now: now).relative(now: now), "within a day", "within a day")
    try expectEqual(VPNExpiry.of(now.addingTimeInterval(-3 * 86_400 - 60), now: now).relative(now: now), "3 days ago", "days ago")
    try expectEqual(VPNExpiry.of(now.addingTimeInterval(-60), now: now).relative(now: now), "less than a day ago", "less than a day ago")

    // quotaState.
    try expectEqual(VPNQuota.of(used: 10, quota: 0).tone, .none, "no quota")
    try expectEqual(VPNQuota.of(used: 79, quota: 100).tone, .healthy, "under 80 percent")
    try expectEqual(VPNQuota.of(used: 80, quota: 100).tone, .warning, "80 percent warns")
    try expect(VPNQuota.of(used: 100, quota: 100).over, "reaching the quota is over")
    try expectEqual(VPNQuota.of(used: 250, quota: 100).percent, 100, "percent caps at 100")
    try expectEqual(VPNQuota.of(used: -5, quota: 100).usedBytes, 0, "negative usage clamps")

    // identityConditions: worst first; a disabled identity is only disabled.
    let base = #""email":"x@example.org","credentials":[],"migrated":false"#
    let bound = #""bindings":[{"line_hash_id":"l1","enabled":true}]"#
    let expiredOver = try vpnUser(#"{"id":"1",\#(base),"enabled":true,\#(bound),"expires_at":"2026-10-20T00:00:00Z","quota_bytes":100,"used_period_bytes":150}"#)
    try expectEqual(VPNIdentity.conditions(expiredOver, now: now), [.expired, .overQuota], "expired and over quota, in that order")
    let expiringUnbound = try vpnUser(#"{"id":"2",\#(base),"enabled":true,"bindings":[{"line_hash_id":"l1","enabled":false}],"expires_at":"2026-11-10T00:00:00Z"}"#)
    try expectEqual(VPNIdentity.conditions(expiringUnbound, now: now), [.expiring, .unbound], "an off binding is not a bound line")
    let disabled = try vpnUser(#"{"id":"3",\#(base),"enabled":false,"bindings":[],"expires_at":"2026-10-01T00:00:00Z"}"#)
    try expectEqual(VPNIdentity.conditions(disabled, now: now), [.disabled], "disabled hides every other condition")
    let active = try vpnUser(#"{"id":"4",\#(base),"enabled":true,\#(bound)}"#)
    try expectEqual(VPNIdentity.state(active, now: now), .active, "active")
    let suspended = try vpnUser(#"{"id":"5",\#(base),"enabled":true,\#(bound),"policy":{"status":"disabled","reason":"operator","suspended_by":"u-ops"}}"#)
    try expectEqual(VPNIdentity.state(suspended, now: now), .disabled, "an operator suspension is out of service")
    try expectEqual(VPNIdentity.word(suspended, state: .disabled), "suspended", "and reads as suspended")
    let quotaOnPolicyOnly = try vpnUser(#"{"id":"6",\#(base),"enabled":true,\#(bound),"policy":{"status":"over_quota","reason":"quota"}}"#)
    try expectEqual(VPNIdentity.state(quotaOnPolicyOnly, now: now), .active, "the state follows the console's figures, not the policy word")
    try expectEqual(VPNIdentity.reason(expiredOver, state: .overQuota, now: now), "150 B of 100 B used.", "over quota reason")
    try expectEqual(VPNIdentity.reason(expiringUnbound, state: .expiring, now: now), "Expires in 12 days.", "expiring reason")
    try expectEqual(VPNBytes.text(1023), "1023 B", "bytes under a KiB")
    try expectEqual(VPNBytes.text(41_000_000_000), "38.2 GiB", "binary units")
    try expectEqual(VPNBytes.text(107_374_182_400), "100 GiB", "no decimal from 100 up")

    let ordered = VPNIdentity.ordered([active, disabled, expiringUnbound, expiredOver], now: now).map(\.id)
    try expectEqual(ordered, ["1", "2", "4", "3"], "worst state first, disabled last")
    let summary = VPNUsersSummary.of([active, disabled, expiringUnbound, expiredOver], now: now)
    try expectEqual(summary.counts.map(\.state), [.expired, .overQuota, .expiring, .unbound, .active, .disabled], "counts in state order")
    try expectEqual(summary.enabled, 3, "enabled count")
    try expectEqual(summary.sentence, "4 identities. 1 expired, 1 over quota, 1 expiring, 1 no line.", "summary sentence counts each condition")

    // A legacy proxy user: no bindings, so never "no line"; its status word decides.
    let proxy = try JSONDecoder().decode(VPNProxyUser.self, from: json(#"{"id":"p","name":"p@example.org","enabled":true,"status":"expired"}"#))
    try expectEqual(VPNIdentity.conditions(VPNUser(legacy: proxy), now: now), [.expired], "legacy status word")

    // Query fields.
    guard case .success(let query) = LatticeQueryEngine.compile("status:expiring", provider: VPNUserQueryFields.self) else {
        throw CheckFailure.failed("status query compiles")
    }
    try expectEqual(LatticeQueryEngine.apply(query, to: [active, expiringUnbound], now: now).map(\.id), ["2"], "status:expiring")
    guard case .success(let free) = LatticeQueryEngine.compile("x@example", provider: VPNUserQueryFields.self) else {
        throw CheckFailure.failed("bare word compiles")
    }
    try expectEqual(LatticeQueryEngine.apply(free, to: [active], now: now).count, 1, "a bare word searches the email")
    if case .success = LatticeQueryEngine.compile("stauts:active", provider: VPNUserQueryFields.self) {
        throw CheckFailure.failed("a misspelt field is an error, never an empty list")
    }
}

// MARK: Link derivations

private func vpnStatus(_ text: String) throws -> VPNLinkStatus {
    try JSONDecoder().decode(VPNLinkStatus.self, from: json(text))
}

private func checkVPNLinkDerivations() throws {
    let day: (Date) -> String = { _ in "Nov 2" }
    let link = #""link":{"slug":"u-a","enabled":true,"issued_at":"2026-08-01T00:00:00Z","update_interval_hours":2}"#
    let none = try vpnStatus(vpnNotIssuedJSON)
    try expectEqual(VPNLinkHeadline.of(none, expiryText: day).key, .none, "no link")
    let paused = try vpnStatus(#"{"identity_id":"a","issued":true,"link":{"slug":"u-a","enabled":false},"answer":"decoy","answer_reason":"link_disabled"}"#)
    try expectEqual(VPNLinkHeadline.of(paused, expiryText: day).title, "Paused", "paused")
    let expired = try vpnStatus(#"{"identity_id":"a","issued":true,"link":{"slug":"u-a","enabled":true,"expires_at":"2026-10-01T00:00:00Z"},"answer":"decoy","answer_reason":"link_expired"}"#)
    let expiredHead = VPNLinkHeadline.of(expired, expiryText: day)
    try expect(expiredHead.tone == .error && expiredHead.detail.contains("expired on Nov 2"), "link expired names the day: \(expiredHead.detail)")
    // The server keeps the pause and the expiry across a rotation, so the
    // copy never promises that rotating alone makes the link serve.
    try expect(!expiredHead.detail.contains("new URL that serves"), "rotating an expired link does not make it serve")
    try expect(VPNLinkWords.rotateCaveat(expired.link, now: vpnInstant("2026-10-29T00:00:00Z"))?.contains("stays expired") == true, "rotating an expired link warns it stays expired")
    try expect(VPNLinkWords.rotateCaveat(paused.link, now: vpnInstant("2026-10-29T00:00:00Z"))?.contains("stays paused") == true, "rotating a paused link warns it stays paused")
    try expectEqual(VPNLinkWords.rotateCaveat(nil, now: vpnInstant("2026-10-29T00:00:00Z")), nil, "no link, no caveat")
    let quota = try vpnStatus(#"{"identity_id":"a","issued":true,\#(link),"answer":"placeholder","answer_reason":"quota","placeholder":"Quota used up"}"#)
    let quotaHead = VPNLinkHeadline.of(quota, expiryText: day)
    try expectEqual(quotaHead.detail, "The identity is over its quota, so a client gets one entry named \"Quota used up\" and no servers, with its quota shown as used up. Raising the quota serves its lines again, as does the next quota reset.", "placeholder sentence")
    let decoy = try vpnStatus(#"{"identity_id":"a","issued":true,\#(link),"answer":"decoy","answer_reason":"transient_empty","excluded":[{"line_hash_id":"l1"},{"line_hash_id":"l2"}]}"#)
    try expectEqual(VPNLinkHeadline.of(decoy, expiryText: day).title, "Serving nothing", "decoy")
    try expect(VPNLinkHeadline.of(decoy, expiryText: day).detail.contains("(2 lines, below)"), "decoy counts the lines left out")
    let active = try vpnStatus(vpnLinkStatusJSON)
    let activeHead = VPNLinkHeadline.of(active, expiryText: day)
    try expectEqual(activeHead.tone, .warning, "a line left out warns")
    try expectEqual(activeHead.detail, "Serves 1 line; 1 bound line is left out, each with the reason below.", "active with one left out")

    try expectEqual(VPNLinkWords.servedHeading(active), "Serves 1 line", "served heading")
    try expectEqual(VPNLinkWords.leftOutHeading(active), "Leaves out 1 bound line", "left out heading")
    try expectEqual(VPNLinkWords.servedHeading(paused), "Would serve 0 lines once the link is resumed", "would serve once resumed")
    try expectEqual(VPNLinkWords.leftOutHeading(quota), "Would leave out 0 bound lines", "a placeholder would leave out")
    try expect(VPNLinkWords.answers(active) && !VPNLinkWords.answers(paused) && !VPNLinkWords.answers(none), "linkAnswers")

    let left = active.excluded[0]
    try expectEqual(VPNLinkWords.excludedReason(left), "the line still has this identity's old credential", "excluded reason")
    try expectEqual(VPNLinkWords.fix(left), "queue an update plan on the web", "fix")
    try expectEqual(VPNLinkWords.lineTitle(left), "edge-tyo-2 / anytls", "line title")
    let lossy = try JSONDecoder().decode(VPNLinkLine.self, from: json(#"{"line_hash_id":"l","reason":"template_lossy","detail":"dropped: alpn"}"#))
    try expectEqual(VPNLinkWords.excludedReason(lossy), "the client template would drop parameters (dropped: alpn)", "detail in parentheses")
    let unknown = try JSONDecoder().decode(VPNLinkLine.self, from: json(#"{"line_hash_id":"l","reason":"some_new_reason"}"#))
    try expectEqual(VPNLinkWords.excludedReason(unknown), "some new reason", "an unknown reason reads as sent")
    let off = try JSONDecoder().decode(VPNLinkLine.self, from: json(#"{"line_hash_id":"l","reason":"binding_disabled"}"#))
    try expectEqual(VPNLinkWords.fix(off), "turn the binding on, on the web", "binding off with no fix")
    try expectEqual(VPNLinkWords.lineTitle(unknown), "l", "a line with no names shows its handle")

    let now = vpnInstant("2026-10-28T12:00:00Z")
    let age: (TimeInterval) -> String = { "\(Int($0 / 3_600)) hours" }
    try checkVPNFetchLine(active, now: now, age: age)
    try expectEqual(VPNLinkWords.fetch(none, now: now, age: age).text, "Never fetched", "never fetched")
    try expectEqual(VPNLinkWords.clientFamily("clashmeta"), "mihomo (Clash Verge, FlClash)", "client family")
    try expectEqual(VPNLinkWords.clientFamily("newthing"), "an unrecognised client", "unknown client")

    try expectEqual(VPNLinkWords.userinfo("upload=1073741824; download=9663676416; total=107374182400", answer: "nodes", day: day),
                    "10.0 GiB of 100 GiB", "userinfo with a total")
    try expectEqual(VPNLinkWords.userinfo("upload=0; download=524288000", answer: "placeholder", day: day),
                    "500.0 MiB used, no limit, shown as used up", "userinfo without a total")
    try expectEqual(VPNLinkWords.userinfo("upload=0; download=0; total=1073741824; expire=1793577600", answer: "nodes", day: day),
                    "0.0 MiB of 1.0 GiB, expires Nov 2", "userinfo with an expiry")
    try expectEqual(VPNLinkWords.userinfo("", answer: "nodes", day: day), "", "no header")

    let summary = try JSONDecoder().decode(VPNLinkSummary.self, from: json(#"{"slug":"u-a","enabled":true,"expires_at":"2026-10-01T00:00:00Z"}"#))
    try expectEqual(VPNLinkWords.badge(summary, now: now), .expired, "expired badge")
    try expectEqual(summary.updateIntervalHours, 2, "the default refresh period")
    try expectEqual(VPNLinkWords.badge(nil, now: now), nil, "no badge without a link")
    try expectEqual(VPNLinkWords.pathHint("u-a"), "/sub/u-a/…", "path hint")
}

/// The last fetch was at 09:00 and the link refreshes every 12 hours, so a
/// fetch three hours ago is within twice the interval: fresh and healthy.
private func checkVPNFetchLine(_ status: VPNLinkStatus, now: Date, age: (TimeInterval) -> String) throws {
    let line = VPNLinkWords.fetch(status, now: now, age: age)
    try expectEqual(line.freshness, .fresh, "fresh within twice the refresh period")
    try expect(line.healthy, "a fresh fetch that got the servers is healthy")
    try expectEqual(line.text, "Fetched 3 hours ago by Shadowrocket, got the servers", "fetch sentence")
    let late = VPNLinkWords.fetch(status, now: now.addingTimeInterval(30 * 3_600), age: age)
    try expectEqual(late.freshness, .stale, "past twice the refresh period is stale")
    try expect(late.text.hasSuffix(". Overdue: clients refresh every \(status.link?.updateIntervalHours ?? 0) hours"), "a stale fetch says it is overdue in words: \(late.text)")
    try expect(!line.text.contains("Overdue"), "a fresh fetch is not overdue")
}

// MARK: Line derivations

private func vpnLine(_ fields: String) throws -> VPNLine {
    try JSONDecoder().decode(VPNLine.self, from: json(#"{"line_hash_id":"l","node_id":"n",\#(fields)}"#))
}

private func checkVPNLineDerivations() throws {
    // lineStateOf: a dead service outranks a clean config; unknown keeps the config verdict.
    try expectEqual(VPNLineState.of(try vpnLine(#""status":"ok","service_state":"down""#)), .down, "down")
    try expectEqual(VPNLineState.of(try vpnLine(#""status":"ok","last_error":"boom","service_state":"running""#)), .configError, "an error outranks running")
    try expectEqual(VPNLineState.of(try vpnLine(#""status":"error","service_state":"restarting""#)), .configError, "config error outranks restarting")
    try expectEqual(VPNLineState.of(try vpnLine(#""status":"ok","service_state":"restarting""#)), .restarting, "restarting")
    try expectEqual(VPNLineState.of(try vpnLine(#""status":"pending","service_state":"running""#)), .pending, "pending outranks running")
    try expectEqual(VPNLineState.of(try vpnLine(#""status":"stale""#)), .stale, "stale")
    try expectEqual(VPNLineState.of(try vpnLine(#""status":"ok","service_state":"running""#)), .running, "running")
    try expectEqual(VPNLineState.of(try vpnLine(#""status":"ok","service_note":"no process""#)), .unproven, "unproven")
    try expectEqual(VPNLineState.of(try vpnLine(#""status":"ok""#)), .configOK, "config ok")

    // lineRole and lineTarget.
    let relay = try vpnLine(#""outbound_ref":"hk/in","outbound_server":"relay.example.net","outbound_port":8443"#)
    try expectEqual(VPNLineRole.of(relay), .relay, "an outbound with server and port relays")
    try expectEqual(VPNLineTarget.of(relay, in: []), .offFleet("relay.example.net:8443"), "an unresolved relay is off the fleet")
    try expectEqual(VPNLineRole.of(try vpnLine(#""outbound_ref":"direct""#)), .exit, "direct is an exit")
    try expectEqual(VPNLineTarget.of(try vpnLine(#""outbound_ref":"direct""#), in: []), .direct, "exits directly")
    try expectEqual(VPNLineRole.of(try vpnLine("\"name\":\"x\"")), .orphan, "no outbound at all")
    let groups = try JSONDecoder().decode(VPNLineList.self, from: json(vpnLinesJSON)).groups
    let entry = groups[0].lines[0]
    try expectEqual(VPNLineTarget.of(entry, in: groups), .node(id: "n-hkg", name: "relay-hkg-1", more: 0), "a resolved jump edge names the node")
    try expectEqual(VPNLineTarget.of(entry, in: groups).sentence, "relays to relay-hkg-1", "target sentence")

    try expectEqual(VPNLineFormat.hostPort("2001:db8::1", 443), "[2001:db8::1]:443", "IPv6 in brackets")
    try expectEqual(VPNLineFormat.hostPort("edge.example.net", 0), "edge.example.net", "no port")
    try expectEqual(VPNLineFormat.hostPort(" ", 443), "", "no host")
    try expectEqual(VPNLineFormat.shape(entry), "vless · reality · tcp", "shape")
    try expectEqual(VPNLineFormat.users(groups[1].lines[0]), "users not inspected yet", "uninspected users")
    try expectEqual(VPNLineFormat.users(entry), "6 users", "user count")

    let flat = VPNLineEntry.flatten(groups)
    try expectEqual(flat.map(\.line.lineHashID), ["line_2", "line_1"], "unproven ranks above running")
    try expectEqual(VPNLineEntry.find("7a1c0e52-0000-4000-8000-000000000001", in: groups)?.line.lineHashID, "line_1", "found by M3's line uuid")
    try expectEqual(VPNLineEntry.find("line_2", in: groups)?.nodeName, "relay-hkg-1", "found by hash id")
    try expect(VPNLineEntry.find("nope", in: groups) == nil, "unknown line")

    // Chain health joined by uuid, from M3's chain rows.
    let chains = try JSONDecoder().decode([MonitoringLineChain].self, from: json(#"""
    [{"source_line_uuid":"7a1c0e52-0000-4000-8000-000000000001","source_node_id":"n-tyo","status":"drifted","last_error":"observed_route_missing",
      "current":{"target_line_uuid":"7a1c0e52-0000-4000-8000-000000000002","target_node_id":"n-hkg","status":"drifted"}}]
    """#))
    let chain = try expectUnwrapped(VPNLineChain.of(entry, chains: chains), "the line is in a chain")
    try expectEqual(chain.state, .drifted, "the line's own route state")
    try expectEqual(chain.problem, "observed route missing", "route error in words")
    try expectEqual(chain.chain.hops.count, 2, "entry and exit hops")
    try expect(VPNLineChain.of(groups[1].lines[0], chains: chains) == nil, "a line with no uuid is in no chain")

    // Query fields.
    guard case .success(let query) = LatticeQueryEngine.compile("state:unproven node:relay", provider: VPNLineQueryFields.self) else {
        throw CheckFailure.failed("line query compiles")
    }
    try expectEqual(LatticeQueryEngine.apply(query, to: flat, now: Date()).map(\.line.lineHashID), ["line_2"], "line query")

    // Bound identities.
    let users = try JSONDecoder().decode(VPNUserList.self, from: json(vpnUsersJSON)).users
    try expectEqual(VPNLineUsers.bound(to: entry, users: users).map(\.id), ["vu_a"], "identities bound to a line")
}

// MARK: Requests

private func checkVPNRequests() async throws {
    let call = "\(vpnBase)/api/plugins/call"
    let (client, transport) = vpnClient([call: (200, json(vpnUsersJSON))])
    let listing = try await client.vpnListUsers()
    try expectEqual(listing.source, .vpnCore, "read through vpn-core")
    try expectEqual(listing.users.count, 2, "two identities")
    let body = try bodyObject(await transport.lastBody)
    try expectEqual(body["id"] as? String, "latticenet.vpn-core", "plugin id")
    try expectEqual(body["service"] as? String, "latticenet.vpn-core/users", "users service")
    try expectEqual(body["method"] as? String, "list", "list method")
    try expect(body["payload"] == nil, "list sends no payload")
    try expectEqual(await transport.methods, ["POST"], "plugin calls are POST")

    // vpn-core not active: the gateway answers 400 and the list falls back.
    let fallback = vpnClient([
        call: (400, json(#"{"error":"plugin does not expose this interface/method (or is not active)"}"#)),
        "\(vpnBase)/api/proxy/users": (200, json(#"{"users":[{"id":"alice","name":"alice@example.org","enabled":true,"has_uuid":true,"status":"active"}]}"#)),
    ])
    let legacy = try await fallback.0.vpnListUsers()
    try expectEqual(legacy.source, .legacyProxyUser, "fell back to the legacy proxy users")
    try expectEqual(legacy.users.map(\.email), ["alice@example.org"], "legacy rows")
    try expectEqual(await fallback.1.requestURLs, [call, "\(vpnBase)/api/proxy/users"], "plugin first, then the legacy list")

    // A body the app cannot read is companion behind, never a fallback or an empty list.
    let behind = vpnClient([call: (200, json("<!doctype html><title>Lattice</title>"))])
    do {
        _ = try await behind.0.vpnListUsers()
        throw CheckFailure.failed("an undecodable list must throw")
    } catch let error as LatticeAPIError {
        try expectEqual(error, .invalidResponse, "decode failure is invalidResponse")
    }
    try expectEqual(await behind.1.requestURLs.count, 1, "no fallback on a decode failure")
    let denied = vpnClient([call: (403, json(#"{"error":"forbidden","code":"capability_denied"}"#))])
    do {
        _ = try await denied.0.vpnListUsers()
        throw CheckFailure.failed("a refusal must throw")
    } catch let error as LatticeAPIError {
        guard case .forbidden = error else { throw CheckFailure.failed("403 is forbidden, got \(error)") }
    }

    let get = vpnClient([call: (200, json(#"{"user":{"id":"vu_a","email":"a@example.org","enabled":true,"credentials":[],"bindings":[],"migrated":false}}"#))])
    let fetched = try await get.0.vpnGetUser(id: "vu_a")
    let getBody = try bodyObject(await get.1.lastBody)
    try expectEqual(getBody["method"] as? String, "get", "get method")
    try expectEqual((getBody["payload"] as? [String: Any])?["id"] as? String, "vu_a", "get payload {id}")
    // The gateway answers an unknown id with the generic 502 text, so only a
    // list read without the id makes it missing.
    let upstream = LatticeAPIError.server(status: 502, code: "bad_gateway", message: "upstream service error")
    let held = VPNUserListing(users: [fetched], source: .vpnCore)
    let empty = VPNUserListing(users: [], source: .vpnCore)
    try expect(LatticeClient.vpnUserGetAmbiguous(upstream), "a 502 from get is ambiguous")
    try expect(LatticeClient.vpnUserMissing(upstream, listing: empty, id: "vu_a"), "502 and a list without the id is missing")
    try expect(!LatticeClient.vpnUserMissing(upstream, listing: held, id: "vu_a"), "502 while the list holds the id is a failure")
    try expect(!LatticeClient.vpnUserMissing(upstream, listing: nil, id: "vu_a"), "502 with no list read is a failure")
    try expect(!LatticeClient.vpnUserMissing(.server(status: 500, code: nil, message: "internal"), listing: empty, id: "vu_a"), "a 500 is never missing")
    try expect(!LatticeClient.vpnUserMissing(.forbidden(code: "capability_denied", message: "forbidden"), listing: empty, id: "vu_a"), "a refusal is never missing")

    let lines = vpnClient([call: (200, json(vpnLinesJSON))])
    let groups = try await lines.0.vpnListLines()
    try expectEqual(groups.count, 2, "two node groups")
    let linesBody = try bodyObject(await lines.1.lastBody)
    try expectEqual(linesBody["service"] as? String, "latticenet.vpn-core/lines", "lines service")

    // Link status, rotate and revoke: the exact paths and methods, no body.
    let link = "\(vpnBase)/api/vpn/users/vu_a/link"
    let (linkClient, linkTransport) = vpnClient([
        link: (200, json(vpnLinkStatusJSON)),
        "\(link)/rotate": (200, json(vpnLinkStatusJSON)),
    ])
    _ = try await linkClient.vpnLinkStatus(userID: "vu_a")
    _ = try await linkClient.vpnRotateLink(userID: "vu_a")
    try expectEqual(await linkTransport.methods, ["GET", "POST"], "status GET, rotate POST")
    try expectEqual(await linkTransport.requestURLs, [link, "\(link)/rotate"], "link paths")
    let rotateBodies = await linkTransport.bodies
    try expect(rotateBodies.allSatisfy { $0 == nil }, "rotate sends no body")
    let revoke = vpnClient([link: (200, json(vpnNotIssuedJSON))])
    let revoked = try await revoke.0.vpnRevokeLink(userID: "vu_a")
    try expectEqual(await revoke.1.methods, ["DELETE"], "revoke is DELETE")
    let revokeBodies = await revoke.1.bodies
    try expect(revokeBodies.allSatisfy { $0 == nil }, "revoke sends no body")
    try expect(!revoked.issued, "revoke answers the status without a link")
    try expectEqual(LatticeClient.vpnLinkPath("vu/x"), "/api/vpn/users/vux/link", "a slash never splits the id")

    // Reveal: `{step_up_grant}` to .../link/reveal on the session.
    let grant = StepUpGrant(grant: "grant-1", expiresAt: Date().addingTimeInterval(60))
    let (revealClient, revealTransport) = vpnClient([
        "\(link)/reveal": (200, json(#"{"kind":"identity","id":"vu_a","slug":"u-abc","token":"t0k","path":"/sub/u-abc/t0k"}"#)),
    ], session: true)
    let reveal = try await revealClient.vpnRevealLink(userID: "vu_a", grant: grant)
    try expectEqual(reveal.token, "t0k", "token")
    let revealBody = try bodyObject(await revealTransport.lastBody)
    try expectEqual(revealBody.keys.sorted(), ["step_up_grant"], "the reveal body carries only the grant")
    try expectEqual(revealBody["step_up_grant"] as? String, "grant-1", "grant value")
    try expectEqual(await revealTransport.csrfHeaders, ["csrf-check"], "session writes carry the CSRF header")

    let (credClient, credTransport) = vpnClient([
        "\(vpnBase)/api/proxy/users/reveal-credentials": (200, json(#"{"ok":true,"user":{"id":"vu_a","email":"a@example.org","enabled":true,"credentials":[],"bindings":[],"migrated":false},"credentials":[{"protocol":"vless","uuid":"u"}]}"#)),
    ], session: true)
    _ = try await credClient.vpnRevealCredentials(userID: "vu_a", grant: grant)
    let credBody = try bodyObject(await credTransport.lastBody)
    try expectEqual(credBody.keys.sorted(), ["id", "step_up_grant"], "credential reveal body")
    try expectEqual(credBody["id"] as? String, "vu_a", "credential reveal id")

    // Body goldens, byte for byte.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try expectEqual(String(decoding: try encoder.encode(VPNLinkRevealRequest(stepUpGrant: "g")), as: UTF8.self), #"{"step_up_grant":"g"}"#, "reveal body golden")
    try expectEqual(String(decoding: try encoder.encode(VPNCredentialsRevealRequest(id: "vu_a", stepUpGrant: "g")), as: UTF8.self),
                    #"{"id":"vu_a","step_up_grant":"g"}"#, "credentials body golden")
    try expectEqual(String(decoding: try encoder.encode(VPNUserGetRequest(id: "vu_a")), as: UTF8.self), #"{"id":"vu_a"}"#, "get payload golden")
}

// MARK: Intents

private func checkVPNIntents() async throws {
    let rotate = VPNIntents.rotateLink(userID: "vu_a", email: "a@example.org", rotatedBefore: vpnInstant("2026-10-01T10:00:00Z"))
    try expectEqual(rotate.tier, .t3, "rotate is T3")
    try expectEqual(rotate.scopes, ["vpncore:admin"], "rotate scope")
    try expect(rotate.consequence.hasPrefix("The old link stops working at once"), "rotate states the consequence")
    try expect(!rotate.idempotent, "rotate is never retried")
    try expect(rotate.consequence.hasSuffix("send it again."), "a serving link is sent again after rotating")
    let stuck = VPNIntents.rotateLink(userID: "vu_a", email: "a@example.org", rotatedBefore: nil, caveat: "The new link stays expired. Remove the expiry on the web before it serves.")
    try expect(stuck.consequence.hasSuffix("before it serves.") && !stuck.consequence.contains("send it again"), "an expired link is not sent again: \(stuck.consequence)")
    let revoke = VPNIntents.revokeLink(userID: "vu_a", email: "a@example.org")
    try expectEqual(revoke.tier, .t4, "revoke is T4")
    try expectEqual(revoke.title, "Revoke the link of a@example.org", "revoke title names the identity")

    // Cancelling Face ID sends nothing.
    let (client, transport) = vpnClient([:])
    let cancelled = await WriteFlow(intent: rotate, client: client, authenticator: VPNAuthStub(outcome: .cancelled)).commit(choices: ConfirmChoices(), reviewed: nil)
    guard case .cancelled = cancelled else { throw CheckFailure.failed("a cancelled rotate is cancelled") }
    try expectEqual(await transport.requestURLs.count, 0, "a cancelled rotate sends zero requests")

    let link = "\(vpnBase)/api/vpn/users/vu_a/link"
    let rotated = vpnClient(["\(link)/rotate": (200, json(vpnLinkStatusJSON))])
    let done = await WriteFlow(intent: rotate, client: rotated.0, authenticator: VPNAuthStub()).commit(choices: ConfirmChoices(), reviewed: nil)
    guard case .finished(.done(let message, _)) = done else { throw CheckFailure.failed("rotate finishes done, got \(done)") }
    try expectEqual(message, "Rotated a@example.org's link: the old link no longer works", "rotate banner")

    let missing = vpnClient(["\(link)/rotate": (404, json(#"{"error":"this identity has no link; issue one first","code":"link_not_issued"}"#))])
    let refused = await WriteFlow(intent: rotate, client: missing.0, authenticator: VPNAuthStub()).commit(choices: ConfirmChoices(), reviewed: nil)
    guard case .finished(.refused(.notFound, let text)) = refused else { throw CheckFailure.failed("rotate without a link is refused, got \(refused)") }
    try expect(text.contains("has no subscription link"), "refusal names the missing link")

    let gone = vpnClient([link: (200, json(vpnNotIssuedJSON))])
    let revokedOutcome = await WriteFlow(intent: revoke, client: gone.0, authenticator: VPNAuthStub()).commit(choices: ConfirmChoices(), reviewed: nil)
    guard case .finished(.done) = revokedOutcome else { throw CheckFailure.failed("revoke finishes done, got \(revokedOutcome)") }
    try expectEqual(await gone.1.methods, ["DELETE"], "revoke sends one DELETE")

    // The verify after a lost answer reads the server's stamp.
    let verify = vpnClient([link: (200, json(vpnLinkStatusJSON))])
    try expectEqual(try await rotate.verify!(verify.0), "a@example.org's link was not rotated.", "same stamp as before: not rotated")

    let reveal = VPNIntents.revealLink(userID: "vu_a", email: "a@example.org", origin: URL(string: "https://console.example.net"))
    try expect(reveal.shareable, "a subscription link may be shared")
    try expectEqual(reveal.purpose, .vpnLink, "reveal purpose")
    try expectEqual(reveal.title, "Reveal the subscription link for a@example.org", "reveal title")
    let grant = StepUpGrant(grant: "g", expiresAt: Date().addingTimeInterval(60))
    let session = vpnClient(["\(link)/reveal": (200, json(#"{"kind":"identity","id":"vu_a","slug":"u-abc","token":"t0k","path":"/sub/u-abc/t0k"}"#))], session: true)
    let secret = try await reveal.perform(session.0, grant)
    try expectEqual(secret.value, "https://console.example.net/sub/u-abc/t0k", "the link on the console origin")
    try expectEqual(secret.kind, .shareableLink, "shareable link kind")
    let credentials = VPNIntents.revealCredentials(userID: "vu_a", email: "a@example.org")
    try expect(!credentials.shareable, "credentials are copy only")
    try expectEqual(credentials.scopes, ["proxy:admin"], "credentials scope")
}

// MARK: Demo

private func checkVPNDemo() async throws {
    let state = DemoState()
    let clock = DemoClock(pinned: "2026-10-28T12:00:00Z")!
    func client(_ identity: DemoIdentity = .pat, _ scenario: DemoScenario = .normal) -> LatticeClient {
        let credential = identity == .pat ? LatticeCredential(bearerToken: DemoWorld.token) : LatticeCredential(sessionCookie: "demo", csrfToken: "demo")
        return LatticeClient(baseURL: DemoWorld.baseURL, credential: credential,
                             transport: DemoTransport(identity: identity, scenario: scenario, clock: clock, state: state))
    }
    let now = clock.anchor
    let listing = try await client().vpnListUsers()
    try expectEqual(listing.users.count, VPNFixtures.users.count, "every demo identity")
    let states = Set(listing.users.map { VPNIdentity.state($0, now: now) })
    try expectEqual(states, Set(VPNIdentityState.allCases), "the demo covers every identity state")
    try expect(listing.users.contains { VPNIdentity.word($0, state: VPNIdentity.state($0, now: now)) == "suspended" }, "and an operator suspension")
    try expect(listing.users.allSatisfy { $0.bindings.allSatisfy { binding in VPNFixtures.lines.contains { $0.hash == binding.lineHashID } } },
               "every binding names a demo line")
    let alice = try expectUnwrapped(listing.user(id: "vu_alice"), "alice")
    try expectEqual(VPNIdentity.state(alice, now: now), .expiring, "alice expires within the Upcoming window")

    let groups = try await client().vpnListLines()
    let entries = VPNLineEntry.flatten(groups)
    try expectEqual(entries.count, VPNFixtures.lines.count, "every demo line")
    try expectEqual(Set(entries.map { VPNLineState.of($0.line) }), Set(VPNLineState.allCases), "the demo covers every line state")
    try expect(entries.allSatisfy { DemoWorld.node(id: $0.nodeID) != nil }, "lines sit on demo nodes")
    let chains = try await client().monitoringLineChains()
    let chained = entries.filter { VPNLineChain.of($0.line, chains: chains) != nil }
    try expectEqual(chained.count, 7, "seven lines take part in M3's chains")
    let tyo = try expectUnwrapped(entries.first { $0.line.displayName == "tyo-reality" }, "tyo-reality")
    try expectEqual(VPNLineChain.of(tyo.line, chains: chains)?.chain.hops.count, 3, "edge-tyo-1 to relay-hkg-1 to relay-fra-1")
    try expectEqual(VPNLineTarget.of(tyo.line, in: groups).sentence, "relays to relay-hkg-1", "tyo relays to hkg")

    // Detail by id, and an id the server does not hold.
    let user = try await client().vpnGetUser(id: "vu_bob")
    try expectEqual(VPNIdentity.state(user, now: now), .overQuota, "bob is over his quota")
    do {
        _ = try await client().vpnGetUser(id: VPNFixtures.missingUserID)
        throw CheckFailure.failed("an unknown identity must throw")
    } catch let error as LatticeAPIError {
        guard case .server(502, _, let message) = error else { throw CheckFailure.failed("unknown identity answers 502, got \(error)") }
        try expect(message.hasPrefix("upstream service error"), "the server's generic 502 text, never the service's: \(message)")
        let listing = try await client().vpnListUsers()
        try expect(LatticeClient.vpnUserMissing(error, listing: listing, id: VPNFixtures.missingUserID), "the list confirms the unknown identity is missing")
        try expect(!LatticeClient.vpnUserMissing(error, listing: listing, id: "vu_bob"), "a listed identity is never missing")
    }

    // Each link headline the screens show.
    let day: (Date) -> String = { _ in "day" }
    var keys: [String: VPNLinkHeadline.Key] = [:]
    for fixture in VPNFixtures.users {
        keys[fixture.id] = VPNLinkHeadline.of(try await client().vpnLinkStatus(userID: fixture.id), expiryText: day).key
    }
    try expectEqual(keys["vu_alice"], .active, "alice active")
    try expectEqual(keys["vu_bob"], .placeholder, "bob placeholder")
    try expectEqual(keys["vu_carol"], VPNLinkHeadline.Key.none, "carol no link")
    try expectEqual(keys["vu_dave"], .paused, "dave paused")
    try expectEqual(keys["vu_grace"], .empty, "grace serving nothing")

    // Rotate, reveal and revoke change what the demo answers.
    let rotateIntent = VPNIntents.rotateLink(userID: "vu_alice", email: "alice@example.org", rotatedBefore: alice.link?.rotatedAt)
    let rotated = await WriteFlow(intent: rotateIntent, client: client(), authenticator: VPNAuthStub()).commit(choices: ConfirmChoices(), reviewed: nil)
    guard case .finished(.done) = rotated else { throw CheckFailure.failed("demo rotate, got \(rotated)") }
    try expectEqual(try await rotateIntent.verify!(client()), "alice@example.org's link was rotated.", "the rotation stamp moved")
    let grant = StepUpGrant(grant: "demo-grant", expiresAt: now.addingTimeInterval(60))
    let secret = try await VPNIntents.revealLink(userID: "vu_alice", email: "alice@example.org", origin: nil).perform(client(.session), grant)
    try expect(secret.value.contains("not-a-secret") && secret.value.hasPrefix("https://demo.lattice.invalid/sub/u-"), "an obviously fake link: \(secret.value)")
    let credentials = try await VPNIntents.revealCredentials(userID: "vu_alice", email: "alice@example.org").perform(client(.session), grant)
    try expect(credentials.value.contains("vless uuid: 00000000-demo"), "fake credentials")
    let revoked = await WriteFlow(intent: VPNIntents.revokeLink(userID: "vu_alice", email: "alice@example.org"), client: client(),
                                  authenticator: VPNAuthStub()).commit(choices: ConfirmChoices(), reviewed: nil)
    guard case .finished(.done) = revoked else { throw CheckFailure.failed("demo revoke, got \(revoked)") }
    let afterRevoke = try await client().vpnLinkStatus(userID: "vu_alice")
    try expect(!afterRevoke.issued, "the revoked link is gone")
    do {
        _ = try await VPNIntents.revealLink(userID: "vu_alice", email: "alice@example.org", origin: nil).perform(client(.session), grant)
        throw CheckFailure.failed("revealing a revoked link must fail")
    } catch let error as LatticeAPIError {
        try expect(error.localizedDescription.contains("has no subscription link"), "a revoked link says so: \(error)")
    }

    // Scope gates as the server's wrappers decide them.
    do {
        _ = try await client(.pat, .limitedToken).vpnListUsers()
        throw CheckFailure.failed("Triage cannot read identities")
    } catch let error as LatticeAPIError {
        guard case .forbidden = error else { throw CheckFailure.failed("Triage is refused, got \(error)") }
    }
    let emptyUsers = try await client(.pat, .empty).vpnListUsers()
    try expect(emptyUsers.users.isEmpty, "Empty serves no identities")
    let emptyLines = try await client(.pat, .empty).vpnListLines()
    try expect(emptyLines.isEmpty, "Empty serves no lines")
    do {
        _ = try await client(.pat, .companionBehind(prefix: "/api/plugins/call")).vpnListUsers()
        throw CheckFailure.failed("companion behind must throw")
    } catch let error as LatticeAPIError {
        try expectEqual(error, .invalidResponse, "companion behind is a decode failure")
    }
    let proxy = try await client().vpnProxyUsers()
    try expect(!proxy.isEmpty, "the legacy list has rows")
}
