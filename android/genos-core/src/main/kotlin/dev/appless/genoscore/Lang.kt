package dev.appless.genoscore

/**
 * App-level pure helpers, byte-exact ports of spec/openui-lang.md §11.
 * Reference: src/genos/store.ts, src/genos/GenOS.tsx.
 *
 * Every regex is audited against the ECMAScript semantics of the RN source
 * pattern (see [JsRegex] for the Java-vs-JS hazard table):
 * - JS `\s` / `[^\S\n]` are spelled via [JsRegex.WS] / [JsRegex.WS_NO_NEWLINE].
 * - JS `\w` is ASCII-only → spelled `[A-Za-z0-9_]`.
 * - JS `.` is spelled via [JsRegex.DOT].
 * - JS `i`-flag patterns are spelled with explicit case variants.
 * - JS `^`/`$` (no `m` flag) map to `\A`/`\z` (Java's `$` also matches before a
 *   final line terminator; JS's does not).
 * - JS `.trim()` maps to [jsTrim] (exact ECMAScript whitespace set).
 *
 * UTF-16 call sites (`slice`, `indexOf`, `startsWith`, `split`) are the native
 * Kotlin operations: a Kotlin `String` is UTF-16 like a JS string, so a
 * combining mark glued to an ASCII delimiter behaves identically. The Swift
 * port needed explicit shims for exactly these.
 */
public object Lang {
    private const val WS = JsRegex.WS
    private const val WS_NO_NL = JsRegex.WS_NO_NEWLINE
    private const val DOT = JsRegex.DOT

    /**
     * §11.1 — strip markdown fences the model may wrap around the program.
     * Safe on partial streams; the trailing cut only applies when an opening
     * fence was present.
     *
     * RN: `/^\s*```/` ; `/^\s*```[\w-]*[^\S\n]*\n?/` ; `` /\n```\s*$/ ``.
     * JS `[\w-]` is ASCII `[A-Za-z0-9_-]` — a Unicode-aware `\w` would also eat
     * letters like "é" (```` ```héllo ```` must strip only ` ```h `, leaving
     * "éllo").
     */
    public fun cleanLang(text: String): String {
        val opened = JsRegex.test("\\A$WS*```", text)
        var t = JsRegex.replaceFirst("\\A$WS*```[A-Za-z0-9_-]*$WS_NO_NL*\\n?", text, "")
        if (opened) {
            // RN: t.indexOf("\n```") + t.slice(0, end) — UTF-16, so a combining
            // mark glued onto the closing fence still matches. The cut lands on
            // the "\n" (ASCII), so it can never split a surrogate pair.
            val end = t.indexOf("\n```")
            if (end != -1) t = t.substring(0, end)
        } else {
            t = JsRegex.replaceFirst("\\n```$WS*\\z", t, "")
        }
        return t
    }

    /**
     * §11.2 — pull every `@ToAssistant("...")` message out of a complete
     * program: unescape by collapsing every backslash-pair, trim, drop empties,
     * dedupe preserving first-seen order.
     *
     * RN: `/@ToAssistant\(\s*"((?:\\.|[^"\\])*)"/g` and `/\\(.)/g`.
     */
    public fun extractActions(content: String): List<String> {
        val out = ArrayList<String>()
        val pattern = "@ToAssistant\\($WS*\"((?:\\\\$DOT|[^\"\\\\])*)\""
        for (match in JsRegex.all(pattern, content)) {
            val raw = match.getOrNull(1) ?: continue
            val msg = jsTrim(JsRegex.replaceAll("\\\\($DOT)", raw, "$1"))
            if (msg.isNotEmpty() && !out.contains(msg)) out.add(msg)
        }
        return out
    }

