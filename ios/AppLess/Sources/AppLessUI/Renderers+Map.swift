//
//  Renderers+Map.swift
//  AppLessUI
//
//  MapView. Port of `src/genos/ui/shared/map.tsx` + `cupertino/map.tsx`.
//
//  RN embeds Google Maps in a WebView because React Native has no first-party
//  map; on iOS the native answer is MapKit, so the port geocodes `placeName`,
//  drops a marker on it, and converts the contract's web-Mercator zoom into an
//  `MKCoordinateSpan` via `AppLessCore.MapGeometry`.
//

#if canImport(SwiftUI)

import AppLessCore
import Foundation
import OpenUILang
import SwiftUI

#if canImport(MapKit)
import CoreLocation
import MapKit
#endif

#if canImport(MapKit)

/// A geocoded place, ready to annotate.
struct MapPlace: Identifiable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
}

/// REAL interactive map centered on a named place, with a marker on it.
/// `contract.tsx` L402-411: zoom 12 = city, 15 = neighborhood (default),
/// 17 = street.
struct MapViewRenderer: View {
    let node: ElementNode
    let ctx: RenderContext

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60))
    @State private var places: [MapPlace] = []

    var body: some View {
        let p = PropReader(node)
        let placeName = MapGeometry.placeName(p.string("placeName"))
        let zoom = MapGeometry.zoom(p.int("zoom"))
        Map(coordinateRegion: $region, annotationItems: places) { place in
            MapMarker(coordinate: place.coordinate, tint: Color(ctx.theme.red))
        }
        .frame(height: CdsMetrics.Size.mapHeight)
        .background(Color(ctx.theme.fill))
        .clipShape(RoundedRectangle(cornerRadius: CdsMetrics.Radius.media, style: .continuous))
        .task(id: "\(placeName)#\(zoom)") {
            await locate(placeName: placeName, zoom: zoom)
        }
    }

    /// Geocode, then frame the result at the requested zoom. A failed lookup
    /// leaves the last good region and simply shows no marker - the screen
    /// never breaks over a place the geocoder does not know.
    private func locate(placeName: String, zoom: Int) async {
        guard !placeName.isEmpty else { return }
        guard let placemark = try? await CLGeocoder().geocodeAddressString(placeName).first,
              let location = placemark.location
        else { return }
        let coordinate = location.coordinate
        // MapKit widens the longitude span to the view's aspect ratio on its
        // own, so only the latitude span has to carry the zoom level.
        let latitudeDelta = MapGeometry.latitudeDelta(
            zoom: zoom,
            height: CdsMetrics.Size.mapHeight,
            latitude: coordinate.latitude)
        places = [MapPlace(name: placeName, coordinate: coordinate)]
        region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(
                latitudeDelta: latitudeDelta,
                longitudeDelta: latitudeDelta))
    }
}

#else

/// MapKit is unavailable on this platform - keep the layout stable.
struct MapViewRenderer: View {
    let node: ElementNode
    let ctx: RenderContext

    var body: some View {
        Color(ctx.theme.fill)
            .frame(height: CdsMetrics.Size.mapHeight)
            .clipShape(
                RoundedRectangle(cornerRadius: CdsMetrics.Radius.media, style: .continuous))
    }
}

#endif

#endif
