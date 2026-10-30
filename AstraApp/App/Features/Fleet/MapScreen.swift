import MapKit
import SwiftUI

/// M2-12 Map. A scope root, frozen as `init()`. One annotation per
/// half-degree cluster with the worst member's glyph and a count, latency
/// arcs whose state is carried by dash pattern as well as color, and a List
/// view (nodes by region and the problem paths) that VoiceOver users get too.
struct MapScreen: View {
    static let modeKey = "fleet.map.mode"
    static let latencyKey = "fleet.map.latency"
    static let allPathsKey = "fleet.map.allPaths"

    @Environment(FleetStore.self) private var store
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(AppState.self) private var appState
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @SceneStorage(MapScreen.modeKey) private var mode = "map"
    @SceneStorage(MapScreen.latencyKey) private var latency = false
    @SceneStorage(MapScreen.allPathsKey) private var allPaths = false
    @State private var selected: FleetMapCluster?
    @State private var position: MapCameraPosition = .automatic
    @State private var framed = false
    /// Degrees one pin covers at the current zoom; nil until the camera settles.
    @State private var pinGap: (latitude: Double, longitude: Double)?
    @State private var mapSize: CGSize = .zero
    @State private var visible: MKCoordinateRegion?
    @ScaledMetric(relativeTo: .subheadline) private var pinWidth: CGFloat = 60
    @ScaledMetric(relativeTo: .subheadline) private var pinHeight: CGFloat = 44

    var body: some View {
        FleetListState(state: store.geo, noun: "the map", retry: { Task { await refresh() } }) { nodes in
            if mode == "list" {
                list(nodes)
            } else {
                map(nodes)
            }
        }
        .polling(.paths, version: changes.version([.nodes, .paths])) { await refresh() }
        .onChange(of: latency) { Task { await refresh() } }
        .toolbar { toolbar }
        .onAppear { consumeQuery() }
        .onChange(of: appState.pendingQuery[FleetScope.map.rawValue]) { consumeQuery() }
    }

