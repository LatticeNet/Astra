import SwiftUI

/// M3-03 Matrix. An overview, not a control: cells are not tappable. Sources
/// are rows and targets columns, with the header row and column pinned. At
/// accessibility sizes, while VoiceOver runs, or on request, the grid is
/// replaced by the per-source list.
struct PathMatrixScreen: View {
    static let fitKey = "monitor.matrix.fit"
    static let listKey = "monitor.matrix.list"

    @Environment(MonitoringStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(ChangeLog.self) private var changes
    @Environment(NodeDirectory.self) private var nodes
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(Router.self) private var router

    @SceneStorage(PathMatrixScreen.fitKey) private var fitToWidth = false
    @SceneStorage(PathMatrixScreen.listKey) private var asList = false

    var body: some View {
        MonitoringResource(state: store.paths, noun: "paths", retry: refresh) { _ in
            let items = MonitoringPaths.visible(store.pathItems { nodes.nodes[$0]?.displayName }, showUnmeasured: false)
            let matrix = MonitoringMatrix(items: items)
            if matrix.rows.isEmpty {
                WholeScreenState {
                    ContentUnavailableView("No paths measured", systemImage: "square.grid.3x3", description: Text("The latency plan has no pairs yet."))
                }
            } else if showsList {
                MonitoringMatrixList(matrix: matrix, state: store.paths)
            } else {
                MonitoringMatrixGrid(matrix: matrix, fitToWidth: fitToWidth, state: store.paths)
            }
        }
        .navigationTitle("Matrix")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(appState.monitorWindow.rawValue)
        .toolbar {
            if !showsList, let matrix = currentMatrix, !matrix.rows.isEmpty {
                // Full-size targets for what the headers do: a header at the
                // cell pitch is narrower than 44 pt (4.4).
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Menu("Paths from") {
                            ForEach(matrix.rows) { row in
                                Button(row.name) { router.push(.monitoring(.paths(query: MonitoringMatrix.sourceQuery(row)))) }
                            }
                        }
                        Menu("Paths to") {
                            ForEach(matrix.columns) { column in
                                Button(column.name) { router.push(.monitoring(.paths(query: MonitoringMatrix.targetQuery(column)))) }
                            }
                        }
                    } label: {
                        Label("Open paths", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Fit to width", systemImage: "arrow.left.and.right.square", isOn: $fitToWidth)
                        .disabled(showsList)
                    Toggle("Show as list", systemImage: "list.bullet", isOn: $asList)
                        .disabled(forcedList)
                } label: {
                    Label("Matrix options", systemImage: "ellipsis.circle")
                }
            }
        }
        .polling(.paths, version: changes.version(.paths) &* 8 &+ (MonitorWindow.allCases.firstIndex(of: appState.monitorWindow) ?? 0)) {
            await nodes.refreshIfOlder(than: 60)
            return await store.refreshPaths(window: appState.monitorWindow)
        }
    }

    private var currentMatrix: MonitoringMatrix? {
        guard store.paths.value != nil else { return nil }
        return MonitoringMatrix(items: MonitoringPaths.visible(store.pathItems { nodes.nodes[$0]?.displayName }, showUnmeasured: false))
    }

    private var forcedList: Bool { typeSize.isAccessibilitySize || voiceOver }
    private var showsList: Bool { forcedList || asList }

    private func refresh() {
        Task { await store.refreshPaths(window: appState.monitorWindow) }
    }
}

/// The per-source list: "tokyo-1: 3 down, 2 degraded, 30 up", each row
/// pushing Paths filtered to that source, with a "Problem paths" rotor.
struct MonitoringMatrixList: View {
    let matrix: MonitoringMatrix
    let state: ResourceState<PathsResponse>

    @Namespace private var rotor

