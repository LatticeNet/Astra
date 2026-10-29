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

        public init(centerLatitude: Double, centerLongitude: Double, latitudeDelta: Double, longitudeDelta: Double) {
            self.centerLatitude = centerLatitude
            self.centerLongitude = centerLongitude
            self.latitudeDelta = latitudeDelta
            self.longitudeDelta = longitudeDelta
        }
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

/// Where the map opens and which problem places it cannot show. Zoomed out,
/// MapKit draws a globe, so a fleet spread round the world never fits one
/// view: the map opens over the window of longitudes holding the most
/// problem places, and names the problem places left outside it.
public enum FleetMapFrame {
    /// Half the width, in degrees of longitude, of the window the map opens on.
    public static let halfWindow = 70.0

    /// The region to open on, chosen from the clusters' own longitudes.
    public static func opening(_ clusters: [FleetMapCluster]) -> FleetMapRegion.Result? {
        guard !clusters.isEmpty else { return nil }
        let best = clusters.map(\.longitude).max { a, b in score(clusters, center: a) < score(clusters, center: b) } ?? clusters[0].longitude
        let inside = clusters.filter { abs(wrapped($0.longitude - best)) <= halfWindow }
        let longitudes = inside.map { best + wrapped($0.longitude - best) }
        let latitudes = inside.map(\.latitude)
        guard let minLon = longitudes.min(), let maxLon = longitudes.max(), let minLat = latitudes.min(), let maxLat = latitudes.max() else { return nil }
        return FleetMapRegion.Result(
            centerLatitude: (minLat + maxLat) / 2,
            centerLongitude: wrapped((minLon + maxLon) / 2),
            latitudeDelta: min(170, max(8, (maxLat - minLat) * 1.5)),
            longitudeDelta: min(2 * halfWindow + 20, max(8, (maxLon - minLon) * 1.5))
        )
    }

    /// Problem clusters (any member not online) that `isShown` says are not on
    /// screen, worst first, so the map can name what panning hid.
    public static func hiddenProblems(_ clusters: [FleetMapCluster], isShown: (FleetMapCluster) -> Bool) -> [FleetMapCluster] {
        clusters.filter { $0.worst != .online && !isShown($0) }
            .sorted { a, b in
                a.worst.severityRank != b.worst.severityRank ? a.worst.severityRank < b.worst.severityRank : a.place < b.place
            }
    }

    /// Where a coordinate falls on a flat Mercator map showing `region` in a
    /// `width` by `height` frame, as fractions: (0, 0) top leading, (1, 1)
    /// bottom trailing. Values outside 0...1 are off screen.
    public static func screenFraction(latitude: Double, longitude: Double, region: FleetMapRegion.Result) -> (x: Double, y: Double) {
        func mercator(_ degrees: Double) -> Double {
            let clamped = max(-85, min(85, degrees)) * .pi / 180
            return log(tan(.pi / 4 + clamped / 2))
        }
        let x = wrapped(longitude - region.centerLongitude) / region.longitudeDelta + 0.5
        let top = mercator(region.centerLatitude + region.latitudeDelta / 2)
        let bottom = mercator(region.centerLatitude - region.latitudeDelta / 2)
        let y = top == bottom ? 0.5 : (top - mercator(latitude)) / (top - bottom)
        return (x, y)
    }

    /// Longitude difference folded into -180...180.
    public static func wrapped(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }

