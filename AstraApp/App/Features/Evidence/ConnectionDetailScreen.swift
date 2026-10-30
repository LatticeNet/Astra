import SwiftUI

/// The detail model of one connection: the record and its stitched path
/// from `/api/trace/hops`, and the markers around it from `/api/trace/markers`.
/// There is no by-id read, so the hops lookup, which answers the record it
/// was keyed by, is the read.
@MainActor @Observable
final class EvidenceConnectionModel {
    let key: EvidenceRecordKey?
    private(set) var hops: ResourceState<EvidenceHopsResponse> = .idle
    private(set) var markers: ResourceState<[EvidenceMarker]> = .idle

    /// How far either side of the start markers are read.
    static let markerWindow: TimeInterval = 30 * 60

    init(id: String) {
        key = EvidenceRecordKey.parse(id)
    }

    var record: EvidenceConnRecord? {
        guard let key else { return nil }
        return hops.value?.record(for: key)
    }

    @discardableResult
    func refresh(session: SessionStore) async -> Bool {
        guard let key else { return true }
        if let missing = session.missing(EvidenceStore.requirement)?.first {
            hops = .denied(scope: missing)
            return true
        }
        guard let client = session.client else { return false }
        hops = hops.reloading
        do {
            hops = .loaded(try await client.evidenceHops(key), at: Date())
        } catch {
            if EvidenceStore.isCancellation(error) { return true }
            let apiError = LatticeAPIError(error)
            if case .invalidResponse = apiError { session.markCompanionBehind("This connection") }
            hops = hops.failing(apiError, surface: "This connection", missingScope: EvidenceCapture.readScope)
            return false
        }
        if let start = record?.startedAt ?? key.startedAt {
            markers = markers.reloading
            do {
                let found = try await client.evidenceMarkers(nodeIDs: [key.nodeID], since: start.addingTimeInterval(-Self.markerWindow), until: start.addingTimeInterval(Self.markerWindow))
                markers = .loaded(found, at: Date())
            } catch {
                if !EvidenceStore.isCancellation(error) {
                    markers = markers.failing(LatticeAPIError(error), surface: "Markers", missingScope: EvidenceCapture.readScope)
                }
            }
        }
        return true
    }
}

/// M10-03 Connection. Every field of the record, its hop path with the
/// stitcher's confidence in words, the markers around it, and links to its
/// node, its line and its user.
struct ConnectionDetailScreen: View {
    let id: String

