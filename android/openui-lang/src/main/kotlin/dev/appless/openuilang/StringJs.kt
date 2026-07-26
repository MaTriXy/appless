package dev.appless.openuilang

/**
 * JS string-semantics helpers.
 *
 * Kotlin/JVM `String` is a UTF-16 code-unit sequence, exactly like a JS string
 * — `==`, `compareTo`, `startsWith`, `indexOf` and `HashMap` keys are all
 * already code-unit exact. That is a real advantage over the Swift port, whose
 * `String` compares by Unicode *canonical equivalence* and therefore needs a
 * whole `StringJS.swift` shim (precomposed NFC and decomposed NFD `"cafe"` are `==` in Swift but `!==` in JS; fixture 072 exercises
 * exactly that). These wrappers exist so the two ports read the same and so
 * the JS-semantics intent stays explicit at each call site — they are
 * deliberately thin.
 *
 * What does NOT transfer for free, and must be spelled out when the lexer and
 * builtins land:
 *
 * - `Char.isWhitespace()` / `\s` in `java.util.regex` do not match the JS
 *   `\s` set (JS includes U+00A0, U+FEFF and the Unicode `Zs` category and
 *   treats U+2028/U+2029 as line terminators; Java's `\s` is ASCII-only unless
 *   `UNICODE_CHARACTER_CLASS` is set, and even then differs). Spell out
 *   explicit character classes, like the Swift `JSRegex`/`StringJS` files do.
 * - Java regex `.` excludes a different line-terminator set than JS, and
 *   `CASE_INSENSITIVE` is ASCII-only unless `UNICODE_CASE` is set — while JS
 *   `/i` uses simple case folding. Prefer hand-written code-unit scanners.
 * - `String.toUpperCase()`/`toLowerCase()` are locale-sensitive on the JVM;
 *   always pass `Locale.ROOT` when a JS `toUpperCase()` is being mirrored.
 */

/** JS string equality (`===`): UTF-16 code-unit equality. Native on the JVM. */
internal fun jsStringEquals(x: String, y: String): Boolean = x == y

/** JS `String.prototype.includes`: contiguous UTF-16 code-unit search. */
internal fun jsStringContains(hay: String, needle: String): Boolean = hay.contains(needle)

/**
 * JS default string ordering (`Array.prototype.sort()` over `Object.keys`):
 * UTF-16 code-unit lexicographic order. `String.compareTo` on the JVM compares
 * `char` values, i.e. UTF-16 code units — identical to JS.
 */
internal fun jsStringLess(x: String, y: String): Boolean = x < y

/** Comparator form of [jsStringLess], for `sortedWith`. */
internal val JS_STRING_ORDER: Comparator<String> = Comparator { a, b -> a.compareTo(b) }

/** JS `String.prototype.startsWith`: UTF-16 code-unit prefix test. */
internal fun jsStringHasPrefix(s: String, prefix: String): Boolean = s.startsWith(prefix)

/**
 * JS `String.prototype.split(separator)` for a single separator: keeps empty
 * segments (`"a..b".split(".")` -> `["a", "", "b"]`). Kotlin's `split` already
 * keeps them (limit 0 means "no limit", NOT "drop trailing empties" the way
 * `java.lang.String.split` does) — this wrapper exists to make that explicit,
 * because the `java.lang.String.split` trap is easy to fall into.
 */
internal fun jsStringSplit(s: String, separator: Char): List<String> =
    s.split(separator)
