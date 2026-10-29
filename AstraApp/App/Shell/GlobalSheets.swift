import SwiftUI

/// What the Review sheet opens: one approval, or one console event group.
enum ReviewTarget: Hashable, Codable, Sendable {
    case single(String)
    case batch(groupKey: String, ids: [String])
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
        case .review(.batch(let key, _)): "batch:\(key)"
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
        case .review(.batch(let key, let ids)):
            BatchReviewSheet(groupKey: key, approvalIDs: ids)
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

/// The close button and stack every placeholder sheet uses until its module
/// builds the real one.
struct StubSheet: View {
    let title: String
    let screenID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            StubScreen(title: title, screenID: screenID)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                    }
                }
                .actionHost(inSheet: true)
        }
        .presentationDragIndicator(.visible)
    }
}
