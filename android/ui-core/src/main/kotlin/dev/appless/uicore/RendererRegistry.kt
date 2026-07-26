package dev.appless.uicore

/**
 * The conformance harness: which contract components a design system must be
 * able to render, which ones it actually registered, and a report the tests
 * print as a CI gate.
 *
 * Deliberately free of Compose so the whole thing is exercisable headlessly —
 * registrations carry a type-erased `Any` payload that only the Compose layer
 * (and the on-device renderer tests) knows how to unwrap.
 *
 * Kotlin sibling of `ios/AppLess/Sources/AppLessCore/RendererRegistry.swift`,
 * with one deliberate difference: the renderable set is DERIVED from
 * [ContractSchema.renderableComponents] rather than restated as an enum, so it
 * cannot drift from the contract even in principle.
 */
@JvmInline
public value class RenderableComponent private constructor(
    /** Component name as it appears in the contract and in openui-lang source. */
    public val name: String,
) : Comparable<RenderableComponent> {

    /** Positional parameters, in openui-lang call order (`schema.paramOrder`). */
    public val paramOrder: List<ContractSchema.Param>
        get() = ContractSchema.paramOrder[name] ?: emptyList()

    override fun compareTo(other: RenderableComponent): Int = name.compareTo(other.name)

    override fun toString(): String = name

    public companion object {
        /**
         * Every component a conforming design system must supply a renderer
         * for — exactly [ContractSchema.renderableComponents] (the schema's 33
         * components minus the 3 structural placeholders), in schema order.
         */
        public val ALL: List<RenderableComponent> =
            ContractSchema.renderableComponents.map { RenderableComponent(it) }

        private val BY_NAME: Map<String, RenderableComponent> = ALL.associateBy { it.name }

        /**
         * The number of renderers the contract requires. Computed from the
         * schema, never typed by hand.
         */
        public val REQUIRED_COUNT: Int = ALL.size

        /** `null` for a name that is not a renderable contract component. */
        public fun of(name: String): RenderableComponent? = BY_NAME[name]

        /** Throws when `name` is not renderable — used by the named constants below. */
        public fun require(name: String): RenderableComponent =
            BY_NAME[name] ?: throw IllegalArgumentException(
                "\"$name\" is not a renderable contract component " +
                    "(known: ${ALL.joinToString(", ") { it.name }})"
            )
    }
}

/**
 * Named handles for the 30 renderable components, so the Compose layer can
 * write `Components.Card` instead of a string literal.
 *
 * These are LOOKUPS into the schema-derived set, not a second declaration of
 * it: if the contract ever drops a component, initializing this object throws
 * rather than silently disagreeing with [RenderableComponent.ALL].
 */
public object Components {
    // Structure
    public val Card: RenderableComponent = RenderableComponent.require("Card")
    public val CardHeader: RenderableComponent = RenderableComponent.require("CardHeader")
    public val TextContent: RenderableComponent = RenderableComponent.require("TextContent")
    public val TextCallout: RenderableComponent = RenderableComponent.require("TextCallout")

    // Lists
    public val ListBlock: RenderableComponent = RenderableComponent.require("ListBlock")
    public val ListItem: RenderableComponent = RenderableComponent.require("ListItem")
    public val Toggle: RenderableComponent = RenderableComponent.require("Toggle")
    public val KVList: RenderableComponent = RenderableComponent.require("KVList")

    // Stats & charts
    public val HeroStat: RenderableComponent = RenderableComponent.require("HeroStat")
    public val StatTiles: RenderableComponent = RenderableComponent.require("StatTiles")
    public val BarChart: RenderableComponent = RenderableComponent.require("BarChart")
    public val LineChart: RenderableComponent = RenderableComponent.require("LineChart")
    public val AreaChart: RenderableComponent = RenderableComponent.require("AreaChart")
    public val PieChart: RenderableComponent = RenderableComponent.require("PieChart")
    public val HorizontalBarChart: RenderableComponent = RenderableComponent.require("HorizontalBarChart")

    // Media & social
    public val ImageBlock: RenderableComponent = RenderableComponent.require("ImageBlock")
    public val PhotoGrid: RenderableComponent = RenderableComponent.require("PhotoGrid")
    public val Bubbles: RenderableComponent = RenderableComponent.require("Bubbles")
    public val Chips: RenderableComponent = RenderableComponent.require("Chips")
    public val Tabs: RenderableComponent = RenderableComponent.require("Tabs")
    public val MapView: RenderableComponent = RenderableComponent.require("MapView")

    // Forms & buttons
    public val Form: RenderableComponent = RenderableComponent.require("Form")
    public val FormControl: RenderableComponent = RenderableComponent.require("FormControl")
    public val Input: RenderableComponent = RenderableComponent.require("Input")
    public val TextArea: RenderableComponent = RenderableComponent.require("TextArea")
    public val Select: RenderableComponent = RenderableComponent.require("Select")
    public val DatePicker: RenderableComponent = RenderableComponent.require("DatePicker")
    public val Slider: RenderableComponent = RenderableComponent.require("Slider")
    public val Buttons: RenderableComponent = RenderableComponent.require("Buttons")
    public val Button: RenderableComponent = RenderableComponent.require("Button")

