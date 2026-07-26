package dev.appless.uicore

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import kotlin.math.cos

/**
 * `MapView` zoom semantics, ported from `src/genos/ui/shared/map.tsx`.
 */
class MapGeometryTest {

    @Test
    fun `the default zoom and the view height match the RN source`() {
        val map = RepoSources.text("src/genos/ui/shared/map.tsx")
        assertTrue(map.contains("typeof props.zoom === \"number\" ? props.zoom : 15"))
        assertTrue(map.contains("height: 215,"))
        assertEquals(15, MapGeometry.zoom(null))
        assertEquals(15, MapGeometry.NEIGHBORHOOD_ZOOM)
        assertEquals(215.0, MapGeometry.VIEW_HEIGHT)
        assertEquals(12, MapGeometry.CITY_ZOOM)
        assertEquals(17, MapGeometry.STREET_ZOOM)
        assertTrue(MapGeometry.backgroundColor.isParsed)
        assertEquals("rgba(120,120,128,0.14)", MapGeometry.backgroundColor.raw)
    }

    @Test
    fun `zoom is clamped to the range web Mercator defines`() {
        assertEquals(12, MapGeometry.zoom(12))
        assertEquals(1, MapGeometry.zoom(0))
        assertEquals(1, MapGeometry.zoom(-4))
        assertEquals(20, MapGeometry.zoom(99))
    }

    @Test
    fun `longitude span halves with every zoom level`() {
        val width = 393.0 // a Pixel-class viewport, in dp
        val z12 = MapGeometry.longitudeDelta(12, width)
        val z13 = MapGeometry.longitudeDelta(13, width)
        assertEquals(z12 / 2, z13, 1e-12)
        // 360 * width / (256 * 2^z)
        assertEquals(360.0 * width / (256.0 * 4096.0), z12, 1e-12)
        // At z=0 the whole 256dp world tile spans 360 degrees.
        assertEquals(360.0, MapGeometry.longitudeDelta(0, 256.0), 1e-12)
    }

    @Test
    fun `latitude span is Mercator-corrected by cos(latitude)`() {
        val height = MapGeometry.VIEW_HEIGHT
        val equator = MapGeometry.latitudeDelta(15, height, 0.0)
        val stockholm = MapGeometry.latitudeDelta(15, height, 59.33)
        assertTrue(stockholm < equator, "a degree of latitude covers less screen away from the equator")
        assertEquals(equator * cos(59.33 * Math.PI / 180.0), stockholm, 1e-12)
        assertEquals(360.0 / (256.0 * 32768.0) * height, equator, 1e-12)
        // Latitude is clamped so the poles cannot collapse the span to zero.
        assertEquals(
            MapGeometry.latitudeDelta(15, height, 85.0),
            MapGeometry.latitudeDelta(15, height, 89.9),
            1e-12,
        )
    }

    @Test
    fun `span combines both deltas at the resolved zoom`() {
        val span = MapGeometry.span(rawZoom = null, width = 393.0, latitude = 37.77)
        assertEquals(MapGeometry.longitudeDelta(15, 393.0), span.longitudeDelta, 1e-12)
        assertEquals(MapGeometry.latitudeDelta(15, 215.0, 37.77), span.latitudeDelta, 1e-12)
        // A city-level zoom is 8x wider than a street-level one (17 - 12 = 5... 2^3 apart per pair)
        val city = MapGeometry.span(12, 393.0, latitude = 0.0)
        val street = MapGeometry.span(17, 393.0, latitude = 0.0)
        assertEquals(32.0, city.longitudeDelta / street.longitudeDelta, 1e-9)
    }

    @Test
    fun `place name defaults to the empty string`() {
        assertEquals("", MapGeometry.placeName(null))
        assertEquals("Bangalore", MapGeometry.placeName("Bangalore"))
    }

    @Test
    fun `the embed URL is the one the RN WebView loads`() {
        assertEquals(
            "https://maps.google.com/maps?q=Koramangala%2C%20Bangalore&z=15&output=embed",
            MapGeometry.embedUrl("Koramangala, Bangalore", null),
        )
        assertEquals(
            "https://maps.google.com/maps?q=&z=17&output=embed",
            MapGeometry.embedUrl(null, 17),
        )
        // `encodeURIComponent` leaves the unreserved marks alone and encodes UTF-8.
        assertEquals("caf%C3%A9-b_a.r~(1)!*'", MapGeometry.encodeUriComponent("café-b_a.r~(1)!*'"))
        assertEquals("a%20b", MapGeometry.encodeUriComponent("a b"))
        assertEquals("a%2Bb", MapGeometry.encodeUriComponent("a+b"))
    }
}
