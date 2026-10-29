import SwiftUI

// The three scoped tab roots (F-19 to F-21) and the toolbar every tab root
// carries. Each segment maps to a module's scope root, frozen as `init()`.

struct FleetRoot: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        ScopedRoot(
            title: "Fleet",
            pickerTitle: "Fleet scope",
            options: FleetScope.allCases.map { ($0, $0.title) },
            selection: $appState.fleetScope
        ) {
            switch appState.fleetScope {
            case .nodes: NodesScreen()
            case .groups: GroupsScreen()
            case .map: MapScreen()
            case .machines: InventoryScreen()
            }
        }
    }
}

struct MonitorRoot: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        ScopedRoot(
            title: "Monitor",
            pickerTitle: "Monitor segment",
            options: MonitorSegment.allCases.map { ($0, $0.title) },
            selection: $appState.monitorSegment
        ) {
            switch appState.monitorSegment {
            case .overview: MonitorOverviewScreen()
            case .paths: PathsScreen()
            case .checks: ChecksScreen()
            case .incidents: IncidentsScreen()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Window", selection: $appState.monitorWindow) {
                        ForEach(MonitorWindow.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "clock")
                        Text(appState.monitorWindow.rawValue)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Window, \(appState.monitorWindow.rawValue)")
                }
            }
        }
    }
}

struct ActivityRoot: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        ScopedRoot(
            title: "Activity",
            pickerTitle: "Activity scope",
            options: ActivityScope.allCases.map { ($0, $0.title) },
            selection: $appState.activityScope
        ) {
            switch appState.activityScope {
            case .tasks: TasksScreen()
            case .audit: AuditScreen()
            case .approvals: ApprovalsScreen()
            case .sent: SentLogScreen()
            }
        }
    }
}

/// One visible scope pattern for all three tabs (section 1): the adaptive
/// segmented control in a top safe-area bar, moved to the principal toolbar
/// slot in a compact vertical size class.
private struct ScopedRoot<Value: Hashable, Content: View>: View {
    let title: String
    let pickerTitle: String
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    @ViewBuilder let content: () -> Content

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var width: CGFloat?
    @State private var screenHeight: CGFloat?

    var body: some View {
        let picker = AdaptiveSegmentedPicker(title: pickerTitle, options: options, selection: $selection, containerWidth: width)
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            // Height including the bars, so it does not change with the title mode.
            .onGeometryChange(for: CGFloat.self) { $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom } action: { screenHeight = $0 }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(usesInlineTitle ? .inline : .automatic)
            .safeAreaBar(edge: .top) {
                if verticalSizeClass != .compact {
                    picker
                        .padding(.horizontal, Spacing.l)
                        .padding(.bottom, Spacing.s)
                }
            }
            .toolbar {
                if verticalSizeClass == .compact {
                    ToolbarItem(placement: .principal) { picker.frame(maxWidth: 420) }
                }
            }
            .tabRootToolbar()
    }

    /// On a short screen at accessibility sizes the large title and the
    /// picker bar do not both fit under the toolbar, and the title renders
    /// blurred under the bar's edge effect (iPhone SE at AX5). The tab and
    /// the picker already name the screen, so the title goes inline there.
    private var usesInlineTitle: Bool {
        guard typeSize.isAccessibilitySize, let screenHeight else { return false }
        return screenHeight < 700
    }
}

extension FleetScope {
    var title: String {
        switch self {
        case .nodes: "Nodes"
        case .groups: "Groups"
        case .map: "Map"
        case .machines: "Machines"
        }
    }
}

extension MonitorSegment {
    var title: String {
        switch self {
        case .overview: "Overview"
        case .paths: "Paths"
        case .checks: "Checks"
        case .incidents: "Incidents"
        }
    }
}

extension ActivityScope {
    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .audit: "Audit"
        case .approvals: "Approvals"
        case .sent: "Sent"
        }
    }
}

extension View {
    /// The trailing group on every tab root (section 2.1): the Settings button
    /// and, in demo mode, the Demo button before it.
    func tabRootToolbar() -> some View {
        modifier(TabRootToolbar())
    }
}

private struct TabRootToolbar: ViewModifier {
    @Environment(Router.self) private var router
    @Environment(SessionStore.self) private var session

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            if session.isDemo {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        router.openSettings()
                    } label: {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "theatermasks")
                            Text("Demo")
                        }
                    }
                    .accessibilityLabel("Demo mode, data is invented")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.openSettings()
                } label: {
                    Label("Settings", systemImage: "person.crop.circle")
                }
            }
        }
    }
}
