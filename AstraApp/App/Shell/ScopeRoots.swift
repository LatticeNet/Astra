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
    @State private var windowPulse: HapticPulse?

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
        // A window change is a picker change (section 4.9), like the segments above.
        .onChange(of: appState.monitorWindow) { windowPulse = HapticPulse(event: .selection) }
        .haptics(windowPulse)
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
            case .sent: SentLogScreen(filterPlacement: .topBarLeading)
            }
        }
    }
}

/// One visible scope pattern for all three tabs (section 1): the adaptive
/// segmented control in a top safe-area bar, moved to the principal toolbar
/// slot in a compact vertical size class. The title is inline: over a List,
/// iOS 26 draws a large title under the picker bar's scroll edge effect, so
/// it read blurred on every size, and `.inlineLarge` pushed the screens'
/// leading items into overflow. The tab and the picker already name the screen,
/// so on a narrow screen or at accessibility sizes the visible title steps
/// aside: squeezed between the leading items and Settings it read as a bare
/// ellipsis and pushed Settings into overflow. The navigation title stays for
/// back buttons and VoiceOver. Screens put their own items at leading, so
/// Settings is always the last trailing group (2.1).
private struct ScopedRoot<Value: Hashable, Content: View>: View {
    let title: String
    let pickerTitle: String
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    @ViewBuilder let content: () -> Content

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var width: CGFloat?

    private var hidesVisibleTitle: Bool {
        typeSize.isAccessibilitySize || (width ?? .infinity) < 390
    }

    var body: some View {
        let picker = AdaptiveSegmentedPicker(title: pickerTitle, options: options, selection: $selection, containerWidth: width)
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.inline)
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
            .toolbar(removing: hidesVisibleTitle && verticalSizeClass != .compact ? .title : nil)
            .tabRootToolbar()
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
                    // A plain Label (2.1): the bar draws it as its glyph, which
                    // keeps room for the title and Settings on a small phone.
                    Button {
                        router.openSettings()
                    } label: {
                        Label("Demo", systemImage: "theatermasks")
                    }
                    .accessibilityLabel("Demo mode, data is invented")
                    .accessibilityInputLabels(["Demo"])
                }
                // Settings sits alone in its glass group (2.1).
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
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
