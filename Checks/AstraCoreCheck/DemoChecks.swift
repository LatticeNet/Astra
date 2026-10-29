import Foundation
import AstraCore

public func checkDemo() async throws {
    try checkFixtureRegistry()
    try checkClockTokens()
    try await checkUnmatchedRoute()
}

/// The uniqueness key has no duplicates. M0a adds the `emptyBody`, literal
/// timestamp and approval hash assertions of section 8.6.
private func checkFixtureRegistry() throws {
    let keys = DemoFixtures.all.map(\.uniquenessKey)
    try expectEqual(Set(keys).count, keys.count, "demo routes are unique by method, path, query and body match")
}

private func checkClockTokens() throws {
    let clock = try expectUnwrapped(DemoClock(pinned: "2026-10-28T12:00:00Z"), "pinned demo clock")
    try expectEqual(
        clock.substitute(#"{"a":"{{now}}","b":"{{now-12s}}","c":"{{now+3d}}"}"#),
        #"{"a":"2026-10-28T12:00:00Z","b":"2026-10-28T11:59:48Z","c":"2026-10-31T12:00:00Z"}"#,
        "time tokens are served relative to the demo clock"
    )
    try expectEqual(DemoScenario(argument: "failing:/api/monitors"), .failing(prefix: "/api/monitors"), "scenario argument with a prefix")
}

private func checkUnmatchedRoute() async throws {
    let transport = DemoTransport(identity: .pat, clock: DemoClock(anchor: Date(), isPinned: true), routes: [])
    let client = LatticeClient(baseURL: DemoWorld.baseURL, credential: LatticeCredential(bearerToken: DemoWorld.token), transport: transport)
    do {
        _ = try await client.fetchHealth()
        throw CheckFailure.failed("an unmatched demo route must not succeed")
    } catch LatticeAPIError.notFound {
        // expected: a missing fixture looks like a missing endpoint
    }
}
