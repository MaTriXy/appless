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
