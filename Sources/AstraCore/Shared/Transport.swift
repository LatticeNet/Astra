import Foundation

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {}

public enum AstraURLNormalizer {
    public static func serviceURL(from rawValue: String, defaultScheme: String = "https") -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.contains("://") {
            return validatedHTTPURL(from: trimmed)
        }
        return validatedHTTPURL(from: "\(defaultScheme)://\(trimmed)")
    }

    public static func latticeDashboardURL(from rawValue: String) -> URL? {
        guard let serviceURL = serviceURL(from: rawValue),
              var components = URLComponents(url: serviceURL, resolvingAgainstBaseURL: false)
        else {
            return nil
        }

        let parts = components.path.pathComponentsForAstraJoin
        if let apiIndex = parts.firstIndex(of: "api") {
            let prefix = Array(parts[..<apiIndex])
            components.path = prefix.isEmpty ? "" : "/" + prefix.joined(separator: "/")
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func validatedHTTPURL(from value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else {
            return nil
        }
        return url
    }
}

public struct LatticeClient: Sendable {
    public var baseURL: URL
    public var credential: LatticeCredential
    public var timeout: TimeInterval
    let transport: any HTTPTransport

    public init(
        baseURL: URL,
        credential: LatticeCredential = LatticeCredential(),
        timeout: TimeInterval = 15,
        transport: any HTTPTransport = URLSession.shared
    ) {
        self.baseURL = baseURL
        self.credential = credential
        self.timeout = timeout
        self.transport = transport
    }

    public func buildRequest(path: String, method: String = "GET") throws -> URLRequest {
        guard let url = baseURL.latticeAPIBaseURL.appendingAstraPath(path) else {
            throw LatticeAPIError.invalidURL(baseURL.absoluteString + path)
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuthentication(to: &request)
        return request
    }

    func applyAuthentication(to request: inout URLRequest) {
        let bearer = credential.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            return
        }

        let session = credential.sessionCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if !session.isEmpty {
            request.setValue("lattice_session=\(session)", forHTTPHeaderField: "Cookie")
        }
        let csrf = credential.csrfToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !csrf.isEmpty {
            request.setValue(csrf, forHTTPHeaderField: "X-Lattice-CSRF")
        }
    }

    /// Sends a request, mapping transport failures to `LatticeAPIError.transport`.
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await transport.data(for: request)
        } catch let error as URLError {
            throw LatticeAPIError.transport(error.code)
        }
    }

    /// Throws the mapped envelope error for any non-2xx status (section 8.3).
    func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else {
            return
        }
        throw LatticeErrorEnvelope.error(status: http.statusCode, body: data)
    }
}

// MARK: - Generic request plumbing

extension LatticeClient {
    /// Shared encoder. Dates are emitted as RFC3339, matching Go's `time.Time`
    /// JSON marshalling on the server.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Build a request that carries a JSON body and optional query items, reusing
    /// the authenticated `buildRequest` so the bearer token / session cookie +
    /// `X-Lattice-CSRF` header are always applied.
    func buildJSONRequest(
        path: String,
        method: String,
        bodyData: Data?,
        query: [URLQueryItem]
    ) throws -> URLRequest {
        var request = try buildRequest(path: path, method: method)
        if !query.isEmpty,
           let url = request.url,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            request.url = components.url
        }
        if let bodyData {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }
        return request
    }

    /// Execute and validate, returning the raw response body.
    func performData(
        path: String,
        method: String = "GET",
        body: (any Encodable)? = nil,
        query: [URLQueryItem] = []
    ) async throws -> Data {
        let bodyData: Data?
        if let body {
            bodyData = try Self.makeEncoder().encode(AnyEncodable(body))
        } else {
            bodyData = nil
        }
        let request = try buildJSONRequest(path: path, method: method, bodyData: bodyData, query: query)
        let (data, response) = try await send(request)
        try validate(response: response, data: data)
        return data
    }

    /// Execute, validate, and decode a `Decodable` response.
    func perform<T: Decodable>(
        _ type: T.Type = T.self,
        path: String,
        method: String = "GET",
        body: (any Encodable)? = nil,
        query: [URLQueryItem] = []
    ) async throws -> T {
        let data = try await performData(path: path, method: method, body: body, query: query)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LatticeAPIError.invalidResponse
        }
    }

    /// Execute and discard the body (used for `{"ok": true}` style responses).
    @discardableResult
    func performVoid(
        path: String,
        method: String = "POST",
        body: (any Encodable)? = nil,
        query: [URLQueryItem] = []
    ) async throws -> Data {
        try await performData(path: path, method: method, body: body, query: query)
    }
}

