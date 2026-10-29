import Foundation

// POST /api/login, /api/login/totp, /api/logout and /api/security/step-up.
// Any password signs in and asks for a code; any six digits pass except
// 000000, which the step-up answers as a wrong code (section 7.3).
extension SharedFixtures {
    static let wrongCode = "000000"

    static var sessionRoutes: [DemoRoute] {
        [
            DemoRoute(method: "POST", pathPattern: "/api/login") { request, _ in
                guard let username = request.bodyStrings["username"], !username.isEmpty else {
                    return .error(status: 400, code: "bad_request", message: "username and password are required")
                }
                return .json(#"{"totp_required":true,"challenge_id":"chal_demo0001"}"#)
            },
            DemoRoute(method: "POST", pathPattern: "/api/login/totp") { request, _ in
                let code = request.bodyStrings["code"] ?? ""
                guard code.count == 6, code != wrongCode else {
                    return .error(status: 401, code: "unauthorized", message: "invalid second factor")
                }
                return DemoResponse(
                    status: 200,
                    body: DemoJSON.object([
                        "csrf_token": "csrf_demo_notasecret",
                        "actor_id": .string(DemoWorld.actorID),
                        "mfa_required": false,
                        "totp_policy_required": true,
                    ]).text,
                    headers: ["Set-Cookie": "lattice_session=sess_demo_notasecret; Path=/; Max-Age=43200; HttpOnly; Secure; SameSite=Strict"]
                )
            },
            DemoRoute(method: "POST", pathPattern: "/api/logout", body: #"{"ok":true}"#),
            DemoRoute(method: "POST", pathPattern: "/api/security/step-up") { request, _ in
                guard request.identity == .session else {
                    return .error(status: 403, code: "forbidden", message: "step-up needs a signed-in session")
                }
                let code = request.bodyStrings["code"] ?? ""
                guard code.count == 6, code.allSatisfy(\.isNumber), code != wrongCode else {
                    return .error(status: 401, code: "unauthorized", message: "invalid second factor")
                }
                return .json(#"{"ok":true,"grant":"grant_demo_notasecret","expires_at":"{{now+60s}}"}"#)
            },
        ]
    }
}
