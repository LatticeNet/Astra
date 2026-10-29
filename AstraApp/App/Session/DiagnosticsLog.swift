import Foundation

/// One failed request, as Diagnostics shows it: no headers, no bodies.
struct RequestRecord: Identifiable, Sendable, Hashable {
    let id = UUID()
    let method: String
    let path: String
    let status: Int?
    let at: Date
    let message: String
}

/// The last 50 request errors, and in demo mode the request log (F-10).
actor DiagnosticsLog {
    private(set) var errors: [RequestRecord] = []
    private(set) var demoRequests: [RequestRecord] = []
    private let limit = 50

    func recordError(_ record: RequestRecord) {
        errors.insert(record, at: 0)
        if errors.count > limit { errors.removeLast(errors.count - limit) }
    }

    func recordDemoRequest(_ record: RequestRecord) {
        demoRequests.insert(record, at: 0)
        if demoRequests.count > limit { demoRequests.removeLast(demoRequests.count - limit) }
    }

    func snapshot() -> (errors: [RequestRecord], demo: [RequestRecord]) {
        (errors, demoRequests)
    }

    func clear() {
        errors = []
        demoRequests = []
    }
}

/// Wraps a transport to record failures for Diagnostics and to report
/// authentication answers to the session (a 401 means a rejected token or an
/// expired session, section 7.2).
struct DiagnosticsTransport: HTTPTransport {
    let base: any HTTPTransport
    let log: DiagnosticsLog
    let kind: ClientKind
    let isDemo: Bool
    let onStatus: @Sendable (ClientKind, Int, String) -> Void

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        do {
            let (data, response) = try await base.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if isDemo {
                await log.recordDemoRequest(RequestRecord(method: method, path: path, status: status, at: Date(), message: ""))
            }
            if status >= 400 {
                await log.recordError(RequestRecord(method: method, path: path, status: status, at: Date(), message: Self.message(in: data)))
            }
            onStatus(kind, status, path)
            return (data, response)
        } catch {
            await log.recordError(RequestRecord(method: method, path: path, status: nil, at: Date(), message: error.localizedDescription))
            throw error
        }
    }

    /// The error envelope's text, never the body itself.
    private static func message(in data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return (object["error"] as? String) ?? (object["message"] as? String) ?? ""
    }
}
