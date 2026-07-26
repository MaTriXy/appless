package dev.appless.app.compose

import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.junit4.ComposeContentTestRule
import androidx.test.core.app.ApplicationProvider
import dev.appless.app.render.ActionDispatcher
import dev.appless.app.render.FormStore
import dev.appless.app.render.LocalFormName
import dev.appless.app.render.LocalIsStreaming
import dev.appless.app.render.LocalTriggerAction
import dev.appless.app.render.RenderElement
import dev.appless.app.render.material.MaterialRenderers
import dev.appless.app.theme.AppLessTheme
import dev.appless.openuilang.ElementNode
import dev.appless.openuilang.LibrarySchema
import dev.appless.openuilang.PropValue
import dev.appless.openuilang.StreamingParser
import dev.appless.uicore.ActionEvent
import android.app.Application

/**
 * Shared plumbing for the Compose UI tier.
 *
 * Everything here exists so a test can say "compose THIS element and look at
 * what came out" without repeating the registry/theme/context boilerplate. The
 * three things it deliberately does NOT fake:
 *
 *  * the contract — [schema] is `spec/contract/genos.schema.json` read out of
 *    the app's own merged ASSETS, the same bytes the APK ships, so a contract
 *    the parser cannot load fails here before it fails on a phone;
 *  * the parser — [parseScreen] runs the real [StreamingParser], so props reach
 *    the renderers through the real positional-argument mapping and the real
 *    prop evaluation, not through hand-built maps;
 *  * the registry — [renderer] resolution goes through `RendererRegistry`, the
 *    same lookup `RenderElement` performs in production.
 */
object Harness {

    /**
     * The shipped contract, loaded from assets.
     *
     * `MainActivity.loadContractSchema` throws when the asset is missing; so
     * does this, for the same reason — a silently absent contract would turn
     * every renderer test into a no-op that still reports green.
     */
    val schema: LibrarySchema by lazy {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val text = context.assets.open("genos.schema.json")
            .use { it.readBytes().toString(Charsets.UTF_8) }
        LibrarySchema.parse(text)
    }

    init {
        // `AppLessApplication.onCreate` does this before the first composition;
        // Robolectric instantiates the manifest Application too, but a test that
        // constructs the harness directly must not depend on that ordering.
        MaterialRenderers.register()
    }

    /**
     * Parse one openui-lang program the way `ScreenView` does and return its
     * root, or `null` when there is no renderable root yet.
     */
    fun parseScreen(source: String): ElementNode? = StreamingParser(schema).set(source).root

    /** Like [parseScreen] but fails loudly — for programs a test believes are valid. */
    fun screen(source: String): ElementNode =
        parseScreen(source) ?: error("program produced no renderable root:\n$source")

    /**
     * `root = Card([x])` + `x = <expression>` — the smallest program that puts
     * one component on screen, and the shape the model itself emits (the system
     * prompt's "write `root = Card(...)` first" rule).
     */
    fun cardWith(expression: String, extra: String = ""): ElementNode =
        screen("root = Card([x])\nx = $expression\n$extra")

    /** The single child of a `Card`-rooted program built by [cardWith]. */
    fun soleChild(root: ElementNode): ElementNode {
        val items = (root.children as? PropValue.Arr)?.items
            ?: error("Card children were not an array: ${root.children}")
        return (items.single() as? PropValue.Element)?.node
            ?: error("Card's child was not an element: ${items.single()}")
    }
}

/** Every [ActionEvent] a composition dispatched, in order. */
class RecordingActions {
    val events: MutableList<ActionEvent> = mutableListOf()
    val store: FormStore = FormStore()
    val dispatcher: ActionDispatcher = ActionDispatcher(store) { events += it }

    val last: ActionEvent get() = events.lastOrNull() ?: error("no action was dispatched")
}

/**
 * Compose [node] under the app's real theme and renderer contexts.
 *
 * `Column` rather than a bare call because several renderers use
 * `Modifier.weight`/`alignByBaseline`, which need a row/column scope — exactly
 * the scope `Card` gives them in production.
 */
