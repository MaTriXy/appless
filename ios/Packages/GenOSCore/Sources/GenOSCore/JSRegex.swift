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

/// `decodeURIComponent` analog: nil where the JS function throws `URIError`.
///
/// Hand-rolled per the spec's `Decode` (ES 19.2.6.5) rather than delegating to
/// Foundation's `removingPercentEncoding`, which SWALLOWS a decoded leading
/// BOM: `"%EF%BB%BF"` came back as `""` and `"%EF%BB%BFa"` as `"a"`, while a
/// MID-string BOM survived - a position-dependent character loss RN and the
/// Kotlin port do not have. This is a direct port of Kotlin's `jsDecodeURIComponent`.
///
/// Strict like the spec: a dangling `%`, a non-hex escape, a truncated or
/// invalid UTF-8 continuation, an overlong encoding, a percent-encoded
/// surrogate (`%ED%A0%80`) and anything above U+10FFFF all fail - so the
/// ported call sites take the same raw-fallback branch RN's `catch` takes.
func jsDecodeURIComponent(_ s: String) -> String? {
    // UTF-16 units, like the JS string this ports: an index into the sequence
    // is what `Decode` walks, and every character it inspects is ASCII.
    let units = Array(s.utf16)
    var out = String.UnicodeScalarView()
    var i = 0

    func hexDigit(_ unit: UInt16) -> Int? {
        switch unit {
        case 0x30...0x39: return Int(unit - 0x30) // 0-9
        case 0x61...0x66: return Int(unit - 0x61 + 10) // a-f
        case 0x41...0x46: return Int(unit - 0x41 + 10) // A-F
        default: return nil
        }
    }

    /// The byte at `%XX` starting at `at`, or nil when it is not a `%` escape.
    func escapedByte(at: Int) -> Int? {
        guard at + 2 < units.count, units[at] == 0x25 else { return nil } // '%'
        guard let hi = hexDigit(units[at + 1]), let lo = hexDigit(units[at + 2]) else { return nil }
        return (hi << 4) | lo
    }

    while i < units.count {
        let unit = units[i]
        if unit != 0x25 { // not '%'
            // Copy the UTF-16 unit through. A lone surrogate here cannot be
            // represented in Swift; JS would keep it and degrade it to U+FFFD
            // at UTF-8-encode time, so degrade it now (same net result).
            if (0xD800...0xDBFF).contains(unit), i + 1 < units.count,
               (0xDC00...0xDFFF).contains(units[i + 1]) {
                let combined = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(units[i + 1]) - 0xDC00)
                out.append(Unicode.Scalar(combined) ?? "\u{FFFD}")
                i += 2
                continue
            }
            out.append((0xD800...0xDFFF).contains(unit) ? "\u{FFFD}" : Unicode.Scalar(unit)!)
            i += 1
            continue
        }

        guard let lead = escapedByte(at: i) else { return nil }
        i += 3
        if lead < 0x80 {
            out.append(Unicode.Scalar(UInt32(lead))!)
            continue
        }
        // The number of leading 1-bits gives the sequence length.
        var n = 0
        var probe = lead
        while probe & 0x80 != 0 {
            n += 1
            probe = (probe << 1) & 0xFF
        }
        guard n >= 2, n <= 4 else { return nil }
        var value = UInt32(lead & (0xFF >> (n + 1)))
        for _ in 1..<n {
            guard let byte = escapedByte(at: i), byte & 0xC0 == 0x80 else { return nil }
            value = (value << 6) | UInt32(byte & 0x3F)
            i += 3
        }
        if n == 2 && value < 0x80 { return nil }
        if n == 3 && value < 0x800 { return nil }
        if n == 4 && value < 0x10000 { return nil }
        if value > 0x10FFFF { return nil }
        if (0xD800...0xDFFF).contains(value) { return nil }
        out.append(Unicode.Scalar(value)!)
    }
    return String(out)
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