    @Environment(SessionStore.self) private var session
    @Environment(NodeDirectory.self) private var nodes
    @Environment(ChangeLog.self) private var changes
    @Environment(Router.self) private var router
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.timeZoneMode) private var mode
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var model: EvidenceConnectionModel

    init(id: String) {
        self.id = id
        _model = State(initialValue: EvidenceConnectionModel(id: id))
    }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(model.record.map { EvidenceCloseState.of($0).word } ?? "")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Open on web", systemImage: "safari") { router.openOnWeb(.connection(id: id)) }
                        Button("Copy link", systemImage: "link") { EvidenceCopy.copy(EvidenceCopy.link(connection: id)) }
                        Button("Copy ID", systemImage: "number") { EvidenceCopy.copy(id) }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
            .onChange(of: id) { _, newID in model = EvidenceConnectionModel(id: newID) }
            .polling(.standard, version: changes.version([.evidence])) {
                await nodes.refreshIfOlder(than: 15)
                return await model.refresh(session: session)
            }
    }

    private var title: String {
        guard let record = model.record else { return "Connection" }
        let host = record.sniffedDomain.isEmpty ? (record.dstHost.isEmpty ? record.dstIP : record.dstHost) : record.sniffedDomain
        return host.isEmpty ? "Connection" : host
    }

    @ViewBuilder
    private var content: some View {
        if !network.isSatisfied && model.hops.value == nil {
            EvidenceOfflineState(noun: "This connection")
        } else if model.key == nil {
            WholeScreenState {
                ContentUnavailableView("Not a connection link", systemImage: "link",
                                       description: Text("The link does not name a node, core generation, log id and start time."))
            }
        } else if case .failed(.notFound, _, _) = model.hops {
            WholeScreenState {
                ContentUnavailableView {
                    Label("Connection not found", systemImage: "questionmark.circle")
                } description: {
                    Text("The store no longer holds this record, or this token cannot see its node.")
                } actions: {
                    Button("Open on web") { router.openOnWeb(.connection(id: id)) }
                }
            }
        } else {
            ResourceView(state: model.hops, noun: "this connection", retry: refresh) { hops in
                if let record = model.record {
                    list(record, hops: hops)
                } else {
                    WholeScreenState {
                        ContentUnavailableView("Connection not found", systemImage: "questionmark.circle",
                                               description: Text("The server answered a path without this record."))
                    }
                }
            }
        }
    }

    /// "198.51.100.150:40000 to api.example.org:443". At accessibility sizes
    /// the addresses may wrap after a separator rather than hyphenate.
    private func header(_ record: EvidenceConnRecord, breakable: Bool) -> String {
        func shown(_ value: String) -> String { breakable ? EvidenceText.breakableAddress(value) : value }
        return "\(record.source.isEmpty ? "Unknown source" : shown(record.source)) to \(record.destination.isEmpty ? "an unknown destination" : shown(record.destination))"
    }

    private func list(_ record: EvidenceConnRecord, hops: EvidenceHopsResponse) -> some View {
        let close = EvidenceCloseState.of(record)
        let nodeName = nodes.name(for: record.nodeID)
        return List {
            if case .failed(let error, _, _) = model.hops {
                Section { ErrorRow(message: "Could not refresh: \(error.localizedDescription)", retry: refresh) }
            }
            Section {
                Text(header(record, breakable: typeSize.isAccessibilitySize))
                    .textRole(.detailHeader)
                    .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
                    .accessibilityLabel(header(record, breakable: false))
                    .accessibilityAddTraits(.isHeader)
                StatusRow(style: .evidenceClose(close), title: nodeName, detail: summary(record), reason: closeReason(record, close),
                          accessibilityPhrase: "\(closeTitle(close)) on \(nodeName), \(spokenSummary(record))")
            }
            hopsSection(record, hops: hops)
            identitySection(record, nodeName: nodeName)
            connectionSection(record)
            lifecycleSection(record, close: close)
            markersSection
            Section {
                NavigationLink(value: AppRoute.evidence(.logs(nodeID: record.nodeID))) {
                    Label("Raw logs on \(nodeName)", systemImage: "doc.plaintext").frame(minHeight: Spacing.minimumTarget)
                }
                NavigationLink(value: AppRoute.evidence(.connections(filter: "node:\(record.nodeID)"))) {
                    Label("Connections on \(nodeName)", systemImage: "arrow.left.arrow.right").frame(minHeight: Spacing.minimumTarget)
                }
                WebLinkRow(path: .connection(id: id))
            } footer: {
                FreshnessFooter(state: model.hops, interval: 60)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.refresh(session: session) }
    }

    private func summary(_ record: EvidenceConnRecord) -> String {
        [EvidenceDuration.text(milliseconds: record.durationMS), EvidenceBytes.text(record)].compactMap { $0 }.joined(separator: " · ")
    }

    private func spokenSummary(_ record: EvidenceConnRecord) -> String {
        [EvidenceDuration.text(milliseconds: record.durationMS).map { "lasted \($0)" }, EvidenceBytes.spoken(record)].compactMap { $0 }.joined(separator: ", ")
    }

    private func closeTitle(_ close: EvidenceCloseState) -> String {
        switch close.id {
        case "open": "Still open"
        case "unknown": "How it ended was not recorded"
        default: close.word.prefix(1).uppercased() + close.word.dropFirst()
        }
    }

    private func closeReason(_ record: EvidenceConnRecord, _ close: EvidenceCloseState) -> String? {
        if let stalled = record.stalledAt { return "Went quiet in both directions at \(EvidenceText.stamp(stalled, mode: mode, locale: locale))." }
        if !close.certain { return close.raw.isEmpty ? "The connection produced no terminal line." : "The server said \(close.raw)." }
        return record.closeError.isEmpty ? nil : record.closeError
    }

    @ViewBuilder
    private func identitySection(_ record: EvidenceConnRecord, nodeName: String) -> some View {
        Section {
            if record.userName.isEmpty {
                DetailRow(label: "User", value: "No user logged", secondary: EvidenceUserKind.word(record.userKind), copyable: false)
            } else if record.userKind == "managed", !record.userID.isEmpty {
                NavigationLink(value: AppRoute.vpn(.user(id: record.userID))) {
                    LabeledContent("User") {
                        VStack(alignment: .trailing, spacing: Spacing.xxs) {
                            Text(record.userName).font(TextRole.identifierInRow.font)
                            Text(EvidenceUserKind.word(record.userKind)).textRole(.stamp)
                        }
                    }
                    .frame(minHeight: Spacing.minimumTarget)
                }
            } else {
                DetailRow(label: "User", value: record.userName, monospaced: true,
                          secondary: EvidenceUserKind.word(record.userKind) + (record.userKind == "managed" ? "" : ", not a Lattice user"))
            }
            if !record.userID.isEmpty {
                DetailRow(label: "Lattice user id", value: record.userID, monospaced: true)
            }
            NavigationLink(value: AppRoute.fleet(.node(id: record.nodeID))) {
                LabeledContent("Node", value: nodeName).frame(minHeight: Spacing.minimumTarget)
            }
            if !record.inboundTag.isEmpty {
                DetailRow(label: "Inbound", value: record.inboundType.isEmpty ? record.inboundTag : "\(record.inboundTag), \(record.inboundType)")
            }
            if !record.lineUUID.isEmpty {
                NavigationLink(value: AppRoute.vpn(.line(id: record.lineUUID))) {
                    LabeledContent("Line") {
                        Text(DetailRow.breakable(record.lineUUID)).font(TextRole.identifierInRow.font).multilineTextAlignment(.trailing)
                    }
                    .frame(minHeight: Spacing.minimumTarget)
                }
            }
        } header: {
            Text("Identity").accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func connectionSection(_ record: EvidenceConnRecord) -> some View {
        Section {
            if !record.network.isEmpty { DetailRow(label: "Network", value: record.network) }
            if !record.source.isEmpty { DetailRow(label: "Source", value: record.source, monospaced: true) }
            if !record.destination.isEmpty { DetailRow(label: "Destination", value: record.destination, monospaced: true) }
            if !record.dstIP.isEmpty && record.dstIP != record.dstHost { DetailRow(label: "Resolved address", value: record.dstIP, monospaced: true) }
            if !record.sniffedProtocol.isEmpty || !record.sniffedDomain.isEmpty {
                DetailRow(label: "Sniffed", value: [record.sniffedProtocol, record.sniffedDomain].filter { !$0.isEmpty }.joined(separator: ", "))
            }
            if !record.ruleText.isEmpty { DetailRow(label: "Matched rule", value: record.ruleText) }
            if !record.outboundTag.isEmpty {
                DetailRow(label: "Outbound", value: record.outboundType.isEmpty ? record.outboundTag : "\(record.outboundTag), \(record.outboundType)")
            }
        } header: {
            Text("Connection").accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func lifecycleSection(_ record: EvidenceConnRecord, close: EvidenceCloseState) -> some View {
        Section {
            if let started = record.startedAt {
                DetailRow(label: "Started", value: TimeDisplay.dateTime(started, mode: mode, locale: locale), secondary: TimeDisplay.otherZone(started, mode: mode, locale: locale))
            }
            if let ended = record.endedAt {
                DetailRow(label: "Ended", value: TimeDisplay.dateTime(ended, mode: mode, locale: locale), secondary: TimeDisplay.otherZone(ended, mode: mode, locale: locale))
            }
            DetailRow(label: "Duration", value: EvidenceDuration.text(milliseconds: record.durationMS) ?? (record.open ? "still open" : "not reported"), copyable: false)
            if record.bytesKnown {
                DetailRow(label: "Up", value: ByteFormatter.bytes(UInt64(max(0, record.upload))))
                DetailRow(label: "Down", value: ByteFormatter.bytes(UInt64(max(0, record.download))))
            } else {
                DetailRow(label: "Bytes", value: "not sampled", copyable: false)
            }
            if !record.closeError.isEmpty { DetailRow(label: "Close error", value: record.closeError) }
            if record.coreGeneration > 0 { DetailRow(label: "Core generation", value: String(record.coreGeneration), monospaced: true) }
            DetailRow(label: "Log id", value: String(record.logID), monospaced: true)
            if !record.sessionIDs.isEmpty { DetailRow(label: "Captured by", value: record.sessionIDs.joined(separator: ", "), monospaced: true) }
        } header: {
            Text("Lifecycle").accessibilityAddTraits(.isHeader)
        } footer: {
            if !record.bytesKnown {
                Text("This connection began and ended between two counter samples, so its bytes were never measured. That is not the same as zero.")
            }
        }
    }

    @ViewBuilder
    private func hopsSection(_ record: EvidenceConnRecord, hops: EvidenceHopsResponse) -> some View {
        let confidence = EvidenceHopConfidence.of(hops.path.confidence)
        Section {
            StatusRow(style: .evidenceHop(confidence), title: "Hop path", detail: hops.records.count == 1 ? "1 hop" : "\(hops.records.count) hops", reason: confidence.sentence)
            if hops.records.count > 1 {
                ForEach(Array(hops.records.enumerated()), id: \.element.id) { index, hop in
                    hopRow(hop, index: index, isAnchor: hop.key.names(record.key))
                }
            }
            if !hops.candidates.isEmpty {
                Text("Candidates the stitcher could not choose between").textRole(.footnote)
                ForEach(hops.candidates) { candidate in
                    hopRow(candidate, index: nil, isAnchor: false)
                }
            }
            if !hops.candidatesComplete {
                Text("The search for downstream records stopped at its limit, so the path may be incomplete.").textRole(.footnote)
            }
        } header: {
            Text("Hops").accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func hopRow(_ hop: EvidenceConnRecord, index: Int?, isAnchor: Bool) -> some View {
        let name = nodes.name(for: hop.nodeID)
        let title = index.map { "\($0 + 1). \(name)" } ?? name
        let detail = [hop.source.isEmpty ? nil : "from \(hop.source)", hop.outboundTag.isEmpty ? nil : "out \(hop.outboundTag)"].compactMap { $0 }.joined(separator: ", ")
        let row = StatusRow(style: .evidenceClose(EvidenceCloseState.of(hop)), title: isAnchor ? "\(title), this connection" : title, detail: detail)
        if isAnchor {
            row
        } else {
            NavigationLink(value: AppRoute.evidence(.connection(id: hop.id))) { row }
        }
    }

    @ViewBuilder
    private var markersSection: some View {
        Section {
            switch model.markers {
            case .loaded(let markers, _) where markers.isEmpty:
                Text("No restart, applied change or capture within 30 minutes of this connection.")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: Spacing.minimumTarget, alignment: .leading)
            case .failed(let error, _, _):
                ErrorRow(message: "Markers not read: \(error.localizedDescription)", retry: refresh)
            case .denied(let scope):
                ScopeDeniedRow(scope: scope)
            default:
                if let markers = model.markers.value {
                    ForEach(markers) { marker in
                        StatusRow(style: markerStyle(marker), title: marker.title.isEmpty ? marker.kind : marker.title, detail: marker.detail.isEmpty ? nil : marker.detail,
                                  trailing: marker.at.map { EvidenceText.stamp($0, mode: mode, locale: locale) })
                    }
                } else {
                    LoadingRows(label: "Loading markers", count: 1)
                }
            }
        } header: {
            Text("Around this connection").accessibilityAddTraits(.isHeader)
        }
    }

    private func markerStyle(_ marker: EvidenceMarker) -> StatusStyle {
        switch marker.kind {
        case EvidenceMarker.coreRestart: StatusStyle(word: "restart", symbol: "arrow.clockwise.circle", tone: .warn)
        case EvidenceMarker.configApply: StatusStyle(word: "applied", symbol: "square.and.arrow.down", tone: .quiet)
        case EvidenceMarker.subFetch: StatusStyle(word: "subscription fetched", symbol: "arrow.down.doc", tone: .quiet)
        case EvidenceMarker.session: StatusStyle(word: "capture", symbol: "record.circle", tone: .quiet)
        default: StatusStyle(word: marker.kind, symbol: "flag", tone: .quiet)
        }
    }

    private func refresh() {
        Task { await model.refresh(session: session) }
    }
}