fun ComposeContentTestRule.renderNode(
    node: ElementNode,
    actions: RecordingActions = RecordingActions(),
    isStreaming: Boolean = false,
    formName: String? = null,
) {
    setContent {
        AppLessTheme(dark = false) {
            CompositionLocalProvider(
                dev.appless.app.render.LocalFormStore provides actions.store,
                LocalTriggerAction provides actions.dispatcher,
                LocalIsStreaming provides isStreaming,
                LocalFormName provides formName,
            ) {
                Column { RenderElement(node) }
            }
        }
    }
}

/** [renderNode] for a whole `root = Card(...)` program. */
fun ComposeContentTestRule.renderProgram(
    source: String,
    actions: RecordingActions = RecordingActions(),
): RecordingActions {
    renderNode(Harness.screen(source), actions)
    return actions
}

/** Compose an arbitrary tree under the app theme (for non-renderer composables). */
fun ComposeContentTestRule.setThemedContent(content: @Composable () -> Unit) {
    setContent { AppLessTheme(dark = false) { content() } }
}

/**
 * A composition whose element can be SWAPPED, for tests that sweep many nodes.
 *
 * `setContent` may be called only once per rule, so a loop over 30 components
 * cannot simply re-set it. Each [show] bumps a generation counter used as a
 * `key`, which tears the previous subtree down completely — otherwise a
 * renderer's `remember`ed state (a `Toggle`'s override, a `Tabs`' active index)
 * would leak into the next iteration and quietly weaken the assertions.
 */
class NodeHost(private val rule: ComposeContentTestRule) {

    val actions: RecordingActions = RecordingActions()

    private var generation by mutableIntStateOf(0)
    private var current by mutableStateOf<ElementNode?>(null)

    init {
        rule.setContent {
            AppLessTheme(dark = false) {
                CompositionLocalProvider(
                    dev.appless.app.render.LocalFormStore provides actions.store,
                    LocalTriggerAction provides actions.dispatcher,
                    LocalIsStreaming provides false,
                    LocalFormName provides null,
                ) {
                    key(generation) {
                        Column { current?.let { RenderElement(it) } }
                    }
                }
            }
        }
    }

    /**
     * Replace the composed element and settle the composition.
     *
     * ### The hazard `waitForIdle` carries
     *
     * `waitForIdle` pumps frames until the composition reports idle. A
     * composition that never settles therefore hangs the test JVM rather than
     * failing it — and a renderer CAN be pushed into that state by a hostile
     * prop: Compose's `Slider` given a non-finite bound animates its thumb
     * toward NaN forever. That is a real defect (100% CPU on a phone), so it is
     * fixed at the source (`Props.finiteOrNull`, applied in `SliderRenderer`)
     * rather than papered over here, and
     * `RendererHostileInputTest.a_slider_with_non_finite_bounds_settles`
     * is the named regression test for it.
     *
     * Driving the clock by hand instead was tried and rejected: with
     * `mainClock.autoAdvance = false`, a state write that adds a NEW layout node
     * never reaches the semantics tree, so every content assertion silently
     * reads an empty tree — a test tier that certifies rather than probes,
     * which is worse than a hang. The build-level backstop is the `timeout` on
     * the `Test` task in `app/build.gradle.kts`.
     */
    fun show(node: ElementNode?) {
        current = null
        generation += 1
        rule.waitForIdle()
        current = node
        rule.waitForIdle()
    }
}

/**
 * Every string the composition put in the semantics tree, in tree order.
 *
 * The renderers set no content descriptions (icons pass `null`, matching the RN
 * source), so `Text` is the whole of the observable output — which makes this
 * the sharpest available assertion for "did anything actually get drawn".
 */
fun ComposeContentTestRule.renderedText(): List<String> =
    onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsProperties.Text), useUnmergedTree = true)
        .fetchSemanticsNodes()
        .flatMap { node ->
            node.config.getOrNull(SemanticsProperties.Text).orEmpty().map { it.text }
        }
