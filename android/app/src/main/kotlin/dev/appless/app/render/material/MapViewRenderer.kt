package dev.appless.app.render.material

import android.annotation.SuppressLint
import android.view.ViewGroup
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.viewinterop.AndroidView
import dev.appless.app.render.ComposeRenderer
import dev.appless.app.render.get
import dev.appless.app.render.intOrNull
import dev.appless.app.render.stringOrNull
import dev.appless.app.theme.toColor
import dev.appless.openuilang.ElementNode
import dev.appless.uicore.MapGeometry

/**
 * `MapView` — a port of `ui/shared/map.tsx` + `ui/material/map.tsx`.
 *
 * ## Why a WebView and not the Maps SDK
 *
 * The RN implementation deliberately uses Google Maps' **keyless**
 * `output=embed` mode, so AppLess ships with no Maps API key and no billing
 * account. That mode only works when the map is an IFRAME inside a real web
 * page — Google checks the `Referer`. Pointing a WebView straight at the embed
 * URL as its top-level document sends no referer and Google demands a key.
 *
 * So the port does exactly what RN does: load a tiny HTML host document whose
 * BASE URL is `https://www.google.com`, and let the iframe inside it carry a
 * referer. Swapping in `maps-compose` would work but would make the app
 * key-gated and put a Play-services dependency in the build — a bigger
 * behavioral change than any pixel difference.
 *
 * The URL itself comes from `ui-core`'s [MapGeometry.embedUrl], which owns the
 * `?? 15` zoom default and the `encodeURIComponent` of the place name.
 */
internal object MapViewRenderer : ComposeRenderer {

    /**
     * The RN Material design system passes `12` to `createMapRenderer`
     * (`material/map.tsx`). `ui-core`'s `MaterialMetrics.MAP_RADIUS` says 16 —
     * a drift in that constant, not in the RN source, so the RN literal wins
     * here and the discrepancy is reported rather than silently doubled.
     */
    private const val CORNER_RADIUS_DP = 12.0

    @SuppressLint("SetJavaScriptEnabled")
    @Composable
    override fun Render(node: ElementNode) {
        val place = node["placeName"].stringOrNull()
        val zoom = node["zoom"].intOrNull()
        val src = MapGeometry.embedUrl(place, zoom)

        Box(
            Modifier
                .fillMaxWidth()
                .height(MapGeometry.VIEW_HEIGHT.dp)
                .clip(RoundedCornerShape(CORNER_RADIUS_DP.dp))
                // `rgba(120,120,128,0.14)` — the placeholder behind the frame,
                // visible until the tiles paint (`shared/map.tsx` L54).
                .background(MapGeometry.backgroundColor.toColor()),
        ) {
            AndroidView(
                factory = { context ->
                    WebView(context).apply {
                        layoutParams = ViewGroup.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.MATCH_PARENT,
                        )
                        // Keep navigations inside the view; a stray tap must not
                        // punt the user into a browser mid-screen.
                        webViewClient = WebViewClient()
                        settings.javaScriptEnabled = true
                        settings.domStorageEnabled = true
                        setBackgroundColor(android.graphics.Color.TRANSPARENT)
                    }
                },
                update = { webView ->
                    webView.loadDataWithBaseURL(BASE_URL, hostDocument(src), "text/html", "utf-8", null)
                },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }

    /** `baseUrl: "https://www.google.com"` — gives the document a web origin. */
    private const val BASE_URL = "https://www.google.com"

    /** The iframe host page, byte-for-byte the RN `source.html` (`map.tsx` L36). */
    private fun hostDocument(src: String): String =
        "<!DOCTYPE html><html><head><meta name=\"viewport\" " +
            "content=\"width=device-width, initial-scale=1, maximum-scale=1\">" +
            "<style>html,body{margin:0;padding:0;height:100%;overflow:hidden}" +
            "iframe{border:0;width:100%;height:100%}</style></head><body>" +
            "<iframe src=\"$src\" allowfullscreen loading=\"lazy\" " +
            "referrerpolicy=\"no-referrer-when-downgrade\"></iframe></body></html>"
}
