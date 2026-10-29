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

/// Nodes grouped by coordinates rounded to 0.5 degrees for the fleet map (M2).
public enum MapClusters {
    // M2: implement.
}