    /// `lattice://fleet?scope=map&q=layer:latency` turns the arcs on, as the
    /// console's `layer=latency` does; `list` and `all` pick the view and paths.
    private func consumeQuery() {
        guard let query = appState.consumeQuery(FleetScope.map.rawValue)?.lowercased() else { return }
        let words = Set(query.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init))
        if words.contains("layer:latency") || words.contains("latency") { latency = true }
        if words.contains("list") { mode = "list" }
        if words.contains("map") { mode = "map" }
        if words.contains("all") { allPaths = true }
    }

    private func refresh() async -> Bool {
        async let nodes: Bool = store.nodes.value == nil ? store.refresh() : true
        let map = await store.refreshMap(window: .oneHour, withPaths: latency)
        _ = await nodes
        return map
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if verticalSizeClass == .compact {
            // Landscape already carries the scope picker; a second segmented
            // control there gets squeezed to clipped letters, so one button switches.
            ToolbarItem(placement: .topBarLeading) {
                Button(mode == "list" ? "Show map" : "Show list", systemImage: mode == "list" ? "map" : "list.bullet") {
                    mode = mode == "list" ? "map" : "list"
                }
            }
        } else {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    Text("Map").tag("map")
                    Text("List").tag("list")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            let unlocated = MapClusters.unlocated(store.geo.value ?? []).count
            Menu {
                Toggle("Latency", systemImage: "point.topleft.down.to.point.bottomright.curvepath", isOn: $latency)
                if latency {
                    Picker("Paths", selection: $allPaths) {
                        Text("Problem paths").tag(false)
                        Text("All paths").tag(true)
                    }
                    .pickerStyle(.inline)
                }
                Divider()
                Button("No location (\(unlocated))", systemImage: "location.slash") { router.push(.fleet(.unlocated)) }
                Button("Open on web", systemImage: "safari") { router.openOnWeb(.map) }
            } label: {
                Label("Map options", systemImage: latency ? "point.topleft.down.to.point.bottomright.curvepath.fill" : "point.topleft.down.to.point.bottomright.curvepath")
            }
            .accessibilityValue(latency ? "Latency on" : "Latency off")
        }
    }

    // MARK: Map

    private func map(_ nodes: [NodeGeoView]) -> some View {
        let located = MapClusters.clusters(nodes)
        // Pins that would overlap at this zoom merge, worst member anchoring,
        // so a healthy pin never covers an offline one.
        let clusters = pinGap.map { MapClusters.merged(located, latitudeGap: $0.latitude, longitudeGap: $0.longitude) } ?? located
        let arcs = latency ? (store.paths.value.map { MapClusters.arcs($0, nodes: nodes, all: allPaths) } ?? []) : []
        return Group {
            Map(position: $position) {
                ForEach(arcs) { arc in
                    MapPolyline(coordinates: [
                        CLLocationCoordinate2D(latitude: arc.fromLatitude, longitude: arc.fromLongitude),
                        CLLocationCoordinate2D(latitude: arc.toLatitude, longitude: arc.toLongitude),
                    ], contourStyle: .geodesic)
                    .stroke(Self.arcColor(arc.state), style: Self.arcStroke(arc.state))
                }
                ForEach(clusters) { cluster in
                    Annotation(cluster.place, coordinate: CLLocationCoordinate2D(latitude: cluster.latitude, longitude: cluster.longitude), anchor: .center) {
                        FleetClusterPin(cluster: cluster, selected: selected?.id == cluster.id) {
                            selected = selected?.id == cluster.id ? nil : cluster
                        }
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { mapSize = $0 }
            .onMapCameraChange(frequency: .onEnd) { context in
                guard mapSize.width > 0, mapSize.height > 0 else { return }
                visible = context.region
                let span = context.region.span
                pinGap = (span.latitudeDelta / mapSize.height * pinHeight, span.longitudeDelta / mapSize.width * pinWidth)
            }
            .task(id: located.count) {
                // Open once over the problem places; after that the operator's pan and zoom stay.
                guard !framed, let open = FleetMapFrame.opening(located) else { return }
                framed = true
                position = .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: open.centerLatitude, longitude: open.centerLongitude),
                    span: MKCoordinateSpan(latitudeDelta: open.latitudeDelta, longitudeDelta: open.longitudeDelta)
                ))
            }
            .mapControls { MapCompass() }
            .overlay {
                if located.isEmpty { emptyMap(nodes) }
            }
            .overlay(alignment: .bottom) {
                if let selected {
                    callout(selected)
                } else {
                    // Bottom, above the tab bar: the top of the map is where the scope picker and most pins sit.
                    VStack(spacing: Spacing.s) {
                        if let visible {
                            FleetOffscreenNotice(clusters: FleetMapFrame.hiddenProblems(located) { isShown($0, in: visible) }) { cluster in
                                position = .region(MKCoordinateRegion(
                                    center: CLLocationCoordinate2D(latitude: cluster.latitude, longitude: cluster.longitude),
                                    span: visible.span
                                ))
                            }
                        }
                        if latency, !located.isEmpty {
                            FleetArcLegend(denied: deniedPaths, failure: pathsFailure) { Task { await refresh() } }
                        }
                    }
                    .padding(.horizontal, Spacing.l)
                    .padding(.bottom, Spacing.s)
                }
            }
            .accessibilityHint(voiceOver ? "The List view reads every node and path." : "")
        }
    }

    /// Whether a cluster's pin is in the clear middle of the map: the top sits
    /// under the bars and the scope picker, the bottom under this notice and the tab bar.
    private func isShown(_ cluster: FleetMapCluster, in region: MKCoordinateRegion) -> Bool {
        let view = FleetMapRegion.Result(centerLatitude: region.center.latitude, centerLongitude: region.center.longitude,
                                         latitudeDelta: region.span.latitudeDelta, longitudeDelta: region.span.longitudeDelta)
        let point = FleetMapFrame.screenFraction(latitude: cluster.latitude, longitude: cluster.longitude, region: view)
        return (0.03...0.97).contains(point.x) && (0.2...0.75).contains(point.y)
    }

    /// No pins to draw: say whether the fleet is empty or only unlocated.
    private func emptyMap(_ nodes: [NodeGeoView]) -> some View {
        Group {
            if nodes.isEmpty {
                ContentUnavailableView("No nodes enrolled", systemImage: "map",
                                       description: Text("Nodes appear here once they are enrolled and report a location."))
            } else {
                ContentUnavailableView {
                    Label("No node has a location", systemImage: "location.slash")
                } description: {
                    Text(nodes.count == 1 ? "The one node has no location yet." : "None of the \(nodes.count) nodes has a location yet.")
                } actions: {
                    Button("No location (\(nodes.count))") { router.push(.fleet(.unlocated)) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(Spacing.l)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    /// The paths read failed with nothing earlier to draw: arcs cannot be trusted as "no problems".
    private var pathsFailure: String? {
        guard FleetLoad.failedEmpty(store.paths) else { return nil }
        if case .failed(let error, _, _) = store.paths { return error.localizedDescription }
        return "The server answered in a shape this app cannot read."
    }

    private var deniedPaths: String? {
        if case .denied(let scope) = store.paths { return scope }
        return nil
    }

    static func arcColor(_ state: PathDisplayState) -> Color {
        switch state {
        case .down: .statusFailFill
        case .degraded: .statusWarnFill
        case .up: .statusOKFill
        case .unknown, .paused: .statusQuiet
        }
    }

    static func arcStroke(_ state: PathDisplayState) -> StrokeStyle {
        switch state {
        case .down: StrokeStyle(lineWidth: 3, lineCap: .round, dash: ChartStyle.arcDownDash)
        case .degraded: StrokeStyle(lineWidth: 3, lineCap: .round, dash: ChartStyle.arcDegradedDash)
        default: StrokeStyle(lineWidth: 2, lineCap: .round)
        }
    }

    private func callout(_ cluster: FleetMapCluster) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(cluster.label).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.s)
                Button(role: .close) { selected = nil }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: Spacing.minimumTarget, minHeight: Spacing.minimumTarget)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(cluster.members) { member in
                        Button {
                            selected = nil
                            router.push(.fleet(.node(id: member.id)))
                        } label: {
                            HStack {
                                StatusRow(style: StatusStyle.node(NodeHonesty(serverValue: member.status)), title: member.displayName,
                                          detail: member.publicIP.isEmpty ? nil : member.publicIP)
                                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                        }
                        .tint(.primary)
                        if member.id != cluster.members.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(Spacing.l)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(uiColor: .separator), lineWidth: 1))
        .padding(.horizontal, Spacing.l)
        .padding(.bottom, Spacing.s)
    }

    // MARK: List

    private func list(_ geo: [NodeGeoView]) -> some View {
        let records = store.nodes.value ?? []
        let sections = FleetNodeGrouping.sections(records, by: .region)
        let problems = store.paths.value.map(MapClusters.problemPaths) ?? []
        return List {
            if latency {
                Section {
                    switch store.paths {
                    case .denied(let scope):
                        ScopeDeniedRow(scope: scope)
                    default:
                        FleetSectionError(state: store.paths, noun: "paths") { Task { await refresh() } }
                        if FleetLoad.isWaiting(store.paths) {
                            LoadingRows(label: "Loading paths", count: 2)
                        } else if store.paths.value != nil, problems.isEmpty {
                            Text("No degraded or down paths").foregroundStyle(.secondary).frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                        }
                        ForEach(problems) { path in
                            NavigationLink(value: AppRoute.monitoring(.path(key: path.key))) {
                                PathRow(path: path, sourceName: store.record(id: path.source)?.node.displayName,
                                        targetName: path.targetNode.isEmpty ? nil : store.record(id: path.targetNode)?.node.displayName,
                                        judgesDegraded: store.paths.value?.judgesDegraded ?? true)
                            }
                        }
                    }
                } header: {
                    Text("Problem paths")
                }
            }
            ForEach(sections) { section in
                Section("\(section.title) (\(section.records.count))") {
                    ForEach(section.records) { record in
                        NavigationLink(value: AppRoute.fleet(.node(id: record.id))) { NodeRow(node: record.node) }
                            .fleetNodeMenu(record)
                    }
                }
            }
            Section {
            } footer: {
                FleetFooter(state: store.geo)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { _ = await refresh() }
    }
}

/// A cluster on the map: the worst member's glyph and the member count, at
/// least 44 pt, labelled "Tokyo, 4 nodes, 1 offline".
struct FleetClusterPin: View {
    let cluster: FleetMapCluster
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let style = StatusStyle.node(cluster.worst)
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: style.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(style.tone.glyph)
                    .font(.body.weight(.semibold))
                if cluster.members.count > 1 {
                    Text("\(cluster.members.count)").font(.subheadline.monospacedDigit().weight(.semibold))
                }
            }
            .padding(.horizontal, Spacing.s)
            .frame(minWidth: Spacing.minimumTarget, minHeight: Spacing.minimumTarget)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
            .overlay(Capsule().stroke(selected ? Color.accentText : Color(uiColor: .separator), lineWidth: selected ? 2 : 1))
        }
        .tint(.primary)
        .fleetMapChrome()
        .accessibilityLabel(cluster.label)
        .accessibilityHint("Shows the nodes here")
    }
}