/// JS `Math.round(x)`: the integral Number closest to `x`, ties going toward
/// +INFINITY. NOT Swift's `.rounded()` (`.toNearestOrAwayFromZero`), which
/// breaks ties away from zero and so returns -1 for -0.5 and -3 for -2.5
/// where JS returns -0 and -2.
///
/// Implemented as floor + exact fractional-part comparison rather than the
/// textbook `floor(x + 0.5)`: the addition itself rounds, so `floor(x + 0.5)`
/// answers 1 for 0.49999999999999994 where `Math.round` answers 0. `x - floor(x)`
/// is exact for every finite double, so the comparison below is not.
func jsMathRound(_ x: Double) -> Double {
    if x.isNaN || x.isInfinite || x == 0 { return x }
    let floored = x.rounded(.down)
    let fraction = x - floored
    if fraction < 0.5 { return floored }
    // fraction > 0.5 rounds up; fraction == 0.5 is a tie, also toward +inf.
    let result = floored + 1
    // JS Math.round(-0.5) is -0; keep the sign so downstream formatting agrees.
    return (result == 0 && x < 0) ? -0.0 : result
}

/// `Math.round` result narrowed to `Int` for the fields the ports store as
/// integers (`genMs`).
///
/// RN keeps a JS Number, which is unbounded and admits NaN; neither port can.
/// Both ports CLAMP identically instead of diverging: Swift's `Int(_:)` used
/// to TRAP on NaN/out-of-range (a crash on a clock that ran backwards past
/// 2^63 ms or produced NaN), and Kotlin's `roundToInt()` silently saturated
/// at `Int.MAX_VALUE` while rounding ties differently. NaN maps to 0 - the
/// only total, sign-free choice, and the same one the Kotlin port makes.
func jsRoundToInt(_ x: Double) -> Int {
    let rounded = jsMathRound(x)
    if rounded.isNaN { return 0 }
    // Compare against the exact Double values of the Int bounds. Int.max is
    // not representable as a Double, so `>=` catches the rounded-up boundary.
    if rounded >= 9_223_372_036_854_775_808.0 { return Int.max }
    if rounded <= -9_223_372_036_854_775_808.0 { return Int.min }
    return Int(rounded)
}

/// JS `appId.charAt(0).toUpperCase() + appId.slice(1)`.
///
/// `charAt(0)` is a single UTF-16 CODE UNIT, so an astral first character is
/// split into its lone high surrogate, which has no case mapping and comes
/// back unchanged - `"\u{10428}eseret"` stays `"\u{10428}eseret"` in RN and
/// Kotlin. Swift's grapheme-level `prefix(1).uppercased()` DOES uppercase it
/// (to U+10400), a three-way disagreement.
///
/// This ports the UTF-16 spelling without ever materializing a lone surrogate
/// as a Swift String (which cannot hold one): a surrogate first unit is
/// recognized and the string passes through untouched, exactly as JS's
/// split-and-rejoin does.
func jsCapitalizeFirst(_ s: String) -> String {
    let units = Array(s.utf16)
    guard let first = units.first else { return "" }
    // A surrogate first code unit has no case mapping in JS; charAt(0) +
    // slice(1) then reassembles the original string verbatim.
    if (0xD800...0xDFFF).contains(first) { return s }
    // Uppercasing one BMP scalar may yield several ("\u{FB01}" -> "FI",
    // "ß" -> "SS"); JS does the same, so full mapping is correct here.
    let head = String(Unicode.Scalar(first)!).uppercased()
    return head + String(decoding: units.dropFirst(), as: UTF16.self)
}

/// RN degrades a non-`StreamError` to the BARE `err.message`. Swift's
/// `String(describing:)` instead yields a type-and-case description
/// ("timeout", "Boom()") and Kotlin's `toString()` a fully-qualified class
/// prefix ("java.lang.IllegalStateException: boom"), so the two ports and the
/// reference all showed different text - to the model (tool ERROR string) AND
/// to the user (`Screen.error`).
///
/// The shared rule both ports now run: the package error's message, else any
/// message the error carries, else the error type's SIMPLE name (never a
/// module/package qualification, never the case payload).
func jsErrorMessage(_ error: Error) -> String {
    if let streamError = error as? StreamError { return streamError.message }
    if let localized = error as? LocalizedError,
       let description = localized.errorDescription, !description.isEmpty {
        return description
    }
    return String(describing: type(of: error))
}