    var body: some View {
        List {
            Section {
                ForEach(matrix.rows) { row in
                    NavigationLink(value: AppRoute.monitoring(.paths(query: MonitoringMatrix.sourceQuery(row)))) {
                        StatusRow(style: style(row), title: row.name, accessibilityPhrase: row.summary)
                    }
                    .accessibilityRotorEntry(id: row.id, in: rotor)
                }
            } header: {
                Text("By source").accessibilityAddTraits(.isHeader)
            } footer: {
                MonitoringFreshness(state: state, cadence: .paths)
            }
            Section {
                ForEach(matrix.columns) { column in
                    NavigationLink(value: AppRoute.monitoring(.paths(query: MonitoringMatrix.targetQuery(column)))) {
                        Text(column.name)
                            .textRole(.rowTitle)
                            .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                    }
                }
            } header: {
                Text("By target").accessibilityAddTraits(.isHeader)
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityRotor("Problem paths") {
            ForEach(matrix.rows.filter(\.hasProblems)) { row in
                AccessibilityRotorEntry(Text(row.summary), id: row.id, in: rotor)
            }
        }
    }

    /// The worst state's symbol and tone, with every count as the word.
    private func style(_ row: MonitoringMatrixRow) -> StatusStyle {
        var base: StatusStyle
        if row.down > 0 { base = .path(.down) } else if row.degraded > 0 { base = .path(.degraded(nil)) } else if row.up == 0 && row.unknown > 0 { base = .path(.unknown(nil)) } else { base = .path(.up) }
        base.word = counts(row)
        return base
    }

    private func counts(_ row: MonitoringMatrixRow) -> String {
        String(row.summary.dropFirst(row.name.count + 2))
    }
}

/// The grid: a Canvas of shape-encoded cells under a pinned header row of
/// targets and a pinned column of sources. Header taps push filtered Paths.
struct MonitoringMatrixGrid: View {
    let matrix: MonitoringMatrix
    let fitToWidth: Bool
    let state: ResourceState<PathsResponse>

    @Environment(Router.self) private var router
    @Environment(\.astraDifferentiateWithoutColor) private var differentiate
    @ScaledMetric(relativeTo: .caption2) private var basePitch: CGFloat = 14
    @ScaledMetric(relativeTo: .caption2) private var labelWidth: CGFloat = 112
    @ScaledMetric(relativeTo: .caption2) private var headerHeight: CGFloat = 96
    @State private var offset = CGPoint.zero

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                MonitoringMatrixLegend()
                Text("\(matrix.rows.count) sources, \(matrix.columns.count) targets. Open a source's or target's paths from the filter menu.")
                    .textRole(.chartAxis)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
            .accessibilityElement(children: .combine)
            Divider()
            GeometryReader { proxy in
                let pitch = cellPitch(width: proxy.size.width)
                grid(pitch: pitch, viewport: proxy.size)
            }
            Divider()
            MonitoringFreshness(state: state, cadence: .paths)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.s)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func cellPitch(width: CGFloat) -> CGFloat {
        guard fitToWidth, !matrix.columns.isEmpty else { return basePitch }
        let fitted = (width - labelWidth - Spacing.l) / CGFloat(matrix.columns.count)
        return min(max(fitted, 8), 44)
    }

    private func grid(pitch: CGFloat, viewport: CGSize) -> some View {
        let width = CGFloat(matrix.columns.count) * pitch
        let height = CGFloat(matrix.rows.count) * pitch
        return ZStack(alignment: .topLeading) {
            ScrollView([.horizontal, .vertical]) {
                MonitoringMatrixCanvas(matrix: matrix, pitch: pitch, differentiate: differentiate)
                    .frame(width: width, height: height)
                    .padding(.leading, labelWidth)
                    .padding(.top, headerHeight)
                    .padding([.trailing, .bottom], Spacing.l)
                    // A grid smaller than the screen stays at the top leading corner, under its headers.
                    .frame(minWidth: viewport.width, minHeight: viewport.height, alignment: .topLeading)
            }
            .onScrollGeometryChange(for: CGPoint.self) { geometry in
                CGPoint(x: geometry.contentOffset.x + geometry.contentInsets.leading, y: geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, value in
                offset = value
            }
            columnHeaders(pitch: pitch)
                .offset(x: labelWidth - offset.x)
                .frame(maxWidth: .infinity, maxHeight: headerHeight, alignment: .topLeading)
                .clipped()
                .background(Color(uiColor: .systemGroupedBackground))
            rowHeaders(pitch: pitch)
                .offset(y: headerHeight - offset.y)
                .frame(maxWidth: labelWidth, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .background(Color(uiColor: .systemGroupedBackground))
            Text("Source \u{2193}  Target \u{2192}")
                .textRole(.chartAxis)
                .foregroundStyle(.secondary)
                .padding(.leading, Spacing.s)
                .frame(width: labelWidth, height: headerHeight, alignment: .bottomLeading)
                .background(Color(uiColor: .systemGroupedBackground))
                .accessibilityHidden(true)
        }
        .clipped()
    }

    private func columnHeaders(pitch: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(matrix.columns) { column in
                Button {
                    router.push(.monitoring(.paths(query: MonitoringMatrix.targetQuery(column))))
                } label: {
                    Text(column.name)
                        .textRole(.chartAxis)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: headerHeight - Spacing.s, height: pitch, alignment: .leading)
                        .rotationEffect(.degrees(-90))
                        .frame(width: pitch, height: headerHeight - Spacing.s)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(pitch >= Spacing.minimumTarget ? Color.accentText : Color.secondary)
                .allowsHitTesting(pitch >= Spacing.minimumTarget)
                .accessibilityLabel("Paths to \(column.name)")
            }
        }
        .padding(.top, Spacing.xs)
        .frame(height: headerHeight, alignment: .top)
    }

    private func rowHeaders(pitch: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(matrix.rows) { row in
                Button {
                    router.push(.monitoring(.paths(query: MonitoringMatrix.sourceQuery(row))))
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if row.hasProblems {
                            Image(systemName: row.down > 0 ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(row.down > 0 ? Color.statusFailFill : Color.statusWarnFill)
                                .accessibilityHidden(true)
                        }
                        Text(row.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .textRole(.chartAxis)
                    .frame(width: labelWidth - Spacing.s, height: pitch, alignment: .leading)
                    .padding(.leading, Spacing.s)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(pitch >= Spacing.minimumTarget ? Color.accentText : Color.secondary)
                .allowsHitTesting(pitch >= Spacing.minimumTarget)
                .accessibilityLabel("Paths from \(row.summary)")
            }
        }
    }
}

/// The cells, drawn in one Canvas. State is encoded by shape as well as
/// color (section 4.6): down fills the cell, degraded its lower half, up a
/// thin bar at the bottom, unknown an outline, paused a short dash. A pair
/// the source does not probe is left empty.
struct MonitoringMatrixCanvas: View {
    let matrix: MonitoringMatrix
    let pitch: CGFloat
    let differentiate: Bool

    var body: some View {
        Canvas { context, _ in
            let inset = max(1, pitch * 0.1)
            for (rowIndex, row) in matrix.rows.enumerated() {
                for (columnIndex, cell) in row.cells.enumerated() {
                    guard let cell else { continue }
                    let rect = CGRect(x: CGFloat(columnIndex) * pitch, y: CGFloat(rowIndex) * pitch, width: pitch, height: pitch).insetBy(dx: inset, dy: inset)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Color(uiColor: .tertiarySystemFill)))
                    draw(cell, in: rect, context: &context)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ cell: MonitoringStripCell, in rect: CGRect, context: inout GraphicsContext) {
        switch cell {
        case .down:
            fill(Path(roundedRect: rect, cornerRadius: 2), .statusFailFill, &context)
        case .degraded:
            fill(Path(roundedRect: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), cornerRadius: 1.5), .statusWarnFill, &context)
        case .up:
            let bar = max(2, rect.height * 0.2)
            fill(Path(roundedRect: CGRect(x: rect.minX, y: rect.maxY - bar, width: rect.width, height: bar), cornerRadius: 1), .statusOKFill, &context)
        case .unknown:
            context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2), with: .color(.statusQuiet), lineWidth: 1)
        case .paused:
            let dash = CGRect(x: rect.midX - rect.width / 4, y: rect.midY - 0.75, width: rect.width / 2, height: 1.5)
            context.fill(Path(dash), with: .color(.statusQuiet))
        }
    }

    private func fill(_ path: Path, _ color: Color, _ context: inout GraphicsContext) {
        context.fill(path, with: .color(color))
        if differentiate {
            context.stroke(path, with: .color(.primary.opacity(0.6)), lineWidth: 1)
        }
    }
}

/// The matrix's legend, drawn with the same shapes as the cells.
struct MonitoringMatrixLegend: View {
    @Environment(\.astraDifferentiateWithoutColor) private var differentiate

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.m) { items }
            VStack(alignment: .leading, spacing: Spacing.xs) { items }
        }
        .textRole(.chartAxis)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var items: some View {
        ForEach(MonitoringStripCell.allCases, id: \.self) { cell in
            HStack(spacing: Spacing.xs) {
                MonitoringMatrixCanvas(matrix: MonitoringMatrix(single: cell), pitch: 12, differentiate: differentiate)
                    .frame(width: 12, height: 12)
                Text(cell.rawValue)
            }
        }
    }
}

extension MonitoringMatrix {
    /// One cell, for the legend.
    fileprivate init(single cell: MonitoringStripCell) {
        self.init(items: [])
        columns = [MonitoringMatrixColumn(id: "c", name: "", targetNode: "")]
        rows = [MonitoringMatrixRow(id: "r", name: "", cells: [cell], down: 0, degraded: 0, unknown: 0, paused: 0, up: 0)]
    }
}
