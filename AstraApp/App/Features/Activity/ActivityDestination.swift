import SwiftUI

/// Maps each ActivityRoute case to its screen.
struct ActivityDestination: View {
    let route: ActivityRoute

    var body: some View {
        switch route {
        case .task(let id): TaskRunScreen(id: id)
        case .taskNode(let taskID, let nodeID): TaskNodeOutputScreen(taskID: taskID, nodeID: nodeID)
        case .auditEvent(let id): AuditEventScreen(id: id)
        case .trace(let id): CorrelationTraceScreen(correlationID: id)
        }
    }
}
