import Foundation

/// JS string-semantics helpers.
///
/// JavaScript compares strings by UTF-16 code units, while Swift's `String`
/// (`==`, `<`, `hasPrefix`, `Dictionary` keys) uses Unicode *canonical
/// equivalence* — precomposed `"caf\u{E9}"` and decomposed `"cafe\u{301}"`
/// are `==` in Swift but `!==` in JS. Every comparison whose operands can
/// carry program-derived text must go through these helpers so the port
/// stays byte-compatible with the reference implementation.

/// UTF-16 code unit of an ASCII scalar — comparison constant for the
/// code-unit scanners (lexer, statement scanner, fence stripper). JS's
/// `src[i] === "x"` compares single UTF-16 code units; scanning Swift
/// `[Character]` (grapheme clusters) instead diverges on CRLF ("\r\n" is ONE
/// Character) and on combining marks (which glue onto the previous cluster so
/// `c == "\""` etc. never fire).
@inline(__always)
func ascii16(_ scalar: Unicode.Scalar) -> UInt16 {
    assert(scalar.isASCII)
    return UInt16(truncatingIfNeeded: scalar.value)
}

/// JS string equality (`===`, and `==` when both operands are strings):
/// UTF-16 code-unit equality.
func jsStringEquals(_ x: String, _ y: String) -> Bool {
    x.utf16.elementsEqual(y.utf16)
}

/// JS `String.prototype.includes`: contiguous UTF-16 code-unit subsequence
/// search. An empty needle is always contained.
func jsStringContains(_ hay: String, _ needle: String) -> Bool {
    let h = Array(hay.utf16)
    let n = Array(needle.utf16)
    if n.isEmpty { return true }
    guard n.count <= h.count else { return false }
    for start in 0...(h.count - n.count) {
        var k = 0
        while k < n.count, h[start + k] == n[k] { k += 1 }
        if k == n.count { return true }
    }
    return false
}

/// JS default string ordering (`Array.prototype.sort()` with no comparator):
/// UTF-16 code-unit lexicographic less-than.
func jsStringLess(_ x: String, _ y: String) -> Bool {
    x.utf16.lexicographicallyPrecedes(y.utf16)
}

/// Largest canonical array index: 2^32 - 2. `"4294967295"` is NOT an index.
private let maxArrayIndex: UInt32 = 4_294_967_294

/// The numeric value of `key` when it is a *canonical array index*, else `nil`.
///
/// A canonical array index is a String `k` with `ToString(ToUint32(k)) === k`
/// and `ToUint32(k) != 2^32 - 1` (ECMAScript "array index", 6.1.7). In
/// practice: a non-empty run of ASCII digits with no redundant leading zero,
/// whose value is at most `maxArrayIndex`. So `"0"`, `"2"`, `"4294967294"`
/// qualify while `""`, `"01"`, `"-0"`, `"+1"`, `"1.0"`, `" 1"` and
/// `"4294967295"` do not.
func jsCanonicalArrayIndex(_ key: String) -> UInt32? {
    let units = key.utf16
    let count = units.count
    guard count > 0, count <= 10 else { return nil } // "4294967294" is 10 digits
    var value: UInt64 = 0
    var isFirst = true
    for unit in units {
        guard unit >= 0x30, unit <= 0x39 else { return nil }
        if isFirst, unit == 0x30, count > 1 { return nil } // leading zero
        isFirst = false
        value = value * 10 + UInt64(unit - 0x30)
    }
    return value > UInt64(maxArrayIndex) ? nil : UInt32(value)
}

