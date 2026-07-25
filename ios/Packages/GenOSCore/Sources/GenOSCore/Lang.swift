import Foundation

/// App-level pure helpers, byte-exact ports of spec/openui-lang.md §11.
/// Reference: src/genos/store.ts, src/genos/GenOS.tsx.
public enum Lang {
    /// §11.1 - Strip markdown fences the model may wrap around the program.
    /// Safe on partial streams; the trailing cut only applies when an opening
    /// fence was present.
    public static func cleanLang(_ text: String) -> String {
        "" // STUB
    }

    /// §11.2 - Pull every @ToAssistant("...") message out of a complete
    /// program: unescape by collapsing every backslash-pair, trim, drop
    /// empties, dedupe preserving first-seen order.
    public static func extractActions(_ content: String) -> [String] {
        [] // STUB
    }

    /// §11.3 - Detect a whole-response @OS(...) command (nothing else in the
    /// reply). Applied after cleanLang + trim; case-insensitive.
    public static func parseOsCommand(_ text: String) -> OSCommand? {
        nil // STUB
    }

    /// §11.4 - Hand-rolled genos://cmd?key=value&... parser. Command
    /// lower-cased; key-only pair → value ""; value gets +→space then
    /// percent-decoding; raw fallback on decode failure.
    public static func parseGenosUrl(_ url: String) -> GenosURL? {
        nil // STUB
    }

    /// Rename gate for summoned apps: the adopted title from the FIRST
    /// screen's first CardHeader("..."), only for summon- apps at stack
    /// depth exactly 1. Returns nil when the gate rejects or no title found.
    /// Reference: GenOS.tsx rename effect + capabilities.md "Summoned apps".
    public static func summonedAppTitle(appId: String, stackDepth: Int, content: String) -> String? {
        nil // STUB
    }
}

public struct GenosURL: Sendable, Equatable {
    public var cmd: String
    public var params: [String: String]

    public init(cmd: String, params: [String: String]) {
        self.cmd = cmd
        self.params = params
    }
}