/// Problem places the map is not showing, worst first, so panning never
/// hides an offline node: "Frankfurt offline off screen". Tapping moves there.
struct FleetOffscreenNotice: View {
    let clusters: [FleetMapCluster]
    let show: (FleetMapCluster) -> Void

    var body: some View {
        if let worst = clusters.first {
            let style = StatusStyle.node(worst.worst)
            Button { show(worst) } label: {
                HStack(spacing: Spacing.s) {
                    Label {
                        Text(sentence)
                            .foregroundStyle(style.tone.word)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: style.symbol).symbolRenderingMode(.hierarchical).foregroundStyle(style.tone.glyph)
                    }
                    Spacer(minLength: 0)
                    Text("Show").fontWeight(.semibold).foregroundStyle(Color.accentText)
                }
                .font(.footnote)
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s)
                .frame(minHeight: Spacing.minimumTarget)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(uiColor: .separator), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .fleetMapChrome()
            .accessibilityHint("Moves the map to \(worst.place)")
        }
    }

    private var sentence: String {
        let first = clusters[0]
        let word = first.worst == .neverReported ? "never reported" : first.worst.rawValue
        let others = clusters.count - 1
        let rest = others == 0 ? "" : (others == 1 ? " and 1 more problem place" : " and \(others) more problem places")
        return "\(first.place) \(word)\(rest) off screen"
    }
}

