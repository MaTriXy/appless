package dev.appless.openuilang

/**
 * Batch (single-shot) parser over a complete program text
 * (spec/openui-lang.md §1 processing pipeline).
 *
 * The reference pipeline (the fixture generator and the app's Renderer) is the
 * *streaming* parser fed the full text once, so the batch parse is exactly a
 * fresh streaming parser plus one [set][StreamingParser.set] call. Mirrors
 * `OpenUIParser` in `ios/Packages/OpenUILang/Sources/OpenUILang/Parser.swift`.
 *
 * STUB: [parse] currently returns an empty [ParseResult] so the fixture-oracle
 * suite compiles and fails RED against every fixture.
 */
public class OpenUIParser(public val schema: LibrarySchema) {

    /** Parses a complete program. The text is taken verbatim — no trimming. */
    public fun parse(text: String): ParseResult {
        val core = StreamCore(schema)
        return Pipeline.run(core.set(text))
    }
}

/**
 * Streaming parser mirroring lang-core's `createStreamingParser` semantics
 * (spec/openui-lang.md §10 streaming semantics): call [set] with the full
 * accumulated text on every flush. When the new text is a prefix-extension of
 * the previous text, completed statements are reused from the cache and only
 * the pending tail is re-parsed; a non-extension resets. `isStreaming` never
 * changes parsing — partial text simply yields the auto-closed partial tree
 * with `meta.incomplete` set.
 *
 * STUB: [set] currently produces an empty [ParseResult].
 */
public class StreamingParser(public val schema: LibrarySchema) {
    private val core = StreamCore(schema)
    private var cachedResult: ParseResult = ParseResult()

    /**
     * Sets the full accumulated text and reparses (with prefix-extension
     * caching). Returns the new result, mirroring the JS `result = sp.set(text)`
     * shape.
     */
    public fun set(text: String): ParseResult {
        cachedResult = Pipeline.run(core.set(text))
        return cachedResult
    }

    /** The result of the most recent [set] pass. */
    public val result: ParseResult
        get() = cachedResult
}

/**
 * Internal per-pass output of the streaming core, before the Renderer pipeline
 * (store initialization + prop evaluation) turns it into a [ParseResult].
 * Mirrors `InternalResult` in the Swift port; the fields stay deliberately
 * close to lang-core's own shape.
 *
 * STUB shape: the real implementation carries materialized elements and
 * runtime values, not already-converted [PropValue]s.
 */
internal class InternalResult(
    val root: ElementNode? = null,
    val incomplete: Boolean = false,
    val unresolved: List<String> = emptyList(),
    val errors: List<ParseError> = emptyList(),
    val stateDeclarations: Map<String, PropValue> = emptyMap(),
)

/**
 * The tokenize -> parse -> materialize core with prefix-extension caching.
 *
 * CONTRACT the implementation must honor (spec/openui-lang.md §10):
 * - [set] always receives the FULL accumulated text, never a delta.
 * - When `text` starts with the previously-seen text (UTF-16 code-unit prefix
 *   test — see `StringJs.kt`), statements already completed in the cached
 *   prefix are reused verbatim and only the pending tail is re-tokenized.
 * - When it does not, the whole cache is discarded and the pass starts clean.
 * - Reusing the cache must never change the result versus a cold parse of the
 *   same text; that equivalence is what the streaming fixtures (partial/101-115)
 *   and the differential probes pin down.
 *
 * STUB: no caching, no parsing — every pass yields an empty [InternalResult].
 */
internal class StreamCore(@Suppress("unused") private val schema: LibrarySchema) {
    private var lastText: String = ""

    fun set(text: String): InternalResult {
        @Suppress("UNUSED_VARIABLE")
        val isPrefixExtension = jsStringHasPrefix(text, lastText)
        lastText = text
        return InternalResult()
    }
}

/**
 * Replays the app's steady-state Renderer pipeline on a parse result
 * (spec/openui-lang.md §1 processing pipeline, Appendix A result shapes):
 * initialize the state store from declarations, evaluate the root element's
 * props, and convert everything into the public (serializable) shapes.
 *
 * STUB: passes the (empty) internal result straight through.
 */
internal object Pipeline {
    fun run(internalResult: InternalResult): ParseResult = ParseResult(
        root = internalResult.root,
        meta = ParseMeta(
            incomplete = internalResult.incomplete,
            unresolved = internalResult.unresolved,
            errors = internalResult.errors,
        ),
        state = internalResult.stateDeclarations,
        // KNOWN-DEVIATION (mirrors the Swift port): the JS
        // `evaluateElementProps` errors array is only appended to from paths
        // AppLess never reaches (QueryManager/tool providers), and the oracle
        // emits [] across the whole corpus.
        runtimeErrors = emptyList(),
    )
}