/// The order `JSON.stringify` emits an object's own keys in — i.e. what the
/// reference serializer (`spec/fixtures/generator/lib/serialize.mjs`) actually
/// produces.
///
/// That serializer does `Object.keys(v).sort()` and re-inserts every key into
/// a FRESH plain object. A flat code-unit sort is therefore only half the
/// story: `JSON.stringify` walks `OrdinaryOwnPropertyKeys` (ES 10.1.11.1),
/// which emits every **canonical array index** first, in ascending NUMERIC
/// order, and only then the remaining string keys in insertion (here: sorted)
/// order. So for
/// `{"-dash":1,"10":2,"2":3,"alpha":4," space":5,"":6,"+plus":7,"0":8,
/// "$usd":9,"(paren)":10,"4294967294":11,"4294967295":12}` node emits
/// `"0","2","10","4294967294"` BEFORE `""," space","$usd","(paren)","+plus",
/// "-dash","4294967295","alpha"` — note `"10"` after `"2"` (numeric, not
/// lexicographic) and `"4294967295"` demoted to the string group because it is
/// out of array-index range.
///
/// Expressed as a strict weak ordering, that is exactly: indices before
/// non-indices, indices by numeric value, non-indices by UTF-16 code units.
func jsOwnKeyLess(_ x: String, _ y: String) -> Bool {
    switch (jsCanonicalArrayIndex(x), jsCanonicalArrayIndex(y)) {
    case (.some(let a), .some(let b)): return a < b
    case (.some, .none): return true
    case (.none, .some): return false
    case (.none, .none): return jsStringLess(x, y)
    }
}

/// `OrdinaryOwnPropertyKeys` (ES 10.1.11.1) applied to a plain object's keys in
/// INSERTION order — i.e. exactly what JS `Object.keys(o)` / `for…in` yields:
/// every canonical array index first in ascending NUMERIC order, then every
/// remaining string key in insertion order.
///
/// NOT the same as `jsOwnKeyLess`, which additionally sorts the string group
/// because the reference SERIALIZER sorts before re-inserting. Public iteration
/// accessors want this one; the serializer wants that one.
func jsOwnPropertyKeys(_ insertionOrder: [String]) -> [String] {
    guard insertionOrder.contains(where: { jsCanonicalArrayIndex($0) != nil }) else {
        return insertionOrder  // overwhelmingly the common case
    }
    var indices: [(UInt32, String)] = []
    var rest: [String] = []
    for k in insertionOrder {
        if let i = jsCanonicalArrayIndex(k) {
            indices.append((i, k))
        } else {
            rest.append(k)
        }
    }
    indices.sort { $0.0 < $1.0 }
    return indices.map { $0.1 } + rest
}

// MARK: - Collation (`String.prototype.localeCompare`)

/// Primary collation weights for the ASCII range, in CLDR root ("ducet")
/// PRIMARY order with `alternate = non-ignorable` — which is what V8's
/// `localeCompare` uses by default, and therefore what `@Sort` must reproduce.
///
/// The order below is not invented: it is `[...asciiChars].sort((a, b) =>
/// a.localeCompare(b))` read straight out of V8, with the case pairs collapsed
/// (`a`/`A` share ONE primary weight and are separated only at the tertiary
/// level). Index = code unit; value = weight; `0` = *completely ignorable*
/// (the C0 controls other than TAB/LF/VT/FF/CR, plus DEL, which carry no
/// weights at any level and are skipped entirely).
///
/// Reading it out loud: controls that DO sort (TAB, LF, VT, FF, CR), space,
/// `_ - , ; : ! ? . ' " ( ) [ ] { } @ * / \ & # % ` ^ + < = > | ~ $`, the ten
/// digits, then the 26 letters. Byte-identical to the Kotlin port's twin table.
private let asciiPrimaryWeight: [Int] = {
    var w = [Int](repeating: 0, count: 128)
    let order: [UInt8] = [
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20,
        0x5F, 0x2D, 0x2C, 0x3B, 0x3A, 0x21, 0x3F, 0x2E, 0x27, 0x22,  // _ - , ; : ! ? . ' "
        0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x40, 0x2A, 0x2F, 0x5C,  // ( ) [ ] { } @ * / \
        0x26, 0x23, 0x25, 0x60, 0x5E, 0x2B, 0x3C, 0x3D, 0x3E, 0x7C,  // & # % ` ^ + < = > |
        0x7E, 0x24,                                                   // ~ $
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,  // 0-9
    ]
    var rank = 1
    for c in order {
        w[Int(c)] = rank
        rank += 1
    }
    for i in 0..<26 {
        w[0x61 + i] = rank  // a-z
        w[0x41 + i] = rank  // A-Z
        rank += 1
    }
    return w
}()

