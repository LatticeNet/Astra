import Foundation
import AstraCore

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw CheckFailure.failed(message)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw CheckFailure.failed("\(message): expected \(expected), got \(actual)")
    }
}

func expectUnwrapped<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw CheckFailure.failed(message)
    }
    return value
}

func bodyObject(_ data: Data?) throws -> [String: Any] {
    let body = try expectUnwrapped(data, "request body present")
    return try expectUnwrapped(JSONSerialization.jsonObject(with: body) as? [String: Any], "request body JSON object")
}

/// Loads a JSON fixture from `Checks/AstraCoreCheck/Fixtures/`, resolved
/// relative to this file because `Package.swift` declares no resources.
func fixture(_ name: String, filePath: String = #filePath) throws -> Data {
    let directory = URL(fileURLWithPath: filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    let url = directory.appendingPathComponent(name)
    do {
        return try Data(contentsOf: url)
    } catch {
        throw CheckFailure.failed("missing fixture \(name) at \(url.path)")
    }
}

/// Answers registered URLs and records every request it sees.
actor MockTransport: HTTPTransport {
    private var responses: [String: [(Int, Data)]]
    private var headers: [String: [String: String]]
    private(set) var requestURLs: [String] = []
    private(set) var authorizationHeaders: [String?] = []
    private(set) var cookieHeaders: [String?] = []
    private(set) var csrfHeaders: [String?] = []
    private(set) var methods: [String?] = []
    private(set) var bodies: [Data?] = []
    private(set) var lastBody: Data?

    init(responses: [String: (Int, Data)], headers: [String: [String: String]] = [:]) {
        self.responses = responses.mapValues { [$0] }
        self.headers = headers
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try expectUnwrapped(request.url, "request URL")
        requestURLs.append(url.absoluteString)
        authorizationHeaders.append(request.value(forHTTPHeaderField: "Authorization"))
        cookieHeaders.append(request.value(forHTTPHeaderField: "Cookie"))
        csrfHeaders.append(request.value(forHTTPHeaderField: "X-Lattice-CSRF"))
        methods.append(request.httpMethod)
        bodies.append(request.httpBody)
        lastBody = request.httpBody

        let key = url.absoluteString
        if var available = responses[key], !available.isEmpty {
            let response = available.removeFirst()
            responses[key] = available
            return httpResponse(url: url, payload: response)
        }
        if let match = responses.first(where: { !$0.value.isEmpty && Self.queryCompatible($0.key, key) }) {
            var available = match.value
            let response = available.removeFirst()
            responses[match.key] = available
            return httpResponse(url: url, payload: response)
        }
        throw CheckFailure.failed("missing mock response for \(key); have \(responses.filter { !$0.value.isEmpty }.keys.sorted()); seen \(requestURLs)")
    }

    private func httpResponse(url: URL, payload: (Int, Data)) -> (Data, URLResponse) {
        let http = HTTPURLResponse(
            url: url,
            statusCode: payload.0,
            httpVersion: "HTTP/1.1",
            headerFields: headers[url.absoluteString]
        )!
        return (payload.1, http)
    }

    private static func queryCompatible(_ registered: String, _ actual: String) -> Bool {
        guard let registeredURL = URL(string: registered), let actualURL = URL(string: actual) else {
            return false
        }
        guard registeredURL.scheme == actualURL.scheme,
              registeredURL.host == actualURL.host,
              registeredURL.path == actualURL.path else {
            return false
        }
        let registeredItems = URLComponents(url: registeredURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let actualItems = URLComponents(url: actualURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Set(registeredItems.map { "\($0.name)=\($0.value ?? "")" }) == Set(actualItems.map { "\($0.name)=\($0.value ?? "")" })
    }
}

func json(_ text: String) -> Data {
    Data(text.utf8)
}

/// Runs one response through a real `LatticeClient` and returns the error it maps to.
enum LatticeErrorProbe {
    static func map(status: Int, body: Data) async -> LatticeAPIError? {
        let transport = MockTransport(responses: ["https://lattice.example.com/api/health": (status, body)])
        let client = LatticeClient(baseURL: URL(string: "https://lattice.example.com")!, transport: transport)
        do {
            _ = try await client.fetchHealth()
            return nil
        } catch let error as LatticeAPIError {
            return error
        } catch {
            return nil
        }
    }
}
