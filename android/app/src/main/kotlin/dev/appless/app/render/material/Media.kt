package dev.appless.app.render.material

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.request.ImageRequest
import dev.appless.app.render.ComposeRenderer
import dev.appless.app.render.field
import dev.appless.app.render.get
import dev.appless.app.render.isTruthy
import dev.appless.app.render.items
import dev.appless.app.render.reactText
import dev.appless.app.render.stringOrNull
import dev.appless.app.theme.LocalMdTheme
import dev.appless.app.theme.toColor
import dev.appless.openuilang.ElementNode
import dev.appless.uicore.MaterialMetrics
import dev.appless.uicore.SemanticImage

/**
 * Media renderers — `src/genos/ui/material/components.tsx` L443-553, plus the
 * shared semantic-image element (`ui/shared/media.tsx`).
 */

/**
 * `createImg(() => useMd().surfaceContainerHigh)` — `shared/media.tsx`.
 *
 * The model never emits a real URL: every `src` is a declarative
 * `/api/img?q=…&seed=N&w=W&h=H` query. `ui-core`'s [SemanticImage] owns the
 * resolution POLICY (keyless -> LoremFlickr, unknown src -> pass through,
 * absent -> placeholder); Coil only loads whatever URL comes back, and
 * crossfades it in the way RN's `opacity: loaded ? 1 : 0` did.
 */
@Composable
internal fun SemanticImg(src: String?, modifier: Modifier = Modifier) {
    val t = LocalMdTheme.current
    val placeholder = t.surfaceContainerHigh.toColor()
    when (val resolution = SemanticImage.resolve(src)) {
        is SemanticImage.Resolution.Url -> AsyncImage(
            model = ImageRequest.Builder(LocalContext.current)
                .data(resolution.url)
                .crossfade(true)
                .build(),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = modifier.background(placeholder),
        )
        // `return <View style={[style, {backgroundColor: placeholder}]} />`:
        // an unresolved src shows the themed block and loads NOTHING, so a
        // pending lookup can never double-fetch.
        SemanticImage.Resolution.None,
        SemanticImage.Resolution.Pending,
        -> Box(modifier.background(placeholder))
    }
}

/** `ImageBlock` — `components.tsx` L444-478: 16:9 hero with a scrimmed caption. */
internal object ImageBlockRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        val t = LocalMdTheme.current
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(16f / 9f)
                .clip(RoundedCornerShape(MaterialMetrics.IMAGE_RADIUS.dp))
                .background(t.surfaceContainerHigh.toColor()),
        ) {
            SemanticImg(node["src"].stringOrNull(), Modifier.fillMaxSize())
            val caption = node["caption"]
            if (caption.isTruthy()) {
                Box(
                    Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        // `["transparent", "rgba(0,0,0,0.62)"]` — L456.
                        .background(
                            Brush.verticalGradient(
                                listOf(Color.Transparent, Color(0f, 0f, 0f, 0.62f)),
                            )
                        )
                        .padding(
                            top = MaterialMetrics.IMAGE_CAPTION_PADDING_TOP.dp,
                            start = MaterialMetrics.IMAGE_CAPTION_PADDING_HORIZONTAL.dp,
                            end = MaterialMetrics.IMAGE_CAPTION_PADDING_HORIZONTAL.dp,
                            bottom = MaterialMetrics.IMAGE_CAPTION_PADDING_BOTTOM.dp,
                        ),
                ) {
                    Text(
                        text = caption.reactText(),
                        color = Color.White,
                        fontSize = MaterialMetrics.IMAGE_CAPTION_FONT_SIZE.sp,
                        fontWeight = FontWeight.Medium,
                    )
                }
            }
        }
    }
}

/**
 * `PhotoGrid` — `components.tsx` L480-500.
 *
 * `flexBasis: "31%"` + `flexGrow: 1` with a 3 gap is three square cells per
 * row, the last row stretching — `FlowRow(maxItemsInEachRow = 3)` with an equal
 * weight each.
 */