/// The arc legend: solid up, dashed degraded, dotted down. When the paths
/// read failed it says so instead, so an empty map never reads as healthy.
/// Map chrome: capped below the accessibility sizes, with the large content
/// viewer, so it never grows over the pins it explains.
struct FleetArcLegend: View {
    let denied: String?
    var failure: String?
    var retry: () -> Void = {}

    var body: some View {
        Group {
            if let denied {
                Label("Paths need \(denied)", systemImage: "lock").font(.footnote).foregroundStyle(.secondary)
            } else if let failure {
                HStack(spacing: Spacing.s) {
                    Label {
                        Text("Paths could not load: \(failure)").foregroundStyle(Color.statusFailText)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusFailFill)
                    }
                    .font(.footnote)
                    Button("Retry", action: retry)
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: Spacing.minimumTarget)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.m) { items }
                    VStack(alignment: .leading, spacing: Spacing.xs) { items }
                }
            }
        }
        .fleetMapChrome()
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(uiColor: .separator), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(denied.map { "Paths need \($0)" } ?? failure.map { "Paths could not load: \($0)" } ?? "Legend: solid line up, dashed degraded, dotted down")
        .accessibilityActions {
            if failure != nil { Button("Retry", action: retry) }
        }
    }

    @ViewBuilder private var items: some View {
        item("up", .up)
        item("degraded", .degraded(nil))
        item("down", .down)
    }

    private func item(_ word: String, _ state: PathDisplayState) -> some View {
        HStack(spacing: Spacing.xs) {
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(path, with: .color(MapScreen.arcColor(state)), style: MapScreen.arcStroke(state))
            }
            .frame(width: 24, height: 8)
            Text(word).font(.footnote).fixedSize()
        }
    }
}

private struct FleetMapChrome: ViewModifier {
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Pins, the legend and notices are map chrome: they stop growing short of
    /// the accessibility sizes (lower still in landscape, where the map is
    /// short) and show the large content viewer instead, so they never cover
    /// the map they explain. The List view carries the same facts at any size.
    func body(content: Content) -> some View {
        content
            .dynamicTypeSize(...(verticalSizeClass == .compact ? DynamicTypeSize.large : .xxxLarge))
            .accessibilityShowsLargeContentViewer()
    }
}

private extension View {
    func fleetMapChrome() -> some View { modifier(FleetMapChrome()) }
}
