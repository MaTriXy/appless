//
//  MapGeometry.swift
//  AppLessCore
//
//  The zoom → span conversion the SwiftUI `MapView` renderer needs.
//
//  The RN MapView embeds Google Maps, which takes a web-Mercator zoom level
//  directly (`&z=<zoom>`). MapKit instead wants an `MKCoordinateSpan`, so the
//  same zoom semantics the contract documents - 12 = city, 15 = neighborhood
//  (default), 17 = street - are converted here, in plain Doubles, so Linux can
//  test them without MapKit.
//
//  NO SwiftUI and NO MapKit in this file.
//

import Foundation

public enum MapGeometry {

    /// Web-Mercator tile size, in points - the constant every zoom-level
    /// formula is defined against.
    public static let tileSize: Double = 256

    /// The fixed height of the map surface. `shared/map.tsx` L50.
    public static let viewHeight: Double = 215

    /// Contract zoom levels (`contract.tsx` L409).
    public static let cityZoom = 12
    public static let neighborhoodZoom = 15
    public static let streetZoom = 17

    /// `typeof props.zoom === "number" ? props.zoom : 15` (`shared/map.tsx` L21),
    /// then clamped to the range web Mercator actually defines so a nonsense
    /// zoom cannot produce a degenerate or wrapped span.
    public static func zoom(_ raw: Int?) -> Int {
        guard let raw else { return neighborhoodZoom }
        return min(max(raw, 1), 20)
    }

    /// Degrees of longitude visible across `width` points at `zoom`.
    ///
    /// At zoom z the whole world (360°) is `tileSize * 2^z` points wide, so a
    /// viewport of `width` points spans `360 * width / (256 * 2^z)`.
    public static func longitudeDelta(zoom: Int, width: Double) -> Double {
        let worldWidth = tileSize * pow(2, Double(zoom))
        return 360 * max(width, 1) / worldWidth
    }

    /// Degrees of latitude visible across `height` points at `zoom`.
    ///
    /// Mercator compresses longitude by `cos(latitude)`, so a degree of
    /// latitude covers more screen than a degree of longitude away from the
    /// equator; the aspect-corrected span keeps the requested zoom honest at
    /// any latitude.
    public static func latitudeDelta(
        zoom: Int,
        width: Double,
        height: Double,
        latitude: Double
    ) -> Double {
        _ = width
        return latitudeDelta(zoom: zoom, height: height, latitude: latitude)
    }

    /// The latitude span alone.
    ///
    /// The width terms cancel (`longitudeDelta / width` is `360 / (256 · 2^z)`
    /// whatever the width is), so a map that lets MapKit widen the longitude to
    /// the view's aspect ratio - which it does automatically - only needs this.
    public static func latitudeDelta(zoom: Int, height: Double, latitude: Double) -> Double {
        let degreesPerPoint = 360 / (tileSize * pow(2, Double(zoom)))
        let clampedLatitude = min(max(latitude, -85), 85)
        return degreesPerPoint * max(height, 1) * cos(clampedLatitude * .pi / 180)
    }

    /// Both deltas at once - what the renderer feeds `MKCoordinateSpan`.
    public static func span(
        zoom rawZoom: Int?,
        width: Double,
        height: Double = viewHeight,
        latitude: Double
    ) -> (latitudeDelta: Double, longitudeDelta: Double) {
        let z = zoom(rawZoom)
        return (
            latitudeDelta: latitudeDelta(zoom: z, width: width, height: height, latitude: latitude),
            longitudeDelta: longitudeDelta(zoom: z, width: width)
        )
    }

    /// `props.placeName ?? ""` (`shared/map.tsx` L20) - the geocoder query and
    /// the marker's title.
    public static func placeName(_ raw: String?) -> String { raw ?? "" }
}
