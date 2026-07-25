import Foundation

/// App-level pure helpers, byte-exact ports of spec/openui-lang.md §11.
/// Reference: src/genos/store.ts, src/genos/GenOS.tsx.
public enum Lang {
    /// §11.1 - Strip markdown fences the model may wrap around the program.
    /// Safe on partial streams; the trailing cut only applies when an opening
    /// fence was present.
    public static func cleanLang(_ text: String) -> String {
        let opened = JSRegex.test(#"^\s*```"#, text)
        var t = JSRegex.replacingFirst(#"^\s*```[\w-]*[^\S\n]*\n?"#, in: text, with: "")
        if opened {
            if let end = t.range(of: "\n```") {
                t = String(t[..<end.lowerBound])
            }
        } else {
            t = JSRegex.replacingFirst(#"\n```\s*\z"#, in: t, with: "")
        }
        return t
    }

    /// §11.2 - Pull every @ToAssistant("...") message out of a complete
    /// program: unescape by collapsing every backslash-pair, trim, drop
    /// empties, dedupe preserving first-seen order.
    public static func extractActions(_ content: String) -> [String] {
        var out: [String] = []
        for match in JSRegex.all(#"@ToAssistant\(\s*"((?:\\.|[^"\\])*)""#, content) {
            guard let raw = match.count > 1 ? match[1] : nil else { continue }
            let msg = JSRegex.replacingAll(#"\\(.)"#, in: raw, with: "$1")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !msg.isEmpty, !out.contains(msg) {
                out.append(msg)
            }
        }
        return out
    }

    /// §11.3 - Detect a whole-response @OS(...) command (nothing else in the
    /// reply). Applied after cleanLang + trim; case-insensitive.
    public static func parseOsCommand(_ text: String) -> OSCommand? {
        let cleaned = cleanLang(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let m = JSRegex.first(
                #"\A@OS\(\s*(back|home|switcher|open)\s*(?:,\s*"([^"]+)")?\s*\)\z"#,
                cleaned,
                caseInsensitive: true
            ),
            let cmdText = m.count > 1 ? m[1] : nil,
            let cmd = OSCommandKind(rawValue: cmdText.lowercased())
        else { return nil }
        return OSCommand(cmd: cmd, arg: m.count > 2 ? m[2] : nil)
    }

    /// §11.4 - Hand-rolled genos://cmd?key=value&... parser. Command
    /// lower-cased; key-only pair → value ""; value gets +→space then
    /// percent-decoding; raw fallback on decode failure.
    public static func parseGenosUrl(_ url: String) -> GenosURL? {
        guard
            let m = JSRegex.first(#"\Agenos://([a-z]+)/?(?:\?(.*))?\z"#, url, caseInsensitive: true),
            let cmd = m.count > 1 ? m[1] : nil
        else { return nil }
        var params: [String: String] = [:]
        let query = (m.count > 2 ? m[2] : nil) ?? ""
        for pair in query.components(separatedBy: "&") {
            if pair.isEmpty { continue }
            let key: String
            let value: String
            if let eq = pair.range(of: "=") {
                key = String(pair[..<eq.lowerBound])
                value = String(pair[eq.upperBound...])
            } else {
                key = pair
                value = ""
            }
            let plusDecoded = value.replacingOccurrences(of: "+", with: " ")
            if let decodedKey = jsDecodeURIComponent(key), let decodedValue = jsDecodeURIComponent(plusDecoded) {
                params[decodedKey] = decodedValue
            } else {
                params[key] = value
            }
        }
        return GenosURL(cmd: cmd.lowercased(), params: params)
    }

    /// Rename gate for summoned apps: the adopted title from the FIRST
    /// screen's first CardHeader("..."), only for summon- apps at stack
    /// depth exactly 1. Returns nil when the gate rejects or no title found.
    /// Reference: GenOS.tsx rename effect + capabilities.md "Summoned apps".
    public static func summonedAppTitle(appId: String, stackDepth: Int, content: String) -> String? {
        guard appId.hasPrefix("summon-"), !content.isEmpty, stackDepth == 1 else { return nil }
        guard
            let m = JSRegex.first(#"CardHeader\(\s*"((?:\\.|[^"\\])*)""#, cleanLang(content)),
            let raw = m.count > 1 ? m[1] : nil
        else { return nil }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
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
