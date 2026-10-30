import SwiftUI

/// What the Review sheet opens: one approval, or one console event group.
/// A batch a filing opened also carries the nodes the server refused, so
/// BatchReview can list them beside what was filed.
enum ReviewTarget: Hashable, Codable, Sendable {
    case single(String)
    case batch(groupKey: String, ids: [String], refused: [ObjectFailure] = [])
}

/// The sheets other modules may open, through `Router.present` (section 2.4).
/// Every other sheet is presented by its own module.
enum GlobalSheet: Identifiable, Hashable {
    case review(ReviewTarget)
    case maintenanceStart(nodeID: String?)
    case renew(machineID: String)
    /// A module sheet opened by name from `-AstraPresent` in demo mode.
    case demoModule(name: String, argument: String?)

    var id: String {
        switch self {
        case .review(.single(let id)): "review:\(id)"
        case .review(.batch(let key, _, _)): "batch:\(key)"
        case .maintenanceStart(let nodeID): "maintenanceStart:\(nodeID ?? "")"
        case .renew(let machineID): "renew:\(machineID)"
        case .demoModule(let name, let argument): "\(name):\(argument ?? "")"
        }
    }
}

/// Maps each global sheet to the owning module's view.
struct GlobalSheetView: View {
    let sheet: GlobalSheet

    var body: some View {
        switch sheet {
        case .review(.single(let id)):
            ApprovalReviewSheet(approvalID: id)
        case .review(.batch(let key, let ids, let refused)):
            BatchReviewSheet(groupKey: key, approvalIDs: ids, refused: refused)
        case .maintenanceStart(let nodeID):
            MaintenanceStartSheet(nodeID: nodeID)
        case .renew(let machineID):
            RenewSheet(machineID: machineID)
        case .demoModule(let name, let argument):
            if let view = DemoHookRegistry.sheet(named: name, argument: argument) {
                view
            } else {
                NavigationStack {
                    ContentUnavailableView("No sheet named \(name)", systemImage: "questionmark.square.dashed")
                }
            }
        }
    }
}
