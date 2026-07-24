import Foundation

/// Batch (single-shot) parser over a complete program text
/// (spec/openui-lang.md §1 processing pipeline).
///
/// The reference pipeline (the fixture generator and the app's Renderer) is
/// the *streaming* parser fed the full text once, so the batch parse is
/// exactly a fresh streaming parser plus one `set(_:)` call.
///
/// Intentional divergences from the JS reference implementation are
/// enumerated in this package's README.md under KNOWN-DEVIATIONS.
public struct OpenUIParser: Sendable {
    public let schema: LibrarySchema

    public init(schema: LibrarySchema) {
        self.schema = schema
    }

    /// Parses a complete program. The text is taken verbatim — no trimming.
    public func parse(_ text: String) -> ParseResult {
        let core = StreamCore(schema: schema)
        return Pipeline.run(core.set(text))
    }
}

/// Streaming parser mirroring lang-core's `createStreamingParser` semantics
/// (spec/openui-lang.md §10 streaming semantics):
/// call `set(_:)` with the full accumulated text on every flush. When the new
/// text is a prefix-extension of the previous text, completed statements are
/// reused from the cache and only the pending tail is re-parsed; a
/// non-extension resets. `isStreaming` never changes parsing — partial text
/// simply yields the auto-closed partial tree with `meta.incomplete` set.
public final class StreamingParser {
    public let schema: LibrarySchema

    private let core: StreamCore
    private var cachedResult: ParseResult = ParseResult()

    public init(schema: LibrarySchema) {
        self.schema = schema
        self.core = StreamCore(schema: schema)
    }

    /// Sets the full accumulated text and reparses (with prefix-extension
    /// caching). Returns the new result, mirroring the JS
    /// `result = sp.set(text)` shape.
    @discardableResult
    public func set(_ text: String) -> ParseResult {
        cachedResult = Pipeline.run(core.set(text))
        return cachedResult
    }

    /// The result of the most recent `set(_:)` pass.
    public var result: ParseResult {
        cachedResult
    }
}