/// `String.prototype.localeCompare` restricted to the ASCII range, implemented
/// as the Unicode Collation Algorithm with the `asciiPrimaryWeight` table:
/// compare the primary weight sequences (ignorables removed), then break ties
/// on the tertiary (case) sequence — lowercase before uppercase. Default ICU
/// strength is tertiary, so equal there means equal; there is no
/// identical-level tie-break.
///
/// Returns `nil` when either operand leaves the range this table covers, so the
/// caller can fall back.
///
/// Verified against V8 over 235,233 pairs drawn from the full 0x00–0x7F
/// alphabet (strings up to length 8, plus a hand-picked adversarial set:
/// `"a-b"/"ab"`, `" s"/"1"`, `"a b c"/"ab"`, `"a-b"/"a.b"`,
/// `"-0"/"[object Object]"`, `"co-op"/"coop"`, mixed case, repeated
/// separators) — zero mismatches.
func jsASCIILocaleCompare(_ a: String, _ b: String) -> Int? {
    func weights(_ s: String) -> (primary: [Int], tertiary: [Int])? {
        var primary: [Int] = []
        var tertiary: [Int] = []
        primary.reserveCapacity(s.utf16.count)
        tertiary.reserveCapacity(s.utf16.count)
        for unit in s.utf16 {
            if unit > 127 { return nil }
            let w = asciiPrimaryWeight[Int(unit)]
            if w == 0 { continue }  // completely ignorable
            primary.append(w)
            tertiary.append(unit >= 0x41 && unit <= 0x5A ? 1 : 0)
        }
        return (primary, tertiary)
    }

    guard let wa = weights(a), let wb = weights(b) else { return nil }
    let n = min(wa.primary.count, wb.primary.count)
    for i in 0..<n where wa.primary[i] != wb.primary[i] {
        return wa.primary[i] < wb.primary[i] ? -1 : 1
    }
    if wa.primary.count != wb.primary.count {
        return wa.primary.count < wb.primary.count ? -1 : 1
    }
    for i in 0..<n where wa.tertiary[i] != wb.tertiary[i] {
        return wa.tertiary[i] < wb.tertiary[i] ? -1 : 1
    }
    return 0
}

/// JS `String.prototype.startsWith`: UTF-16 code-unit prefix test (Swift's
/// `hasPrefix` matches canonically and would accept an NFC/NFD variant).
func jsStringHasPrefix(_ s: String, _ prefix: String) -> Bool {
    s.utf16.starts(with: prefix.utf16)
}

/// JS `String.prototype.split(separator)` for a single ASCII separator,
/// applied over UTF-16 code units. Keeps empty segments, exactly like JS
/// (`"a..b".split(".")` → `["a", "", "b"]`). Character-based splitting would
/// let a combining mark straight after the separator glue onto it and hide
/// the split point.
func jsStringSplit(_ s: String, separator: Unicode.Scalar) -> [String] {
    precondition(separator.isASCII)
    let sep = UInt16(separator.value)
    var parts: [String] = []
    var current: [UInt16] = []
    for unit in s.utf16 {
        if unit == sep {
            parts.append(String(decoding: current, as: UTF16.self))
            current = []
        } else {
            current.append(unit)
        }
    }
    parts.append(String(decoding: current, as: UTF16.self))
    return parts
}

/// Dictionary key with JS (UTF-16 code-unit) identity, for maps whose keys
/// are program-derived strings. JS object properties and `Map` keys are
/// code-unit exact; a Swift `[String: _]` would collide canonically-equal
/// keys that JS keeps distinct.
struct JSKey: Hashable {
    let string: String

    init(_ string: String) {
        self.string = string
    }

    static func == (a: JSKey, b: JSKey) -> Bool {
        jsStringEquals(a.string, b.string)
    }

    func hash(into hasher: inout Hasher) {
        for unit in string.utf16 {
            hasher.combine(unit)
        }
    }
}
