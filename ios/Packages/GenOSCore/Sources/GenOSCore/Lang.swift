import Foundation

/// App-level pure helpers, byte-exact ports of spec/openui-lang.md §11.
/// Reference: src/genos/store.ts, src/genos/GenOS.tsx.
///
/// Every regex below is audited against the ECMAScript semantics of the RN
/// source pattern (see JSRegex.swift for the ICU-vs-JS hazard table):
/// - JS `\s` / `[^\S\n]` are spelled via `JSRegex.jsWS` / `jsWSNoNewline`.
/// - JS `\w` is ASCII-only → spelled `[A-Za-z0-9_]`.
/// - JS `.` is spelled via `JSRegex.jsDot`.
/// - JS `i`-flag patterns are spelled with explicit case variants (ICU's
///   case-insensitivity uses full case folding, JS's does not).
/// - JS `^`/`$` (no `m` flag) map to ICU `^`/`\z` (ICU `$` also matches
///   before a final line terminator, JS `$` does not).
/// - JS `.trim()` maps to `jsTrim` (exact ECMAScript whitespace set).
public enum Lang {
    private static let ws = JSRegex.jsWS
    private static let wsNoNL = JSRegex.jsWSNoNewline
    private static let dot = JSRegex.jsDot

    /// §11.1 - Strip markdown fences the model may wrap around the program.
    /// Safe on partial streams; the trailing cut only applies when an opening
    /// fence was present.
    ///
    /// RN: /^\s*```/ ; /^\s*```[\w-]*[^\S\n]*\n?/ ; /\n```\s*$/.
    /// JS `[\w-]` is ASCII `[A-Za-z0-9_-]`; ICU `\w` would also eat letters
    /// like "é" ('```héllo' must strip only '```h', leaving 'éllo').
    public static func cleanLang(_ text: String) -> String {
        let opened = JSRegex.test("^\(ws)*```", text)
        var t = JSRegex.replacingFirst("^\(ws)*```[A-Za-z0-9_-]*\(wsNoNL)*\\n?", in: text, with: "")
        if opened {
            if let end = t.range(of: "\n```") {
                t = String(t[..<end.lowerBound])
            }
        } else {
            t = JSRegex.replacingFirst("\\n```\(ws)*\\z", in: t, with: "")
        }
        return t
    }

    /// §11.2 - Pull every @ToAssistant("...") message out of a complete
    /// program: unescape by collapsing every backslash-pair, trim, drop
    /// empties, dedupe preserving first-seen order.
    ///
    /// RN: /@ToAssistant\(\s*"((?:\\.|[^"\\])*)"/g and /\\(.)/g.
    public static func extractActions(_ content: String) -> [String] {
        var out: [String] = []
        for match in JSRegex.all("@ToAssistant\\(\(ws)*\"((?:\\\\\(dot)|[^\"\\\\])*)\"", content) {
            guard let raw = match.count > 1 ? match[1] : nil else { continue }
            let msg = jsTrim(JSRegex.replacingAll("\\\\(\(dot))", in: raw, with: "$1"))
            if !msg.isEmpty, !out.contains(msg) {
                out.append(msg)
            }
        }
        return out
    }

    /// §11.3 - Detect a whole-response @OS(...) command (nothing else in the
    /// reply). Applied after cleanLang + trim; case-insensitive.
    ///
    /// RN: /^@OS\(\s*(back|home|switcher|open)\s*(?:,\s*"([^"]+)")?\s*\)$/i.
    /// Case variants are spelled out instead of using ICU's `i` flag: ICU
    /// case folding would also accept U+212A (KELVIN) for "k" and U+017F
    /// (LONG S) for "s", which JS's `i` (no `u` flag) rejects.
    public static func parseOsCommand(_ text: String) -> OSCommand? {
        let cleaned = jsTrim(cleanLang(text))
        let cmdAlt = "[Bb][Aa][Cc][Kk]|[Hh][Oo][Mm][Ee]|[Ss][Ww][Ii][Tt][Cc][Hh][Ee][Rr]|[Oo][Pp][Ee][Nn]"
        guard
            let m = JSRegex.first(
                "\\A@[Oo][Ss]\\(\(ws)*(\(cmdAlt))\(ws)*(?:,\(ws)*\"([^\"]+)\")?\(ws)*\\)\\z",
                cleaned
            ),
            let cmdText = m.count > 1 ? m[1] : nil,
            let cmd = OSCommandKind(rawValue: cmdText.lowercased())
        else { return nil }
        return OSCommand(cmd: cmd, arg: m.count > 2 ? m[2] : nil)
    }

    /// §11.4 - Hand-rolled genos://cmd?key=value&... parser. Command
    /// lower-cased; key-only pair → value ""; value gets +→space then
    /// percent-decoding; raw fallback on decode failure.
    ///
    /// RN: /^genos:\/\/([a-z]+)\/?(?:\?(.*))?$/i. Spelled case variants (no
    /// ICU `i` full folding) and `jsDot` for `.*` (ICU's `.` would reject a
    /// query containing \v, \f or U+0085, which JS's `.` matches).
    public static func parseGenosUrl(_ url: String) -> GenosURL? {
        guard
            let m = JSRegex.first(
                "\\A[Gg][Ee][Nn][Oo][Ss]://([A-Za-z]+)/?(?:\\?(\(dot)*))?\\z",
                url
            ),
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
    ///
    /// RN: /CardHeader\(\s*"((?:\\.|[^"\\])*)"/ then m?.[1]?.trim().
    public static func summonedAppTitle(appId: String, stackDepth: Int, content: String) -> String? {
        guard appId.hasPrefix("summon-"), !content.isEmpty, stackDepth == 1 else { return nil }
        guard
            let m = JSRegex.first("CardHeader\\(\(ws)*\"((?:\\\\\(dot)|[^\"\\\\])*)\"", cleanLang(content)),
            let raw = m.count > 1 ? m[1] : nil
        else { return nil }
        let title = jsTrim(raw)
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
