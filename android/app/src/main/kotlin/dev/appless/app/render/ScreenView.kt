package dev.appless.app.render

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import dev.appless.genoscore.Lang
import dev.appless.openuilang.LibrarySchema
import dev.appless.openuilang.StreamingParser
import dev.appless.uicore.JsonWriter
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
 * the wire world — and neither depends on the other. This is the only bridge,
 * and it preserves key order, which the request JSON depends on (fields must
 * reach the model in UI order).
 */
public fun OrderedJson.toControllerFormState(): List<Pair<String, CoreJson>> =
    pairs.map { (key, value) -> key to value.toCoreJson() }

private fun LangJson.toCoreJson(): CoreJson = when (this) {
    LangJson.Null -> CoreJson.Null
    is LangJson.Bool -> CoreJson.Bool(value)
    is LangJson.Num -> CoreJson.Num(value)
    is LangJson.Str -> CoreJson.Str(value)
    is LangJson.Arr -> CoreJson.Arr(value.map { it.toCoreJson() })
    // LinkedHashMap in, LinkedHashMap out: insertion order IS the payload order.
    is LangJson.Obj -> CoreJson.Obj(
        LinkedHashMap<String, CoreJson>().also { out ->
            for ((k, v) in value) out[k] = v.toCoreJson()
        },
    )
}

/** `JSON.stringify(formState)` — used by the toast/debug paths and tests. */
public fun OrderedJson.stringify(): String = stringified()

/** Re-exported so callers do not reach into `ui-core` for one function. */
public fun jsonNumber(value: Double): String = JsonWriter.number(value)
