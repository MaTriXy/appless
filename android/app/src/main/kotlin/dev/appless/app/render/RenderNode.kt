package dev.appless.app.render

import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import dev.appless.openuilang.ElementNode
import dev.appless.openuilang.PropValue
import dev.appless.uicore.RenderableComponent
import dev.appless.uicore.RendererRegistry

/**
 * `renderNode(value)` — react-lang's recursive child renderer.
 *
 * A prop slot can hold a single element, an array of them, or nothing; every
 * container renderer (`Card.children`, `ListBlock.items`, `Form.fields`,
 * `Buttons.buttons`, `TabItem.children`) hands its slot straight to this.
 */
@Composable
public fun RenderNode(value: PropValue?) {
    when (value) {
        null, PropValue.Null -> Unit
        is PropValue.Element -> RenderElement(value.node)
        is PropValue.Arr -> value.items.forEachIndexed { index, item ->
            // React keys children by index here; `key` gives the same identity
            // so a Toggle/Tabs/Chips local state survives a streaming re-parse.
            key(index) { RenderNode(item) }
        }
        // A bare string/number in a child slot is not renderable: RN throws
        // ("text strings must be rendered within a <Text>"). Dropping it is the
        // safe degradation for a partial stream.
        else -> Unit
    }
}

/**
 * Look the component up in the shared registry and draw it.
 *
 * Unknown components and the three structural placeholders (`Series`,
 * `SelectItem`, `TabItem` — consumed by their parents) resolve to nothing,
 * matching their `component: () => null` definitions in `ui/contract.tsx`.
 */
@Composable
public fun RenderElement(node: ElementNode) {
    val component = RenderableComponent.of(node.component) ?: return
    val renderer = RendererRegistry.shared.renderer(component) as? ComposeRenderer ?: return
    renderer.Render(node)
}
