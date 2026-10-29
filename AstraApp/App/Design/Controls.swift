import SwiftUI

/// A segmented control of at most four noun segments that becomes a Menu
/// picker labelled with the current segment when the text is xxxLarge or
/// larger, or the width is under 390 pt (section 1).
struct AdaptiveSegmentedPicker<Value: Hashable>: View {
    let title: String
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var width: CGFloat = 400
    @State private var pulse: HapticPulse?

    var body: some View {
        Group {
            if typeSize >= .xxxLarge || width < 390 {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: Spacing.minimumTarget)
            } else {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: selection) { pulse = HapticPulse(event: .selection) }
        .haptics(pulse)
    }
}

/// One section of a `FilterMenu`: an inline picker over string options.
struct FilterMenuSection: Identifiable {
    let title: String
    let options: [String]
    /// The broadest option, which counts as "no filter".
    let defaultOption: String
    let selection: Binding<String>

    var id: String { title }
    var isActive: Bool { selection.wrappedValue != defaultOption }
}

/// The toolbar filter menu for multi-dimension filters (section 5.0). Active
/// filters also show as search tokens and in `.navigationSubtitle`, which the
/// screen owns.
struct FilterMenu: View {
    let sections: [FilterMenuSection]

    var body: some View {
        Menu {
            ForEach(sections) { section in
                Picker(section.title, selection: section.selection) {
                    ForEach(section.options, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Label("Filter", systemImage: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityValue(isActive ? "Filtered" : "All")
    }

    private var isActive: Bool { sections.contains(where: \.isActive) }
}

/// A time range for lists that filter by time (1h, 24h, 7d, 30d, All, Custom).
enum TimeRangeSelection: Hashable, Sendable {
    case lastHour, lastDay, lastWeek, lastMonth, all
    case custom(since: Date, until: Date)

    static let presets: [TimeRangeSelection] = [.lastHour, .lastDay, .lastWeek, .lastMonth, .all]

    var title: String {
        switch self {
        case .lastHour: "1h"
        case .lastDay: "24h"
        case .lastWeek: "7d"
        case .lastMonth: "30d"
        case .all: "All"
        case .custom: "Custom"
        }
    }

    func since(now: Date) -> Date? {
        switch self {
        case .lastHour: now.addingTimeInterval(-3600)
        case .lastDay: now.addingTimeInterval(-86_400)
        case .lastWeek: now.addingTimeInterval(-7 * 86_400)
        case .lastMonth: now.addingTimeInterval(-30 * 86_400)
        case .all: nil
        case .custom(let since, _): since
        }
    }

    /// Only a custom range has an upper bound; servers without `until` filter on device.
    var until: Date? {
        if case .custom(_, let until) = self { return until }
        return nil
    }
}

/// The toolbar range menu (section 5.0).
struct RangeMenu: View {
    @Binding var selection: TimeRangeSelection
    @State private var editingCustom = false
    @State private var since = Date.now.addingTimeInterval(-86_400)
    @State private var until = Date.now

    var body: some View {
        Menu {
            Picker("Range", selection: $selection) {
                ForEach(TimeRangeSelection.presets, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Button("Custom…", systemImage: "calendar") { editingCustom = true }
        } label: {
            Label("Range: \(selection.title)", systemImage: "calendar.badge.clock")
        }
        .sheet(isPresented: $editingCustom) {
            NavigationStack {
                Form {
                    DatePicker("Since", selection: $since, in: ...until)
                    DatePicker("Until", selection: $until, in: since...)
                }
                .navigationTitle("Custom range")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { editingCustom = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") {
                            selection = .custom(since: since, until: until)
                            editingCustom = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

/// Offset paging with a "Load more" fallback row.
@MainActor @Observable
final class PagedListLoader<Item: Sendable> {
    typealias Fetch = @Sendable (_ offset: Int, _ limit: Int) async throws -> [Item]

    private(set) var items: [Item] = []
    private(set) var isLoading = false
    private(set) var reachedEnd = false
    private(set) var error: LatticeAPIError?
    let pageSize: Int
    private let fetch: Fetch

    init(pageSize: Int = 50, fetch: @escaping Fetch) {
        self.pageSize = pageSize
        self.fetch = fetch
    }

    func reload() async {
        items = []
        reachedEnd = false
        await loadMore()
    }

    func loadMore() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await fetch(items.count, pageSize)
            items += page
            reachedEnd = page.count < pageSize
            error = nil
        } catch {
            self.error = LatticeAPIError(error)
        }
    }
}

/// The last row of a paged list: loads the next page when it appears, and
/// offers a button when that failed.
struct LoadMoreRow<Item: Sendable>: View {
    let loader: PagedListLoader<Item>

    var body: some View {
        if let error = loader.error {
            ErrorRow(message: "Could not load more: \(error.localizedDescription)") {
                Task { await loader.loadMore() }
            }
        } else if !loader.reachedEnd {
            Button("Load more") { Task { await loader.loadMore() } }
                .frame(maxWidth: .infinity, minHeight: Spacing.minimumTarget)
                .task { await loader.loadMore() }
        }
    }
}