    /** Every named handle above — asserted equal to [RenderableComponent.ALL] in tests. */
    public val all: List<RenderableComponent> = listOf(
        Card, CardHeader, TextContent, TextCallout,
        ListBlock, ListItem, Toggle, KVList,
        HeroStat, StatTiles, BarChart, LineChart, AreaChart, PieChart, HorizontalBarChart,
        ImageBlock, PhotoGrid, Bubbles, Chips, Tabs, MapView,
        Form, FormControl, Input, TextArea, Select, DatePicker, Slider, Buttons, Button,
    )
}

/**
 * One design system's renderer for one component.
 *
 * [erasedRenderer] is `Any` because `ui-core` cannot name a Compose type; the
 * Compose layer stores its renderer lambda here and casts it back at render
 * time. Headless tests only ever look at the metadata.
 */
public data class RendererRegistration(
    public val component: RenderableComponent,
    /** Design system that supplied it, e.g. `"material"`. */
    public val designSystem: String,
    /**
     * Source location of the registering call site — shows up in the
     * conformance report so a missing renderer is easy to trace.
     */
    public val sourceFile: String,
    public val erasedRenderer: Any,
)

/**
 * Registry of the renderers a design system has wired up.
 *
 * The Compose layer calls [register] once per component at startup; tests call
 * [conformanceReport] to see what is missing.
 */
public class RendererRegistry(
    /** Design system this registry describes. */
    public val designSystem: String,
) {

    private val lock = Any()
    private val storage = LinkedHashMap<RenderableComponent, RendererRegistration>()

    /**
     * Register `renderer` for `component`.
     *
     * @return `false` if a renderer was already registered for that component
     * (the new one still wins — last registration applies, which is what a
     * design-system override needs); `true` on first registration.
     */
    public fun register(
        component: RenderableComponent,
        renderer: Any,
        designSystem: String = this.designSystem,
        sourceFile: String = "<unknown>",
    ): Boolean = synchronized(lock) {
        val isNew = !storage.containsKey(component)
        storage[component] = RendererRegistration(component, designSystem, sourceFile, renderer)
        isNew
    }

    /** Register many at once. */
    public fun registerAll(
        renderers: Map<RenderableComponent, Any>,
        designSystem: String = this.designSystem,
        sourceFile: String = "<unknown>",
    ) {
        for ((component, renderer) in renderers) {
            register(component, renderer, designSystem, sourceFile)
        }
    }

    public fun isRegistered(component: RenderableComponent): Boolean =
        synchronized(lock) { storage.containsKey(component) }

    /** The type-erased renderer for `component`, if any. */
    public fun renderer(component: RenderableComponent): Any? =
        synchronized(lock) { storage[component]?.erasedRenderer }

    public fun registration(component: RenderableComponent): RendererRegistration? =
        synchronized(lock) { storage[component] }

    /** Every registered component, sorted by name. */
    public val registeredComponents: List<RenderableComponent>
        get() = synchronized(lock) { storage.keys.sorted() }

    public val registeredCount: Int
        get() = synchronized(lock) { storage.size }

    /** Drop every registration — used by tests that need a clean registry. */
    public fun reset(): Unit = synchronized(lock) { storage.clear() }

    /** Snapshot of how complete this design system's renderer set is. */
    public fun conformanceReport(): ConformanceReport {
        val registered = registeredComponents
        val registeredSet = registered.toSet()
        return ConformanceReport(
            designSystem = designSystem,
            declared = RenderableComponent.ALL.sorted(),
            registered = registered,
            missing = RenderableComponent.ALL.sorted().filter { it !in registeredSet },
            registrations = registered.mapNotNull { registration(it) },
        )
    }

    public companion object {
        /** Registry the Android app and the conformance tests share. */
        public val shared: RendererRegistry = RendererRegistry(designSystem = "material")
    }
}

/** Result of comparing a registry against the contract. */
public data class ConformanceReport(
    /** Design system the report describes. */
    val designSystem: String,
    /** Every component the contract requires a renderer for (30). */
    val declared: List<RenderableComponent>,
    /** Components that actually have a renderer. */
    val registered: List<RenderableComponent>,
    /** [declared] minus [registered]. */
    val missing: List<RenderableComponent>,
    val registrations: List<RendererRegistration>,
) {
    /** The number of renderers the contract requires — the gate's denominator. */
    public val declaredCount: Int get() = declared.size

    /** The number of renderers wired up right now. */
    public val registeredCount: Int get() = registered.size

    public val isComplete: Boolean get() = missing.isEmpty()

    /**
     * CI gate line for the count actually wired up:
     * `renderers registered: 0/30` while the Compose layer is a stub,
     * `renderers registered: 30/30` once it is complete.
     */
    public val gateLine: String get() = "renderers registered: $registeredCount/$declaredCount"

    /**
     * CI gate line for the count the contract DECLARES.
     *
     * This scaffold prints it so the gate exists before the Compose renderers
     * are written (they need an Android device/Robolectric, so nothing can
     * register in this headless module); the renderers task switches the
     * assertion over to [gateLine] on instrumented CI, where the two must agree.
     */
    public val declaredGateLine: String get() = "renderers registered: $declaredCount/$declaredCount"

    /** Human-readable multi-line summary. */
    public fun formatted(): String {
        val lines = mutableListOf(
            gateLine,
            "design system: $designSystem",
            "contract components: ${ContractSchema.COMPONENT_COUNT} " +
                "(${ContractSchema.structuralPlaceholders.size} structural placeholders excluded)",
        )
        if (missing.isEmpty()) {
            lines += "missing: none"
        } else {
            lines += "missing (${missing.size}): " + missing.joinToString(", ") { it.name }
        }
        return lines.joinToString("\n")
    }
}