/// Type-erasing box so heterogeneous `Encodable` request payloads can be encoded
/// through a single code path.
struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void
    init(_ wrapped: any Encodable) {
        encodeClosure = wrapped.encode
    }
    func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}

// MARK: - Error envelope

/// The server's error body. Most handlers write `{"error": {code, message,
/// request_id, field}}`; plan handlers that refuse on lint findings write
/// `{"error": "<message>", "findings": [{code, severity, message}]}`.
struct LatticeErrorEnvelope: Decodable {
    var error: LatticeAPIErrorBody
    var findings: [String]

    enum CodingKeys: String, CodingKey { case error, findings }

    private struct Finding: Decodable {
        var code: String?
        var message: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let body = try? container.decode(LatticeAPIErrorBody.self, forKey: .error) {
            error = body
        } else {
            let message = try container.decode(String.self, forKey: .error)
            error = LatticeAPIErrorBody(code: "", message: message, requestID: nil, scope: nil)
        }
        if let objects = try? container.decodeIfPresent([Finding].self, forKey: .findings) {
            findings = objects.map { $0.message ?? $0.code ?? "" }.filter { !$0.isEmpty }
        } else {
            findings = (try? container.decodeIfPresent([String].self, forKey: .findings)) ?? []
        }
    }

    /// The error for a non-2xx response, from the envelope when the body is one.
    static func error(status: Int, body: Data) -> LatticeAPIError {
        if let envelope = try? JSONDecoder().decode(LatticeErrorEnvelope.self, from: body) {
            return envelope.error.asAPIError(statusCode: status, findings: envelope.findings)
        }
        return LatticeAPIErrorBody(code: "", message: "", requestID: nil, scope: nil)
            .asAPIError(statusCode: status, findings: [])
    }
}

struct LatticeAPIErrorBody: Decodable {
    var code: String
    var message: String
    var requestID: String?
    var scope: String?

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case requestID = "request_id"
        case scope
    }

    init(code: String, message: String, requestID: String?, scope: String?) {
        self.code = code
        self.message = message
        self.requestID = requestID
        self.scope = scope
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(String.self, forKey: .code) ?? ""
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
    }

    /// Maps the envelope to a `LatticeAPIError`. A nil status is an envelope
    /// found in a 2xx body, which older handlers sometimes sent.
    func asAPIError(statusCode: Int? = nil, findings: [String] = []) -> LatticeAPIError {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let codeOrNil = normalizedCode.isEmpty ? nil : normalizedCode
        if normalizedCode == "unauthorized" && statusCode == nil {
            return .unauthorized(message: messageForDisplay)
        }
        switch statusCode {
        case 401:
            return .unauthorized(message: messageForDisplay)
        case 403:
            return .forbidden(code: codeOrNil ?? "forbidden", scope: scope)
        case 404:
            return .notFound
        case 409:
            return .conflict(code: codeOrNil ?? "conflict", findings: findings)
        default:
            return .server(status: statusCode ?? 0, code: codeOrNil, message: messageForDisplay)
        }
    }

    private var messageForDisplay: String {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requestID = requestID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requestID.isEmpty
        else {
            return trimmedMessage
        }
        if trimmedMessage.isEmpty {
            return "request_id: \(requestID)"
        }
        if trimmedMessage.contains(requestID) {
            return trimmedMessage
        }
        return "\(trimmedMessage) (request_id: \(requestID))"
    }
}

// MARK: - Path joining

extension URL {
    var latticeAPIBaseURL: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.query = nil
        components.fragment = nil
        return components.url ?? self
    }

    func appendingAstraPath(_ path: String) -> URL? {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        let existingParts = components?.path.pathComponentsForAstraJoin ?? []
        let newParts = path.pathComponentsForAstraJoin
        let mergedParts = existingParts.mergingAstraPathOverlap(with: newParts)
        components?.path = mergedParts.isEmpty ? "" : "/" + mergedParts.joined(separator: "/")
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }
}

extension String {
    var pathComponentsForAstraJoin: [String] {
        split(separator: "/").map(String.init)
    }
}

extension Array where Element == String {
    func mergingAstraPathOverlap(with appendedParts: [String]) -> [String] {
        guard !isEmpty else {
            return appendedParts
        }
        guard !appendedParts.isEmpty else {
            return self
        }

        let maximumOverlap = Swift.min(count, appendedParts.count)
        for overlap in stride(from: maximumOverlap, through: 1, by: -1) {
            if suffix(overlap) == appendedParts.prefix(overlap) {
                return self + appendedParts.dropFirst(overlap)
            }
        }
        return self + appendedParts
    }
}
