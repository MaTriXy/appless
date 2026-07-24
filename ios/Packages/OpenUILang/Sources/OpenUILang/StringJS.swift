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

/// JS default string ordering (`Array.prototype.sort()` on `Object.keys`):
/// UTF-16 code-unit lexicographic less-than.
func jsStringLess(_ x: String, _ y: String) -> Bool {
    x.utf16.lexicographicallyPrecedes(y.utf16)
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
