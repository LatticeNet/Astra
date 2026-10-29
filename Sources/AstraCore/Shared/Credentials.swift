import Foundation

public struct LatticeCredential: Codable, Equatable, Hashable, Sendable {
    public var bearerToken: String
    public var sessionCookie: String
    public var csrfToken: String

    public init(bearerToken: String = "", sessionCookie: String = "", csrfToken: String = "") {
        self.bearerToken = bearerToken
        self.sessionCookie = sessionCookie
        self.csrfToken = csrfToken
    }

    public var hasAuthentication: Bool {
        !bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !sessionCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct LatticeLoginRequest: Encodable {
    var username: String
    var password: String
}

private struct LatticeTOTPRequest: Encodable {
    var challengeID: String
    var code: String
    var recoveryCode: String

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case code
        case recoveryCode = "recovery_code"
    }
}

public struct LatticeLoginResponse: Codable, Equatable, Hashable, Sendable {
    public var csrfToken: String?
    public var actorID: String?
    public var totpRequired: Bool
    public var challengeID: String?

    enum CodingKeys: String, CodingKey {
        case csrfToken = "csrf_token"
        case actorID = "actor_id"
        case totpRequired = "totp_required"
        case challengeID = "challenge_id"
    }

    public init(csrfToken: String? = nil, actorID: String? = nil, totpRequired: Bool = false, challengeID: String? = nil) {
        self.csrfToken = csrfToken
        self.actorID = actorID
        self.totpRequired = totpRequired
        self.challengeID = challengeID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        csrfToken = try container.decodeIfPresent(String.self, forKey: .csrfToken)
        actorID = try container.decodeIfPresent(String.self, forKey: .actorID)
        totpRequired = try container.decodeIfPresent(Bool.self, forKey: .totpRequired) ?? false
        challengeID = try container.decodeIfPresent(String.self, forKey: .challengeID)
    }
}

public struct LatticeLoginSession: Codable, Equatable, Hashable, Sendable {
    public var sessionCookie: String
    public var csrfToken: String
    public var actorID: String?
    /// When the cookie stops working, from its `Expires` or `Max-Age` attribute.
    public var expiresAt: Date?

    public init(sessionCookie: String, csrfToken: String, actorID: String? = nil, expiresAt: Date? = nil) {
        self.sessionCookie = sessionCookie
        self.csrfToken = csrfToken
        self.actorID = actorID
        self.expiresAt = expiresAt
    }

    public var credential: LatticeCredential {
        LatticeCredential(sessionCookie: sessionCookie, csrfToken: csrfToken)
    }
}

// MARK: - Login, TOTP and logout

extension LatticeClient {
    public func login(username: String, password: String) async throws -> LatticeLoginSession {
        let request = try buildLoginRequest(username: username, password: password)
        let (data, response) = try await send(request)
        try validate(response: response, data: data)
        let login = try LatticeDecoder.decodeLogin(from: data)
        if login.totpRequired {
            throw LatticeAPIError.totpRequired(challengeID: login.challengeID ?? "")
        }
        return try session(from: login, response: response)
    }

    public func loginTOTP(challengeID: String, code: String, recoveryCode: String = "") async throws -> LatticeLoginSession {
        let request = try buildTOTPRequest(challengeID: challengeID, code: code, recoveryCode: recoveryCode)
        let (data, response) = try await send(request)
        try validate(response: response, data: data)
        let login = try LatticeDecoder.decodeLogin(from: data)
        return try session(from: login, response: response)
    }

    /// `POST /api/logout`: ends the session this client carries.
    public func logout() async throws {
        try await performVoid(path: "/api/logout")
    }

    public func buildLoginRequest(username: String, password: String) throws -> URLRequest {
        try unauthenticatedJSONRequest(path: "/api/login", body: LatticeLoginRequest(username: username, password: password))
    }

    public func buildTOTPRequest(challengeID: String, code: String, recoveryCode: String = "") throws -> URLRequest {
        try unauthenticatedJSONRequest(
            path: "/api/login/totp",
            body: LatticeTOTPRequest(challengeID: challengeID, code: code, recoveryCode: recoveryCode)
        )
    }

    private func unauthenticatedJSONRequest(path: String, body: some Encodable) throws -> URLRequest {
        guard let url = baseURL.latticeAPIBaseURL.appendingAstraPath(path) else {
            throw LatticeAPIError.invalidURL(baseURL.absoluteString + path)
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func session(from response: LatticeLoginResponse, response urlResponse: URLResponse) throws -> LatticeLoginSession {
        guard let csrf = response.csrfToken?.trimmingCharacters(in: .whitespacesAndNewlines), !csrf.isEmpty else {
            throw LatticeAPIError.invalidResponse
        }
        guard let cookie = LatticeSessionCookie.parse(urlResponse) else {
            throw LatticeAPIError.missingSessionCookie
        }
        return LatticeLoginSession(sessionCookie: cookie.value, csrfToken: csrf, actorID: response.actorID, expiresAt: cookie.expiresAt)
    }
}

/// The `lattice_session` cookie in a login response, with its expiry.
public struct LatticeSessionCookie: Equatable, Sendable {
    public var value: String
    public var expiresAt: Date?

    public static func parse(_ response: URLResponse, now: Date = Date()) -> LatticeSessionCookie? {
        guard let http = response as? HTTPURLResponse else {
            return nil
        }
        for (key, value) in http.allHeaderFields {
            guard String(describing: key).lowercased() == "set-cookie",
                  let cookieHeader = value as? String
            else {
                continue
            }
            if let cookie = parse(header: cookieHeader, now: now) {
                return cookie
            }
        }
        return nil
    }

    /// Parses one `Set-Cookie` header value. `Expires` dates contain a comma,
    /// so cookies are split on the `lattice_session=` name, not on commas.
    public static func parse(header: String, now: Date = Date()) -> LatticeSessionCookie? {
        guard let start = header.range(of: "lattice_session=") else {
            return nil
        }
        let fields = header[start.lowerBound...].components(separatedBy: ";")
        guard let first = fields.first?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        var value = String(first.dropFirst("lattice_session=".count))
        if let comma = value.firstIndex(of: ",") {
            value = String(value[..<comma])
        }
        guard !value.isEmpty else {
            return nil
        }
        var expiresAt: Date?
        for field in fields.dropFirst() {
            let parts = field.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "max-age":
                if let seconds = TimeInterval(parts[1]) { expiresAt = now.addingTimeInterval(seconds) }
            case "expires" where expiresAt == nil:
                expiresAt = httpDate(parts[1])
            default:
                break
            }
        }
        return LatticeSessionCookie(value: value, expiresAt: expiresAt)
    }

    private static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}
