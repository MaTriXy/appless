package dev.appless.app.render

import dev.appless.openuilang.ActionPlan
import dev.appless.openuilang.ElementNode
import dev.appless.openuilang.PropValue
import dev.appless.uicore.JsonWriter

/**
 * Reading resolved props the way React/RN reads them.
 *
 * The renderers are a port of JSX, so the coercions have to be JS's, not
 * Kotlin's: `{props.title}` stringifies a number and renders NOTHING for a
 * boolean or null, `!!props.subtitle` is JS truthiness (empty string and 0 are
 * falsy), and `(props.rows ?? []).filter(Boolean)` drops falsy entries.
 *
 * Every accessor here exists because a renderer body in the `material` renderer set uses
 * that exact idiom.
 */

/** `node.props[name]`. */
public operator fun ElementNode.get(name: String): PropValue? = props[name]

/**
 * What React puts on screen for `{value}`.
 *
 * Strings pass through; numbers stringify with JS number formatting; `null`,
 * `undefined` and BOOLEANS render as nothing (React skips them); arrays and
 * objects are not renderable text and render as nothing here rather than
 * throwing the way RN would.
 */
public fun PropValue?.reactText(): String = when (this) {
    null, PropValue.Null -> ""
    is PropValue.Str -> value
    is PropValue.Num -> JsonWriter.number(value).let {
        // JSON.stringify writes non-finite as null; String() spells them out.
        if (value.isFinite()) it else if (value.isNaN()) "NaN" else if (value > 0) "Infinity" else "-Infinity"
    }
    else -> ""
}

/**
 * JS truthiness — what `!!props.x` and `.filter(Boolean)` test.
 *
 * Falsy: absent, `null`, `false`, `0`, `NaN`, `""`. Everything else (including
 * an EMPTY array or object, which JS considers truthy) is true.
 */
public fun PropValue?.isTruthy(): Boolean = when (this) {
    null, PropValue.Null -> false
    is PropValue.Bool -> value
    is PropValue.Num -> value != 0.0 && !value.isNaN()
    is PropValue.Str -> value.isNotEmpty()
    else -> true
}

/** The value only when it really is a string (`typeof x === "string"`). */
public fun PropValue?.stringOrNull(): String? = (this as? PropValue.Str)?.value

/** The value only when it really is a number (`typeof x === "number"`). */
public fun PropValue?.numberOrNull(): Double? = (this as? PropValue.Num)?.value

/** `props.rows ?? 4` for an integer-ish prop; non-numbers fall through to null. */
public fun PropValue?.intOrNull(): Int? = numberOrNull()?.let {
    if (it.isFinite()) it.toInt() else null
}

/** The value only when it really is a boolean. */
public fun PropValue?.boolOrNull(): Boolean? = (this as? PropValue.Bool)?.value

/** `Array.isArray(x) ? x : []`. */
public fun PropValue?.items(): List<PropValue> = (this as? PropValue.Arr)?.items ?: emptyList()

/** `(x ?? []).filter(Boolean)` — the guard every list-shaped renderer applies. */
public fun PropValue?.truthyItems(): List<PropValue> = items().filter { it.isTruthy() }

/** A list of strings, dropping non-strings — `props.labels` / `PieChart.labels`. */
public fun PropValue?.stringItems(): List<String> = items().mapNotNull { it.stringOrNull() }

/**
 * The own properties of a plain object prop, or of an evaluated element node.
 *
 * The parser hands inline object literals back as [PropValue.Obj] and evaluated
 * child components (`Series`, `SelectItem`, `TabItem`) as [PropValue.Element];
 * RN reads `s.props` for the latter, so both shapes collapse here.
 */
public fun PropValue?.objectProps(): Map<String, PropValue>? = when (this) {
    is PropValue.Obj -> entries.entries.toMap()
    is PropValue.Element -> node.props
    else -> null
}

/** Convenience: one key out of [objectProps]. */
public fun PropValue?.field(name: String): PropValue? = objectProps()?.get(name)

/** `props.action` as a plan; `null` makes the element inert (`useTap`). */
public fun PropValue?.actionPlan(): ActionPlan? = (this as? PropValue.Action)?.plan

/**
 * The `children` slot of an evaluated child element.
 *
 * The parser keeps `children` OUT of [ElementNode.props] (it is a structural
 * slot, not a named prop), while react-lang's evaluated node carries it inside
 * `props` — so `it.props?.children` in `components.tsx` reads through here.
 */
public fun PropValue?.childrenSlot(): PropValue? = when (this) {
    is PropValue.Element -> node.children
    is PropValue.Obj -> entries["children"]
    else -> null
}
