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
 * Intentional divergences from the JS reference implementation are enumerated
 * in this module's README.md under KNOWN-DEVIATIONS.
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