    /**
     * §11.3 — detect a whole-response `@OS(...)` command (nothing else in the
     * reply). Applied after [cleanLang] + trim; case-insensitive.
     *
     * RN: `/^@OS\(\s*(back|home|switcher|open)\s*(?:,\s*"([^"]+)")?\s*\)$/i`.
     * Case variants are spelled out rather than relying on a flag default, so
     * the ASCII-only folding JS performs is visible in the pattern.
     */
    public fun parseOsCommand(text: String): OSCommand? {
        val cleaned = jsTrim(cleanLang(text))
        val cmdAlt = "[Bb][Aa][Cc][Kk]|[Hh][Oo][Mm][Ee]|[Ss][Ww][Ii][Tt][Cc][Hh][Ee][Rr]|[Oo][Pp][Ee][Nn]"
        val pattern = "\\A@[Oo][Ss]\\($WS*($cmdAlt)$WS*(?:,$WS*\"([^\"]+)\")?$WS*\\)\\z"
        val m = JsRegex.first(pattern, cleaned) ?: return null
        val cmdText = m.getOrNull(1) ?: return null
        val cmd = OSCommandKind.from(cmdText.lowercase()) ?: return null
        return OSCommand(cmd = cmd, arg = m.getOrNull(2))
    }

    /**
     * §11.4 — hand-rolled `genos://cmd?key=value&...` parser. Command
     * lower-cased; key-only pair → value ""; value gets `+`→space then
     * percent-decoding; raw fallback on decode failure.
     *
     * RN: `/^genos:\/\/([a-z]+)\/?(?:\?(.*))?$/i`. Spelled case variants, and
     * [JsRegex.DOT] for `.*` (Java's `.` would reject a query containing U+0085,
     * which JS's `.` matches).
     */
    public fun parseGenosUrl(url: String): GenosUrl? {
        val pattern = "\\A[Gg][Ee][Nn][Oo][Ss]://([A-Za-z]+)/?(?:\\?($DOT*))?\\z"
        val m = JsRegex.first(pattern, url) ?: return null
        val cmd = m.getOrNull(1) ?: return null
        val params = LinkedHashMap<String, String>()
        val query = m.getOrNull(2) ?: ""
        // RN: query.split("&") / pair.indexOf("=") — Kotlin's split keeps empty
        // segments (java.lang.String.split would drop trailing ones) and both
        // operate on UTF-16 units, so this is JS-exact.
        for (pair in query.split('&')) {
            if (pair.isEmpty()) continue
            val eq = pair.indexOf('=')
            val key = if (eq == -1) pair else pair.substring(0, eq)
            val value = if (eq == -1) "" else pair.substring(eq + 1)
            // RN: v.replace(/\+/g, " ") before decoding.
            val plusDecoded = value.replace('+', ' ')
            val decodedKey = jsDecodeURIComponent(key)
            val decodedValue = jsDecodeURIComponent(plusDecoded)
            if (decodedKey != null && decodedValue != null) {
                params[decodedKey] = decodedValue
            } else {
                params[key] = value
            }
        }
        return GenosUrl(cmd = cmd.lowercase(), params = params)
    }

    /**
     * Rename gate for summoned apps: the adopted title from the FIRST screen's
     * first `CardHeader("...")`, only for `summon-` apps at stack depth exactly
     * 1. Null when the gate rejects or no title is found.
     *
     * RN: `/CardHeader\(\s*"((?:\\.|[^"\\])*)"/` then `m?.[1]?.trim()`.
     */
    public fun summonedAppTitle(appId: String, stackDepth: Int, content: String): String? {
        if (!appId.startsWith("summon-") || content.isEmpty() || stackDepth != 1) return null
        val pattern = "CardHeader\\($WS*\"((?:\\\\$DOT|[^\"\\\\])*)\""
        val m = JsRegex.first(pattern, cleanLang(content)) ?: return null
        val raw = m.getOrNull(1) ?: return null
        val title = jsTrim(raw)
        return title.ifEmpty { null }
    }
}

public data class GenosUrl(val cmd: String, val params: Map<String, String>)
