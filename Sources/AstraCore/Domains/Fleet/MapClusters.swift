import Foundation

/// Fits a MapKit region to node coordinates without producing a span MapKit aborts on.
/// Worldwide fleets can span more than 360 degrees of longitude after padding; `MKMapView`
/// raises if latitudeDelta is outside (0, 180] or longitudeDelta is outside (0, 360].
public enum FleetMapRegion: Sendable {
    public struct Result: Equatable, Sendable {
        public var centerLatitude: Double
        public var centerLongitude: Double
        public var latitudeDelta: Double
        public var longitudeDelta: Double
    }

    public static func fitting(latitudes: [Double], longitudes: [Double]) -> Result? {
        let pairs = zip(latitudes, longitudes).filter { lat, lon in
            lat.isFinite && lon.isFinite
                && lat >= -90 && lat <= 90
                && lon >= -180 && lon <= 180
        }
        guard let first = pairs.first else { return nil }
        var minLat = first.0
        var maxLat = first.0
        var minLon = first.1
        var maxLon = first.1
        for (lat, lon) in pairs.dropFirst() {
            minLat = min(minLat, lat)
            maxLat = max(maxLat, lat)
            minLon = min(minLon, lon)
            maxLon = max(maxLon, lon)
        }
        let latitudeDelta = min(180, max(8, (maxLat - minLat) * 1.6))
        let longitudeDelta = min(360, max(8, (maxLon - minLon) * 1.6))
        return Result(
            centerLatitude: (minLat + maxLat) / 2,
            centerLongitude: (minLon + maxLon) / 2,
            latitudeDelta: latitudeDelta,
            longitudeDelta: longitudeDelta
        )
    }
}

/// One map annotation: the nodes whose coordinates round to the same half degree.
public struct FleetMapCluster: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var latitude: Double
    public var longitude: Double
    /// The place the members share ("Tokyo"), or the first member's.
    public var place: String
    /// Worst first.
    public var members: [NodeGeoView]

    public var worst: NodeHonesty {
        members.map { NodeHonesty(serverValue: $0.status) }.min { $0.severityRank < $1.severityRank } ?? .online
    }

    /// Members that are not online, by state, worst first: "1 offline, 1 degraded".
    public var problems: [(honesty: NodeHonesty, count: Int)] {
        let counts = Dictionary(grouping: members.map { NodeHonesty(serverValue: $0.status) }, by: { $0 }).mapValues(\.count)
        return counts.filter { $0.key != .online }.sorted { $0.key.severityRank < $1.key.severityRank }.map { ($0.key, $0.value) }
    }

    /// "Tokyo, 4 nodes, 1 offline", the VoiceOver label and callout title.
    public var label: String {
        var parts = [place, members.count == 1 ? "1 node" : "\(members.count) nodes"]
        for (honesty, count) in problems {
            let word = honesty == .neverReported ? "never reported" : honesty.rawValue
            parts.append("\(count) \(word)")
        }
        return parts.joined(separator: ", ")
    }
}

/// A latency arc between two located nodes, drawn for a path.
public struct FleetMapArc: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var pathKey: String
    public var fromLatitude: Double
    public var fromLongitude: Double
    public var toLatitude: Double
    public var toLongitude: Double
    public var state: PathDisplayState
}

/// Nodes grouped by coordinates rounded to 0.5 degrees for the fleet map (M2).
public enum MapClusters {
    public static let cell = 0.5

    public static func rounded(_ value: Double) -> Double {
        (value / cell).rounded() * cell
    }

    /// Located nodes only; a node without a usable coordinate is in `unlocated`.
    public static func clusters(_ nodes: [NodeGeoView]) -> [FleetMapCluster] {
        var buckets: [String: [NodeGeoView]] = [:]
        for node in nodes where node.hasCoordinate {
            guard let geo = node.geo else { continue }
            buckets[key(geo.lat, geo.lon), default: []].append(node)
        }
        return buckets.map { key, members in
            let sorted = members.sorted { a, b in
                let ra = NodeHonesty(serverValue: a.status).severityRank, rb = NodeHonesty(serverValue: b.status).severityRank
                if ra != rb { return ra < rb }
                return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }
            let lat = members.compactMap { $0.geo?.lat }.reduce(0, +) / Double(members.count)
            let lon = members.compactMap { $0.geo?.lon }.reduce(0, +) / Double(members.count)
            let places = members.compactMap { $0.geo.map { $0.city.isEmpty ? $0.region : $0.city } }.filter { !$0.isEmpty }
            let place = mostCommon(places) ?? sorted.first?.displayName ?? key
            return FleetMapCluster(id: key, latitude: lat, longitude: lon, place: place, members: sorted)
        }
        .sorted { a, b in
            if a.worst.severityRank != b.worst.severityRank { return a.worst.severityRank < b.worst.severityRank }
            return a.place < b.place
        }
    }

    public static func unlocated(_ nodes: [NodeGeoView]) -> [NodeGeoView] {
        nodes.filter { !$0.hasCoordinate }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func key(_ lat: Double, _ lon: Double) -> String {
        "\(rounded(lat)),\(rounded(lon))"
    }

    private static func mostCommon(_ values: [String]) -> String? {
        let counts = Dictionary(grouping: values, by: { $0 }).mapValues(\.count)
        return counts.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key
    }

    /// Arcs for node-to-node paths whose ends are both located. Problem
    /// paths only unless `all`; a path to an address has no second end.
    public static func arcs(_ response: PathsResponse, nodes: [NodeGeoView], all: Bool) -> [FleetMapArc] {
        let located = Dictionary(nodes.compactMap { node -> (String, NodeGeoInfo)? in
            guard node.hasCoordinate, let geo = node.geo else { return nil }
            return (node.id, geo)
        }, uniquingKeysWith: { first, _ in first })
        return response.paths.compactMap { path in
            guard !path.targetNode.isEmpty, let from = located[path.source], let to = located[path.targetNode] else { return nil }
            let state = path.displayState(judgesDegraded: response.judgesDegraded)
            if !all, !isProblem(state) { return nil }
            return FleetMapArc(id: path.id, pathKey: path.key, fromLatitude: from.lat, fromLongitude: from.lon,
                               toLatitude: to.lat, toLongitude: to.lon, state: state)
        }
    }

    public static func isProblem(_ state: PathDisplayState) -> Bool {
        switch state {
        case .down, .degraded: true
        case .up, .unknown, .paused: false
        }
    }

    /// Problem paths for the list view, worst first.
    public static func problemPaths(_ response: PathsResponse) -> [PathView] {
        response.paths.filter { isProblem($0.displayState(judgesDegraded: response.judgesDegraded)) }
            .sorted { a, b in
                FleetPathPick.rank(a.displayState(judgesDegraded: response.judgesDegraded))
                    < FleetPathPick.rank(b.displayState(judgesDegraded: response.judgesDegraded))
            }
    }
}
