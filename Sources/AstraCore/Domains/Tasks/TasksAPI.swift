import Foundation

struct TaskIDRequest: Encodable {
    var id: String
}

public extension LatticeClient {
    @discardableResult
    func cancelTask(id: String) async throws -> LatticeTask {
        try await perform(
            LatticeTask.self,
            path: "/api/tasks/cancel",
            method: "POST",
            body: TaskIDRequest(id: id)
        )
    }
}
