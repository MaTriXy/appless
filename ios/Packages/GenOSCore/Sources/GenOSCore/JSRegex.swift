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
/// function throws there).
func jsDecodeURIComponent(_ s: String) -> String? {
    s.removingPercentEncoding
}

/// `encodeURIComponent` analog: everything but A-Za-z0-9 -_.!~*'() escaped.
func jsEncodeURIComponent(_ s: String) -> String {
    let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
    )
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

/// JS `parseInt(s, 10)`: optional sign + leading decimal digits; nil = NaN.
func jsParseInt(_ s: String) -> Int? {
    var scalars = Substring(s).unicodeScalars[...]
    // Leading whitespace is skipped by parseInt.
    while let c = scalars.first, c == " " || c == "\t" || c == "\n" || c == "\r" {
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
    guard !digits.isEmpty, let value = Int(digits) else { return nil }
    return negative ? -value : value
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