    /// Problem places first, then nodes, inside the window around `center`.
    private static func score(_ clusters: [FleetMapCluster], center: Double) -> Int {
        clusters.reduce(0) { total, cluster in
            guard abs(wrapped(cluster.longitude - center)) <= halfWindow else { return total }
            return total + (cluster.worst == .online ? 0 : 1_000) + cluster.members.count
        }
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
            let sorted = members.sorted(by: memberOrder)
            let lat = members.compactMap { $0.geo?.lat }.reduce(0, +) / Double(members.count)
            let lon = members.compactMap { $0.geo?.lon }.reduce(0, +) / Double(members.count)
            let places = members.compactMap { $0.geo.map { $0.city.isEmpty ? $0.region : $0.city } }.filter { !$0.isEmpty }
            let place = mostCommon(places) ?? sorted.first?.displayName ?? key
            return FleetMapCluster(id: key, latitude: lat, longitude: lon, place: place, members: sorted)
        }
        .sorted(by: worstFirst)
    }

    /// Merges clusters whose pins would overlap at the current zoom: centres
    /// closer than `latitudeGap` and `longitudeGap` degrees. Worst clusters
    /// anchor, so a merged pin always carries the worst member's glyph and the
    /// summed count; a healthy pin never sits over a failing one.
    public static func merged(_ clusters: [FleetMapCluster], latitudeGap: Double, longitudeGap: Double) -> [FleetMapCluster] {
        guard latitudeGap > 0, longitudeGap > 0, clusters.count > 1 else { return clusters }
        var groups: [[FleetMapCluster]] = []
        for cluster in clusters.sorted(by: worstFirst) {
            if let index = groups.firstIndex(where: { group in
                abs(group[0].latitude - cluster.latitude) < latitudeGap && abs(group[0].longitude - cluster.longitude) < longitudeGap
            }) {
                groups[index].append(cluster)
            } else {
                groups.append([cluster])
            }
        }
        return groups.map { group in
            guard group.count > 1 else { return group[0] }
            let members = group.flatMap(\.members).sorted(by: memberOrder)
            let weight = Double(members.count)
            let latitude = group.reduce(0) { $0 + $1.latitude * Double($1.members.count) } / weight
            let longitude = group.reduce(0) { $0 + $1.longitude * Double($1.members.count) } / weight
            let others = group.count - 1
            let place = "\(group[0].place) and \(others == 1 ? "1 more place" : "\(others) more places")"
            return FleetMapCluster(id: group.map(\.id).sorted().joined(separator: "+"), latitude: latitude, longitude: longitude,
                                   place: place, members: members)
        }
        .sorted(by: worstFirst)
    }

    private static func worstFirst(_ a: FleetMapCluster, _ b: FleetMapCluster) -> Bool {
        if a.worst.severityRank != b.worst.severityRank { return a.worst.severityRank < b.worst.severityRank }
        return a.place < b.place
    }

    private static func memberOrder(_ a: NodeGeoView, _ b: NodeGeoView) -> Bool {
        let ra = NodeHonesty(serverValue: a.status).severityRank, rb = NodeHonesty(serverValue: b.status).severityRank
        if ra != rb { return ra < rb }
        return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
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
    /// paths only unless `all`; a path to an address has no second end. Paths
    /// between the same two cells share one arc in the worst state, because
    /// overlapping geodesics mix their dash patterns into one no legend names.
    public static func arcs(_ response: PathsResponse, nodes: [NodeGeoView], all: Bool) -> [FleetMapArc] {
        let located = Dictionary(nodes.compactMap { node -> (String, NodeGeoInfo)? in
            guard node.hasCoordinate, let geo = node.geo else { return nil }
            return (node.id, geo)
        }, uniquingKeysWith: { first, _ in first })
        var byPair: [String: FleetMapArc] = [:]
        for path in response.paths {
            guard !path.targetNode.isEmpty, let from = located[path.source], let to = located[path.targetNode] else { continue }
            let state = path.displayState(judgesDegraded: response.judgesDegraded)
            if !all, !isProblem(state) { continue }
            let ends = [key(from.lat, from.lon), key(to.lat, to.lon)].sorted()
            guard ends[0] != ends[1] else { continue }
            let pair = ends.joined(separator: "|")
            if let kept = byPair[pair], FleetPathPick.rank(kept.state) <= FleetPathPick.rank(state) { continue }
            byPair[pair] = FleetMapArc(id: pair, pathKey: path.key, fromLatitude: from.lat, fromLongitude: from.lon,
                                       toLatitude: to.lat, toLongitude: to.lon, state: state)
        }
        return byPair.values.sorted { a, b in
            let ra = FleetPathPick.rank(a.state), rb = FleetPathPick.rank(b.state)
            return ra != rb ? ra > rb : a.id < b.id
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