internal object PhotoGridRenderer : ComposeRenderer {
    @OptIn(ExperimentalLayoutApi::class)
    @Composable
    override fun Render(node: ElementNode) {
        val t = LocalMdTheme.current
        // `.filter((im) => im?.src)` — entries without a src are dropped, L484.
        val images = node["images"].items()
            .mapNotNull { it.field("src").stringOrNull() }
            .filter { it.isNotEmpty() }
        FlowRow(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(MaterialMetrics.PHOTO_GRID_RADIUS.dp))
                .background(t.surfaceContainerHigh.toColor()),
            horizontalArrangement = Arrangement.spacedBy(MaterialMetrics.PHOTO_GRID_GAP.dp),
            verticalArrangement = Arrangement.spacedBy(MaterialMetrics.PHOTO_GRID_GAP.dp),
            maxItemsInEachRow = 3,
        ) {
            for (src in images) {
                SemanticImg(
                    src = src,
                    modifier = Modifier
                        .weight(1f)
                        .aspectRatio(1f),
                )
            }
        }
    }
}

/** `Bubbles` — `components.tsx` L502-553: iMessage-style chat transcript. */
internal object BubblesRenderer : ComposeRenderer {
    @Composable
    override fun Render(node: ElementNode) {
        val t = LocalMdTheme.current
        // `.filter((m) => m?.text)` — L506.
        val messages = node["messages"].items().filter { it.field("text").isTruthy() }

        BoxWithConstraints(Modifier.fillMaxWidth()) {
            // `maxWidth: "78%"` (L512) resolves against the transcript width.
            val bubbleMax = this@BoxWithConstraints.maxWidth * 0.78f
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 2.dp),
                verticalArrangement = Arrangement.spacedBy(MaterialMetrics.BUBBLE_GAP.dp),
            ) {
                for (message in messages) {
                    val me = message.field("me").isTruthy()
                    val time = message.field("time")
                    if (time.isTruthy()) {
                        Text(
                            text = time.reactText(),
                            color = t.onSurfaceVariant.toColor(),
                            fontSize = MaterialMetrics.BUBBLE_AUTHOR_FONT_SIZE.sp,
                            fontWeight = FontWeight.Medium,
                            textAlign = TextAlign.Center,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(top = 8.dp, bottom = 3.dp),
                        )
                    }
                    Box(
                        modifier = Modifier.fillMaxWidth(),
                        contentAlignment = if (me) Alignment.CenterEnd else Alignment.CenterStart,
                    ) {
                        val radius = MaterialMetrics.BUBBLE_RADIUS.dp
                        val tail = 4.dp
                        Box(
                            Modifier
                                .widthIn(max = bubbleMax)
                                .background(
                                    color = if (me) {
                                        t.primaryContainer.toColor()
                                    } else {
                                        t.surfaceContainerHigh.toColor()
                                    },
                                    // The tail corner: bottom-right for "me",
                                    // bottom-left otherwise — L519-520.
                                    shape = RoundedCornerShape(
                                        topStart = radius,
                                        topEnd = radius,
                                        bottomEnd = if (me) tail else radius,
                                        bottomStart = if (me) radius else tail,
                                    ),
                                )
                                .padding(
                                    vertical = MaterialMetrics.BUBBLE_PADDING_VERTICAL.dp,
                                    horizontal = MaterialMetrics.BUBBLE_PADDING_HORIZONTAL.dp,
                                ),
                        ) {
                            Text(
                                text = message.field("text").reactText(),
                                color = if (me) {
                                    t.onPrimaryContainer.toColor()
                                } else {
                                    t.onSurface.toColor()
                                },
                                fontSize = MaterialMetrics.BUBBLE_FONT_SIZE.sp,
                                lineHeight = MaterialMetrics.BUBBLE_LINE_HEIGHT.sp,
                            )
                        }
                    }
                }
            }
        }
    }
}
