package dev.appless.uicore

import kotlin.math.cos
import kotlin.math.pow

/**
 * The zoom -> span conversion the Compose `MapView` renderer needs.
 *
 * The RN MapView embeds Google Maps, which takes a web-Mercator zoom level
 * directly (`&z=<zoom>`, `shared/map.tsx` L22). Android's Maps Compose surface
 * takes a `CameraPosition` zoom, but a plain `MapView` fallback (and the tests)
 * want an explicit lat/lng span, so the same zoom semantics the contract
 * documents — 12 = city, 15 = neighborhood (default), 17 = street — are
 * converted here in plain Doubles so this stays testable headlessly.
 *
 * NO Compose and NO Maps SDK in this file.
 */
public object MapGeometry {

    /** Web-Mercator tile size, in dp — the constant every zoom-level formula is defined against. */
    public const val TILE_SIZE: Double = 256.0

    /** The fixed height of the map surface — `shared/map.tsx` L50. */
    public const val VIEW_HEIGHT: Double = 215.0

    /** Contract zoom levels (`ui/contract.tsx`, `MapView.zoom`). */
    public const val CITY_ZOOM: Int = 12
    public const val NEIGHBORHOOD_ZOOM: Int = 15
    public const val STREET_ZOOM: Int = 17

    /** The placeholder fill behind the web view — `shared/map.tsx` L54. */
    public val backgroundColor: MdColor = MdColor("rgba(120,120,128,0.14)")

    /**
     * `typeof props.zoom === "number" ? props.zoom : 15` (`shared/map.tsx` L21),
     * then clamped to the range web Mercator actually defines so a nonsense zoom
     * cannot produce a degenerate or wrapped span.
     */
    public fun zoom(raw: Int?): Int {
        if (raw == null) return NEIGHBORHOOD_ZOOM
        return raw.coerceIn(1, 20)
    }

    /**
     * Degrees of longitude visible across `width` dp at `zoom`.
     *
     * At zoom z the whole world (360 degrees) is `TILE_SIZE * 2^z` dp wide, so a
     * viewport of `width` dp spans `360 * width / (256 * 2^z)`.
     */
    public fun longitudeDelta(zoom: Int, width: Double): Double {
        val worldWidth = TILE_SIZE * 2.0.pow(zoom.toDouble())
        return 360.0 * maxOf(width, 1.0) / worldWidth
    }

    /**
     * Degrees of latitude visible across `height` dp at `zoom`.
     *
     * Mercator compresses longitude by `cos(latitude)`, so a degree of latitude
     * covers more screen than a degree of longitude away from the equator; the
     * aspect-corrected span keeps the requested zoom honest at any latitude.
     */
    public fun latitudeDelta(zoom: Int, height: Double, latitude: Double): Double {
        val degreesPerPoint = 360.0 / (TILE_SIZE * 2.0.pow(zoom.toDouble()))
        val clamped = latitude.coerceIn(-85.0, 85.0)
        return degreesPerPoint * maxOf(height, 1.0) * cos(clamped * Math.PI / 180.0)
    }

    /** Both deltas at once — what the renderer feeds the camera. */
    public data class Span(val latitudeDelta: Double, val longitudeDelta: Double)

    public fun span(
        rawZoom: Int?,
        width: Double,
        height: Double = VIEW_HEIGHT,
        latitude: Double,
    ): Span {
        val z = zoom(rawZoom)
        return Span(
            latitudeDelta = latitudeDelta(z, height, latitude),
            longitudeDelta = longitudeDelta(z, width),
        )
    }

    /** `props.placeName ?? ""` (`shared/map.tsx` L20) — the geocoder query and the marker title. */
    public fun placeName(raw: String?): String = raw ?: ""

    /**
     * The embed URL the RN WebView loads — `shared/map.tsx` L22:
     * `https://maps.google.com/maps?q=<encoded place>&z=<zoom>&output=embed`.
     *
     * Note the zoom here is the RAW prop value with only the `?? 15` default
     * applied (RN never clamps); [zoom] clamping is a native-span concern only.
     */
    public fun embedUrl(rawPlaceName: String?, rawZoom: Int?): String {
        val place = placeName(rawPlaceName)
        val z = rawZoom ?: NEIGHBORHOOD_ZOOM
        return "https://maps.google.com/maps?q=${encodeUriComponent(place)}&z=$z&output=embed"
    }

    /**
     * `encodeURIComponent` — percent-encodes UTF-8 bytes, leaving
     * `A-Za-z0-9 - _ . ! ~ * ' ( )` untouched.
     */
    public fun encodeUriComponent(s: String): String {
        val unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
        val sb = StringBuilder()
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val c = (b.toInt() and 0xFF).toChar()
            if (c in unreserved) sb.append(c) else sb.append("%%%02X".format(b.toInt() and 0xFF))
        }
        return sb.toString()
    }
}
