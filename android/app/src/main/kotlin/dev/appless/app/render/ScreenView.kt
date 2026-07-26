package dev.appless.app.render

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import dev.appless.genoscore.Lang
import dev.appless.openuilang.LibrarySchema
import dev.appless.openuilang.StreamingParser
import dev.appless.uicore.OrderedJson
import dev.appless.genoscore.JsonValue as CoreJson
import dev.appless.openuilang.JsonValue as LangJson

/**
 * `<Renderer response={cleanLang(top.content)} library={genosLibrary}
 * isStreaming={generating} onAction={handleAction} />` — `GenOS.tsx` L639-644.
 *
 * The parse itself is `:openui-lang`'s STREAMING parser fed the full
 * accumulated text on every flush, which is exactly what the RN reference does:
 * a prefix-extension reuses the cached completed statements and only re-parses
 * the pending tail, so a 3 KB screen is not re-parsed from scratch 60 times a
 * second.
 */
@Composable
public fun ScreenView(
    /** The raw accumulated openui-lang source (NOT yet fence-stripped). */
    content: String,
    isStreaming: Boolean,
    schema: LibrarySchema,
    formStore: FormStore,
    dispatcher: ActionDispatcher,
) {
    // One parser per mounted screen: its statement cache is what makes the
    // incremental re-parse cheap, so it must survive recomposition.
    val parser = remember(schema) { StreamingParser(schema) }

    // §11.1 — strip the markdown fence the model may have wrapped the program
    // in. Safe on a partial stream.
    val cleaned = remember(content) { Lang.cleanLang(content) }
    val result = remember(cleaned) { parser.set(cleaned) }

    CompositionLocalProvider(
        LocalFormStore provides formStore,
        LocalTriggerAction provides dispatcher,
        LocalIsStreaming provides isStreaming,
        // A screen starts OUTSIDE any form; `Form` re-provides this.
        LocalFormName provides null,
    ) {
        // `root == null` means no renderable root yet — the host shows its
        // skeleton, which is the caller's job.
        result.root?.let { RenderElement(it) }
    }
}

/**
 * `ev.formState` -> the ordered key/value list `GenOSController.resolveAction`
 * takes.
 *
 * The two modules carry two DIFFERENT `JsonValue` types on purpose —
 * `:openui-lang`'s belongs to the contract/prop world and `:genos-core`'s to
 * the wire world — and neither depends on the other. This is the only bridge.
 *
 * ## Key order
 *
 * The payload is serialized straight into the request
 * (`"\n\nSubmitted form values: " + JSON.stringify(formState)`,
 * `spec/openui-lang.md` §9.4 step 6), so its key ORDER is what the model reads
 * as the order of the form. React-lang holds that payload in a PLAIN JS OBJECT
 * (`store.set(formName, { ...formData, [name]: wrapped })` — react-lang
 * `hooks/useOpenUIState.js` `setFieldValue`), and `JSON.stringify` enumerates a
 * plain object with `OrdinaryOwnPropertyKeys` (ES 10.1.11.1), NOT with
 * insertion order alone.
 *
 * So insertion order is only most of the rule. [jsOwnKeyOrder] adds the rest.
 */
public fun OrderedJson.toControllerFormState(): List<Pair<String, CoreJson>> =
    jsOwnKeyOrder(pairs).map { (key, value) -> key to value.toCoreJson() }

private fun LangJson.toCoreJson(): CoreJson = when (this) {
    LangJson.Null -> CoreJson.Null
    is LangJson.Bool -> CoreJson.Bool(value)
    is LangJson.Num -> CoreJson.Num(value)
    is LangJson.Str -> CoreJson.Str(value)
    is LangJson.Arr -> CoreJson.Arr(value.map { it.toCoreJson() })
    is LangJson.Obj -> CoreJson.Obj(
        LinkedHashMap<String, CoreJson>().also { out ->
            for ((k, v) in jsOwnKeyOrder(value.entries.map { it.key to it.value })) {
                out[k] = v.toCoreJson()
            }
        },
    )
}

/**
 * `OrdinaryOwnPropertyKeys` (ES 10.1.11.1) applied to a plain object's entries
 * in insertion order: every **canonical array index** first, in ascending
 * NUMERIC order, then every remaining key in insertion order.
 *
 * A canonical array index is a string `k` with `ToString(ToUint32(k)) === k`
 * and `ToUint32(k) != 2^32 - 1` — a non-empty run of ASCII digits with no
 * redundant leading zero, valued at most `2^32 - 2`. So `"0"`, `"2"` and
 * `"4294967294"` are hoisted while `""`, `"01"`, `"-0"`, `"1.0"` and
 * `"4294967295"` are ordinary string keys.
 *
 * Concretely: a form whose fields are named `10`, `zeta`, `2` reaches the model
 * as `{"2":…,"10":…,"zeta":…}`, because that is what the RN app sends. Field
 * names are model-chosen, and a numbered questionnaire is exactly the shape the
 * system prompt encourages, so this is a live path rather than a curiosity.
 *
 * `:openui-lang` spells the same rule for the tree serializer
 * (`StringJs.jsOwnPropertyKeys`, pinned by
 * `spec/fixtures/075-object-key-index-order`), but it is `internal` to that
 * module; this is the form-state path's copy, in the module that owns the
 * bridge.
 */
private fun <T> jsOwnKeyOrder(entries: List<Pair<String, T>>): List<Pair<String, T>> {
    if (entries.none { canonicalArrayIndex(it.first) >= 0 }) return entries // the common case
    val indices = entries.filter { canonicalArrayIndex(it.first) >= 0 }
        .sortedBy { canonicalArrayIndex(it.first) }
    val rest = entries.filter { canonicalArrayIndex(it.first) < 0 }
    return indices + rest
}

/** The numeric value of a canonical array index, or `-1`. */
private fun canonicalArrayIndex(key: String): Long {
    val n = key.length
    if (n == 0 || n > 10) return -1 // "4294967294" is 10 digits
    if (key[0] == '0' && n > 1) return -1 // no redundant leading zeros
    var value = 0L
    for (c in key) {
        if (c < '0' || c > '9') return -1
        value = value * 10 + (c - '0')
    }
    return if (value > 4294967294L) -1 else value
}
