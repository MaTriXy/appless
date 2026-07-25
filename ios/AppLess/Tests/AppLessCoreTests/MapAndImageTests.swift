import Foundation
import GenOSCore
import Testing

@testable import AppLessCore

/// MapView zoom semantics and semantic-image resolution.
@Suite struct MapAndImageTests {

    // MARK: - Zoom

    @Test func zoomDefaultsToNeighborhood() {
        #expect(MapGeometry.zoom(nil) == 15)
        #expect(MapGeometry.zoom(12) == 12)
        #expect(MapGeometry.zoom(17) == 17)
        // Nonsense zooms clamp instead of producing a wrapped span.
        #expect(MapGeometry.zoom(-4) == 1)
        #expect(MapGeometry.zoom(99) == 20)
    }

    @Test func higherZoomShowsLessGround() {
        let city = MapGeometry.longitudeDelta(zoom: 12, width: 390)
        let neighborhood = MapGeometry.longitudeDelta(zoom: 15, width: 390)
        let street = MapGeometry.longitudeDelta(zoom: 17, width: 390)
        #expect(city > neighborhood)
        #expect(neighborhood > street)
        // Each zoom level halves the visible span.
        #expect(abs(city / neighborhood - 8) < 1e-9)
        #expect(abs(neighborhood / street - 4) < 1e-9)
    }

    @Test func zoomZeroWouldShowTheWholeWorldAcrossOneTile() {
        // 360 degrees across 256 points at zoom 0 - the definition the formula
        // is derived from.
        #expect(abs(MapGeometry.longitudeDelta(zoom: 0, width: 256) - 360) < 1e-9)
    }

    @Test func latitudeSpanIsMercatorCorrected() {
        let equator = MapGeometry.latitudeDelta(zoom: 15, width: 390, height: 215, latitude: 0)
        let north = MapGeometry.latitudeDelta(zoom: 15, width: 390, height: 215, latitude: 60)
        // cos(60°) == 0.5
        #expect(abs(north / equator - 0.5) < 1e-9)
        #expect(equator > 0)
    }

    @Test func spanReturnsBothDeltas() {
        let span = MapGeometry.span(zoom: 15, width: 390, latitude: 0)
        #expect(span.longitudeDelta == MapGeometry.longitudeDelta(zoom: 15, width: 390))
        #expect(span.latitudeDelta > 0)
        // A missing zoom uses the contract's default.
        #expect(
            MapGeometry.span(zoom: nil, width: 390, latitude: 0).longitudeDelta
                == MapGeometry.longitudeDelta(zoom: 15, width: 390))
    }

    @Test func degenerateSizesNeverProduceZeroOrNaN() {
        let span = MapGeometry.span(zoom: 15, width: 0, height: 0, latitude: 0)
        #expect(span.latitudeDelta > 0)
        #expect(span.longitudeDelta > 0)
        #expect(span.latitudeDelta.isFinite)
    }

    // MARK: - Images

    @Test func semanticImageRefsResolveThroughGenOSCore() {
        let resolution = SemanticImage.resolve("/api/img?q=sushi+plate&seed=3&w=800&h=500")
        guard case .url(let url) = resolution else {
            Issue.record("expected a URL")
            return
        }
        #expect(url == Images.loremflickrUrl(Images.parseImgUrl("/api/img?q=sushi+plate&seed=3&w=800&h=500")!))
        #expect(url.contains("loremflickr.com/800/500/sushi%2Cplate"))
        #expect(url.hasSuffix("?lock=3"))
    }

    @Test func nonSemanticSourcesPassThrough() {
        #expect(SemanticImage.resolve("https://example.com/a.png") == .url("https://example.com/a.png"))
        #expect(SemanticImage.resolve(nil) == .none)
        #expect(SemanticImage.resolve("") == .none)
    }

    @Test func unsplashResolutionFollowsTheCacheStates() {
        let src = "/api/img?q=cat&seed=1"
        // nil cache entry = search in flight → placeholder, no double load.
        #expect(SemanticImage.resolve(src, unsplashCandidates: nil) == .pending)
        // empty = search failed → LoremFlickr.
        guard case .url(let fallback) = SemanticImage.resolve(src, unsplashCandidates: []) else {
            Issue.record("expected a URL")
            return
        }
        #expect(fallback.contains("loremflickr.com"))
        // hits → cropped Unsplash raw URL.
        guard
            case .url(let hit) = SemanticImage.resolve(
                src, unsplashCandidates: ["https://images.unsplash.com/photo-1?ixid=a"])
        else {
            Issue.record("expected a URL")
            return
        }
        #expect(hit.hasSuffix("&fit=crop&q=80"))
        // A non-semantic src ignores the cache entirely.
        #expect(SemanticImage.resolve("https://x/y.png", unsplashCandidates: nil) == .url("https://x/y.png"))
    }

    @Test func queryExposesTheParsedReference() {
        #expect(SemanticImage.query("/api/img?q=dog")?.q == "dog")
        #expect(SemanticImage.query("https://x/y.png") == nil)
        #expect(SemanticImage.query(nil) == nil)
    }
}
