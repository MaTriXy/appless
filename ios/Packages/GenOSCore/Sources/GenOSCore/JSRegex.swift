import Foundation

/// Thin NSRegularExpression wrapper matching the JS regex call-sites ported
/// in this package. Capture groups come back as `nil` when unmatched.
///
/// ICU vs ECMAScript shorthand-class hazards (why the constants below exist):
/// - `\w`/`\d` are Unicode-aware in ICU but ASCII-only in JS (no `u` flag).
///   Ported patterns must spell `[A-Za-z0-9_]` / `[0-9]`.
/// - `\s` in JS is WhiteSpace ∪ LineTerminator = \t \n \v \f \r U+FEFF
///   \p{Z} U+2028 U+2029. ICU's `\s` is only [\t\n\f\r\p{Z}]: it misses
///   U+000B (VT) and U+FEFF (BOM). Use `jsWS`.
/// - `.` in JS (no `s` flag) excludes exactly \n \r U+2028 U+2029. ICU's `.`
///   additionally excludes U+000B, U+000C and U+0085. Use `jsDot`.
/// - ICU case-insensitive matching uses full Unicode case folding, so `i`
///   patterns match U+212A (KELVIN SIGN → k) and U+017F (LONG S → s) where JS
///   (no `u` flag) does not. Ported `i` patterns spell case variants instead.
enum JSRegex {
    /// ECMAScript `\s` member set, ICU-spelled (see hazards above).
    static let jsWSMembers = #"\t\n\x{B}\f\r\p{Z}\x{FEFF}"#
    /// ECMAScript `\s` as a character class.
    static let jsWS = "[" + jsWSMembers + "]"
    /// ECMAScript `[^\S\n]` (whitespace except newline).
    static let jsWSNoNewline = #"[\t\x{B}\f\r\p{Z}\x{FEFF}]"#
    /// ECMAScript `.` (anything but \n \r U+2028 U+2029).
    static let jsDot = #"[^\n\r\x{2028}\x{2029}]"#

