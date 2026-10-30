import Foundation

// M13 owns GET proxy/users, POST proxy/users/reveal-credentials and the
// vpn/users/{id}/link endpoints (section 8.4). Reads of identities and lines
// go through the Shared `callPlugin`; line chains come from M3's
// `monitoringLineChains`.

public extension LatticeClient {
    // MARK: Identities

    /// The identities: vpn-core `users.list` (vpncore:read, unconfined),
    /// falling back to `GET /api/proxy/users` only when the server says
    /// vpn-core does not expose the method (400, or 404 from a server with
    /// no plugin gateway). Any other failure, a decode failure included, is
    /// thrown: a body the app cannot read is companion behind, never empty.
    func vpnListUsers() async throws -> VPNUserListing {
        do {
            let list = try await callPlugin(VPNUserList.self, id: VPNService.pluginID, service: VPNService.users, method: "list")
            return VPNUserListing(users: list.users, source: .vpnCore)
        } catch let error as LatticeAPIError where Self.vpnPluginUnavailable(error) {
            return VPNUserListing(users: try await vpnProxyUsers().map(VPNUser.init(legacy:)), source: .legacyProxyUser)
        }
    }

    /// One identity through vpn-core `users.get`.
    func vpnGetUser(id: String) async throws -> VPNUser {
        try await callPlugin(VPNUserEnvelope.self, id: VPNService.pluginID, service: VPNService.users, method: "get",
                             body: VPNUserGetRequest(id: id)).user
    }

    /// `GET /api/proxy/users` (proxy:read, unconfined): the legacy substrate.
    func vpnProxyUsers() async throws -> [VPNProxyUser] {
        try await perform(VPNProxyUserList.self, path: "/api/proxy/users").users
    }

    /// True when a plugin call failed because the plugin is not active or
    /// does not declare the method, which `handlePluginCall` answers 400.
    static func vpnPluginUnavailable(_ error: LatticeAPIError) -> Bool {
        switch error {
        case .server(let status, _, _): status == 400
        case .notFound: true
        default: false
        }
    }

    /// True when a vpn-core `get` failure may mean the id is gone. The
    /// gateway answers an unknown id with a plain 502 "upstream service
    /// error", the same body as any other upstream failure, so this alone
    /// never proves absence; `vpnUserMissing(_:listing:id:)` does.
    static func vpnUserGetAmbiguous(_ error: LatticeAPIError) -> Bool {
        switch error {
        case .notFound: true
        case .server(let status, _, _): status == 502
        default: false
        }
    }

    /// True when `get` failed in a way that may mean absence and a list read
    /// after it holds no such id. A list that did not load proves nothing.
    static func vpnUserMissing(_ error: LatticeAPIError, listing: VPNUserListing?, id: String) -> Bool {
        guard vpnUserGetAmbiguous(error), let listing else { return false }
        return listing.user(id: id) == nil
    }

    // MARK: Identity link

    /// `GET /api/vpn/users/{id}/link` (vpncore:admin, unconfined): what the
    /// link serves now, never the token.
    func vpnLinkStatus(userID: String) async throws -> VPNLinkStatus {
        try await perform(VPNLinkStatus.self, path: Self.vpnLinkPath(userID))
    }

    /// `POST /api/vpn/users/{id}/link/rotate`: a new token; the old one
    /// answers the decoy at once.
    func vpnRotateLink(userID: String) async throws -> VPNLinkStatus {
        try await perform(VPNLinkStatus.self, path: Self.vpnLinkPath(userID) + "/rotate", method: "POST")
    }

    /// `DELETE /api/vpn/users/{id}/link`: removes the link and replaces the
    /// stored token with one nothing serves.
    func vpnRevokeLink(userID: String) async throws -> VPNLinkStatus {
        try await perform(VPNLinkStatus.self, path: Self.vpnLinkPath(userID), method: "DELETE")
    }

    /// `POST /api/vpn/users/{id}/link/reveal {step_up_grant}` on the session.
    func vpnRevealLink(userID: String, grant: StepUpGrant) async throws -> VPNLinkReveal {
        try await perform(VPNLinkReveal.self, path: Self.vpnLinkPath(userID) + "/reveal", method: "POST",
                          body: VPNLinkRevealRequest(stepUpGrant: grant.grant))
    }

    /// `POST /api/proxy/users/reveal-credentials {id, step_up_grant}` on the
    /// session (proxy:admin, unconfined).
    func vpnRevealCredentials(userID: String, grant: StepUpGrant) async throws -> VPNCredentialsReveal {
        try await perform(VPNCredentialsReveal.self, path: "/api/proxy/users/reveal-credentials", method: "POST",
                          body: VPNCredentialsRevealRequest(id: userID, stepUpGrant: grant.grant))
    }

    /// `/api/vpn/users/{id}/link`. The request builder sets the path through
    /// `URLComponents.path`, which escapes what a segment needs, so the id is
    /// passed as is; a slash would split it, so it never reaches the server.
    static func vpnLinkPath(_ userID: String) -> String {
        "/api/vpn/users/\(userID.replacingOccurrences(of: "/", with: ""))/link"
    }

    // MARK: Lines

    /// The lines, grouped by node: vpn-core `lines.list` (vpncore:read, unconfined).
    func vpnListLines() async throws -> [VPNLineGroup] {
        try await callPlugin(VPNLineList.self, id: VPNService.pluginID, service: VPNService.lines, method: "list").groups
    }
}
