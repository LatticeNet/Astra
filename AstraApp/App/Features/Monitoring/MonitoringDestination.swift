import SwiftUI

/// Maps each MonitoringRoute case to its screen.
struct MonitoringDestination: View {
    let route: MonitoringRoute

    var body: some View {
        switch route {
        case .path(let key): PathDetailScreen(key: key)
        case .matrix: PathMatrixScreen()
        case .chain(let id): ChainDetailScreen(id: id)
        case .check(let id): CheckDetailScreen(id: id)
        case .checkResults(let id): CheckResultsScreen(checkID: id)
        case .definition(let id): DefinitionDetailScreen(id: id)
        case .incident(let id): IncidentDetailScreen(id: id)
        case .maintenanceWindow(let id): MaintenanceWindowScreen(id: id)
        }
    }
}