    static func compile(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        // Patterns are compile-time constants in this package; a failure here
        // is a programmer error caught by the test suite.
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func groups(_ match: NSTextCheckingResult, in text: String) -> [String?] {
        let ns = text as NSString
        return (0..<match.numberOfRanges).map { i in
            let r = match.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    /// `text.match(re)` (non-global): whole match + captures, or nil.
    static func first(_ pattern: String, _ text: String, caseInsensitive: Bool = false) -> [String?]? {
        let re = compile(pattern, caseInsensitive: caseInsensitive)
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range) else { return nil }
        return groups(m, in: text)
    }

    /// Global scan: every match's whole text + captures.
    static func all(_ pattern: String, _ text: String) -> [[String?]] {
        let re = compile(pattern)
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).map { groups($0, in: text) }
    }

    /// `text.replace(re, replacement)` for a NON-global regex: first match only.
    static func replacingFirst(_ pattern: String, in text: String, with template: String) -> String {
        let re = compile(pattern)
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = re.firstMatch(in: text, range: range) else { return text }
        let replaced = re.replacementString(for: m, in: text, offset: 0, template: template)
        return ns.replacingCharacters(in: m.range, with: replaced)
    }

    /// `text.replace(re, replacement)` for a GLOBAL regex.
    static func replacingAll(_ pattern: String, in text: String, with template: String) -> String {
        let re = compile(pattern)
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// `re.test(text)`.
    static func test(_ pattern: String, _ text: String, caseInsensitive: Bool = false) -> Bool {
        first(pattern, text, caseInsensitive: caseInsensitive) != nil
    }
}

/// JS `String.prototype.trim()`: strips the exact ECMAScript whitespace set.
/// Foundation's `.whitespacesAndNewlines` diverges (it strips U+0085, which
/// JS keeps, and keeps U+FEFF, which JS strips), so ported `.trim()` call
/// sites use this instead.
func jsTrim(_ s: String) -> String {
    JSRegex.replacingAll("\\A\(JSRegex.jsWS)+|\(JSRegex.jsWS)+\\z", in: s, with: "")
}

/// `decodeURIComponent` analog: nil on malformed percent-escapes (the JS
/// function throws there). Pinned by tests: a dangling "%" ("a%20%") and
/// percent-encoded lone surrogates ("%ED%A0%80") both return nil, matching
/// decodeURIComponent's URIError on the same inputs.
func jsDecodeURIComponent(_ s: String) -> String? {
    s.removingPercentEncoding
}

// MARK: - JS string-primitive analogs (UTF-16 / scalar semantics)
//
// JS string operations work on UTF-16 code units; Swift's default String
// operations work on grapheme Characters. The two diverge whenever a
// combining mark follows an ASCII delimiter ("&\u{301}" is ONE Character but
// two UTF-16 units) or when "\r\n" is involved (one Character, two units).
// For ASCII delimiters/needles, scalar-level matching is exactly equivalent
// to JS's UTF-16 matching, because an ASCII code unit can never appear
// inside a surrogate pair or a multi-unit scalar.

/// JS `s.split(sep)` for a single ASCII separator: scalar-level split,
/// keeping empty subsequences (JS keeps them too). Verified to yield
/// ["a\r", "b"] for "a\r\nb" like JS, where Character-level splitting sees
/// "\r\n" as one grapheme and does not split at all.
func jsSplit(_ s: String, on separator: Unicode.Scalar) -> [String] {
    s.unicodeScalars
        .split(separator: separator, omittingEmptySubsequences: false)
        .map { String($0) }
}

/// JS `pair.indexOf(sep)` + `slice(0, eq)` / `slice(eq + 1)` for an ASCII
/// separator: split at the FIRST occurrence, scalar-level. Returns nil when
/// the separator is absent (JS indexOf === -1). Character-level
/// `range(of:)` would miss a separator glued to a following combining mark.
func jsSplitFirst(_ s: String, on separator: Unicode.Scalar) -> (before: String, after: String)? {
    let scalars = s.unicodeScalars
    guard let idx = scalars.firstIndex(of: separator) else { return nil }
    return (
        before: String(scalars[..<idx]),
        after: String(scalars[scalars.index(after: idx)...])
    )
}

/// JS `s.startsWith(prefix)` for an ASCII prefix: scalar-level, so a
/// combining mark straight after the prefix ("data:\u{301}…", "/api/img\u{301}?…")
/// does not defeat the match the way Character-level hasPrefix does.
func jsHasPrefix(_ s: String, _ prefix: String) -> Bool {
    s.unicodeScalars.starts(with: prefix.unicodeScalars)
}

/// JS `s.slice(0, end)` in UTF-16 code units. A slice that splits a
/// surrogate pair leaves JS holding a lone surrogate, which becomes U+FFFD
/// the moment the string is UTF-8-encoded (HTTP body, JSON) - Swift cannot
/// hold the lone surrogate, so it materializes that same U+FFFD here.
func jsSlice(_ s: String, upTo end: Int) -> String {
    let units = Array(s.utf16)
    guard units.count > end else { return s }
    return String(decoding: units[..<max(0, end)], as: UTF16.self)
}

/// JS `s.slice(start)` in UTF-16 code units (same lone-surrogate → U+FFFD
/// note as `jsSlice(_:upTo:)`).
func jsSlice(_ s: String, from start: Int) -> String {
    let units = Array(s.utf16)
    guard start < units.count else { return "" }
    return String(decoding: units[max(0, start)...], as: UTF16.self)
}

/// JS `s.indexOf(needle)` in UTF-16 code units (nil for -1). Used with
/// ASCII needles, where a Character-level `range(of:)` would miss a match
/// whose last unit is glued to a following combining mark ("\n```\u{301}").
func jsUTF16Index(of needle: String, in s: String) -> Int? {
    let hay = Array(s.utf16)
    let ned = Array(needle.utf16)
    guard !ned.isEmpty else { return 0 }
    guard hay.count >= ned.count else { return nil }
    for i in 0...(hay.count - ned.count) where hay[i] == ned[0] {
        if !zip(hay[i..<(i + ned.count)], ned).contains(where: { $0 != $1 }) {
            return i
        }
    }
    return nil
}

/// ECMAScript StrWhiteSpace membership (WhiteSpace ∪ LineTerminator - the
/// same set as `jsTrim`/`jsWS`, scalar-level): \t \n \v \f \r U+FEFF,
/// U+2028, U+2029 and every \p{Zs} space separator (U+0020, U+00A0, …).
func isJSWhiteSpace(_ c: Unicode.Scalar) -> Bool {
    switch c {
    case "\t", "\n", "\u{0B}", "\u{0C}", "\r", "\u{2028}", "\u{2029}", "\u{FEFF}":
        return true
    default:
        return c.properties.generalCategory == .spaceSeparator
    }
}

/// `encodeURIComponent` analog: everything but A-Za-z0-9 -_.!~*'() escaped.
func jsEncodeURIComponent(_ s: String) -> String {
    let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
    )
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

/// JS `parseInt(s, 10)`: skips the FULL StrWhiteSpace set (same set as
/// trim - includes NBSP, U+2028/29, U+FEFF), then optional sign + leading
/// decimal digits. Returns .nan when no digits (JS NaN). The digit run is
/// converted through Double (JS Number semantics), so long runs saturate
/// instead of failing: a 23-digit seed → ~1.23e22 (correctly rounded, like
/// JS), hundreds of digits → +Infinity - both clamp downstream exactly as
/// in RN instead of collapsing to the NaN path.
func jsParseInt(_ s: String) -> Double {
    var scalars = Substring(s).unicodeScalars[...]
    while let c = scalars.first, isJSWhiteSpace(c) {
        scalars = scalars.dropFirst()
    }
    var negative = false
    if let c = scalars.first, c == "+" || c == "-" {
        negative = c == "-"
        scalars = scalars.dropFirst()
    }
    var digits = ""
    while let c = scalars.first, ("0"..."9").contains(c) {
        digits.unicodeScalars.append(c)
        scalars = scalars.dropFirst()
    }
    guard !digits.isEmpty, let magnitude = Double(digits) else { return .nan }
    return negative ? -magnitude : magnitude
}

/// JS `String(value)` for tool-call argument coercion (`args.query ?? ""`).
func jsStringCoerce(_ value: JSONValue?) -> String {
    switch value {
    case .none, .some(.null): return ""
    case .some(.string(let s)): return s
    case .some(.number(let n)): return JSONValue.numberString(n)
    case .some(.bool(let b)): return b ? "true" : "false"
    case .some(.array), .some(.object): return value!.stringified()
    }
}
