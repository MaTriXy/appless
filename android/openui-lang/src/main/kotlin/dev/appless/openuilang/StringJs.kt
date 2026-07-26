package dev.appless.openuilang

/**
 * JS string-semantics helpers.
 *
 * Kotlin/JVM `String` is a UTF-16 code-unit sequence, exactly like a JS string
 * — `==`, `compareTo`, `startsWith`, `indexOf` and `HashMap` keys are all
 * already code-unit exact. That is a real advantage over the Swift port, whose
 * `String` compares by Unicode *canonical equivalence* and therefore needs a
 * whole `StringJS.swift` shim (precomposed NFC and decomposed NFD `"cafe"` are
 * `==` in Swift but `!==` in JS; fixture 072 exercises exactly that). So this
 * file carries only the helpers that encode semantics the JVM does NOT give
 * for free; the operations that ARE native (`===`, `includes`, `startsWith`,
 * `<`) are used directly at their call sites rather than wrapped.
 *
 * What does NOT transfer for free:
 *
 * - `Char.isWhitespace()` / `\s` in `java.util.regex` do not match the JS
 *   `\s` set (JS includes U+00A0, U+FEFF and the Unicode `Zs` category and
 *   treats U+2028/U+2029 as line terminators; Java's `\s` is ASCII-only unless
 *   `UNICODE_CHARACTER_CLASS` is set, and even then adds U+0085 NEL, which JS
 *   does not treat as whitespace). `Preprocess.kt` spells out an explicit
 *   character class, like the Swift `StringJS`/`Preprocess` files do.
 * - Java regex `.` excludes a different line-terminator set than JS, and
 *   `CASE_INSENSITIVE` is ASCII-only unless `UNICODE_CASE` is set — while JS
 *   `/i` uses simple case folding. Prefer hand-written code-unit scanners.
 * - `String.toUpperCase()`/`toLowerCase()` are locale-sensitive on the JVM;
 *   always pass `Locale.ROOT` when a JS `toUpperCase()` is being mirrored.
 * - `java.lang.String.split` drops trailing empty segments; JS does not — see
 *   [jsStringSplit].
 * - `Object.keys(o).sort()` is NOT the order `JSON.stringify(o)` emits — see
 *   [JS_OWN_KEY_ORDER].
 */

/**
 * JS default string ordering (`Array.prototype.sort()` with no comparator):
 * UTF-16 code-unit lexicographic order. `String.compareTo` on the JVM compares
 * `char` values, i.e. UTF-16 code units — identical to JS.
 */
internal val JS_STRING_ORDER: Comparator<String> = Comparator { a, b -> a.compareTo(b) }

/** Largest canonical array index: 2^32 - 2. `"4294967295"` is NOT an index. */
private const val MAX_ARRAY_INDEX: Long = 4294967294L

/**
 * The numeric value of `key` when it is a *canonical array index*, else `-1`.
 *
 * A canonical array index is a String `k` with `ToString(ToUint32(k)) === k`
 * and `ToUint32(k) != 2^32 - 1` (ECMAScript "array index", 6.1.7). In practice:
 * a non-empty run of ASCII digits with no redundant leading zero, whose value
 * is at most [MAX_ARRAY_INDEX]. So `"0"`, `"2"`, `"4294967294"` qualify while
 * `""`, `"01"`, `"-0"`, `"+1"`, `"1.0"`, `" 1"` and `"4294967295"` do not.
 */
internal fun jsCanonicalArrayIndex(key: String): Long {
    val n = key.length
    if (n == 0 || n > 10) return -1 // "4294967294" is 10 digits
    if (key[0] == '0' && n > 1) return -1 // no redundant leading zeros
    var value = 0L
    for (i in 0 until n) {
        val c = key[i]
        if (c < '0' || c > '9') return -1
        value = value * 10 + (c - '0')
    }
    return if (value > MAX_ARRAY_INDEX) -1 else value
}

/**
 * The order `JSON.stringify` emits an object's own keys in — i.e. what the
 * reference serializer (`spec/fixtures/generator/lib/serialize.mjs`) actually
 * produces.
 *
 * That serializer does `Object.keys(v).sort()` and re-inserts every key into a
 * FRESH plain object. A flat code-unit sort is therefore only half the story:
 * `JSON.stringify` walks `OrdinaryOwnPropertyKeys` (ES 10.1.11.1), which emits
 * every **canonical array index** first, in ascending NUMERIC order, and only
 * then the remaining string keys in insertion (here: sorted) order. So for
 * `{"-dash":1,"10":2,"2":3,"alpha":4," space":5,"":6,"+plus":7,"0":8,
 * "$usd":9,"(paren)":10,"4294967294":11,"4294967295":12}` node emits
 * `"0","2","10","4294967294"` BEFORE `""," space","$usd","(paren)","+plus",
 * "-dash","4294967295","alpha"` — note `"10"` after `"2"` (numeric, not
 * lexicographic) and `"4294967295"` demoted to the string group because it is
 * out of array-index range.
 *
 * Expressed as a total order, that is exactly: indices before non-indices,
 * indices by numeric value, non-indices by UTF-16 code units.
 */
internal val JS_OWN_KEY_ORDER: Comparator<String> = Comparator { a, b ->
    val ia = jsCanonicalArrayIndex(a)
    val ib = jsCanonicalArrayIndex(b)
    when {
        ia >= 0 && ib >= 0 -> ia.compareTo(ib)
        ia >= 0 -> -1
        ib >= 0 -> 1
        else -> a.compareTo(b)
    }
}

/**
 * `OrdinaryOwnPropertyKeys` (ES 10.1.11.1) applied to a plain object's keys in
 * INSERTION order — i.e. exactly what JS `Object.keys(o)` / `for…in` yields:
 * every canonical array index first in ascending NUMERIC order, then every
 * remaining string key in insertion order.
 *
 * NOT the same as [JS_OWN_KEY_ORDER], which additionally sorts the string group
 * because the reference SERIALIZER sorts before re-inserting. Public iteration
 * accessors want this one; the serializer wants that one.
 */
internal fun jsOwnPropertyKeys(insertionOrder: List<String>): List<String> {
    var hasIndex = false
    for (k in insertionOrder) {
        if (jsCanonicalArrayIndex(k) >= 0) {
            hasIndex = true
            break
        }
    }
    if (!hasIndex) return insertionOrder // overwhelmingly the common case
    val indices = ArrayList<Pair<Long, String>>()
    val rest = ArrayList<String>()
    for (k in insertionOrder) {
        val i = jsCanonicalArrayIndex(k)
        if (i >= 0) indices.add(i to k) else rest.add(k)
    }
    indices.sortBy { it.first }
    return indices.map { it.second } + rest
}

/**
 * JS `String.prototype.split(separator)` for a single separator: keeps empty
 * segments (`"a..b".split(".")` -> `["a", "", "b"]`). Kotlin's `split` already
 * keeps them (limit 0 means "no limit", NOT "drop trailing empties" the way
 * `java.lang.String.split` does) — this wrapper exists to make that explicit,
 * because the `java.lang.String.split` trap is easy to fall into.
 */
internal fun jsStringSplit(s: String, separator: Char): List<String> =
    s.split(separator)
