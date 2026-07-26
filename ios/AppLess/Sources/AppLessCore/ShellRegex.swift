//
//  ShellRegex.swift
//  AppLessCore
//
//  The regex/string primitives the shell's command routing needs, with
//  ECMAScript (not ICU) semantics.
//
//  `GenOSCore.JSRegex` is internal to that package, so the same audited
//  spellings are restated here for the shell's own call sites. The hazard
//  table is unchanged and is the reason none of these patterns use `\s`,
//  `\w`, `.` or the `i` flag directly:
//
//  - JS `\s` is WhiteSpace ∪ LineTerminator (\t \n \v \f \r U+FEFF \p{Z}
//    U+2028 U+2029); ICU's `\s` misses U+000B and U+FEFF → use ``jsWS``.
//  - JS `.` (no `s` flag) excludes exactly \n \r U+2028 U+2029; ICU's `.`
//    also excludes U+000B, U+000C, U+0085 → use ``jsDot``.
//  - ICU case-insensitive matching folds U+212A (KELVIN) onto "k" and U+017F
//    (LONG S) onto "s"; JS `i` without `u` does not → ``caseInsensitive(_:)``
//    spells the case variants out instead.
//  - JS `^`/`$` (no `m` flag) are `\A`/`\z` in ICU (ICU's `$` also matches
//    before a final line terminator).
//
//  NO SwiftUI in this file.
//

import Foundation

enum ShellRegex {
    /// ECMAScript `\s` as a character class.
    static let jsWS = #"[\t\n\x{B}\f\r\p{Z}\x{FEFF}]"#
    /// ECMAScript `.` (anything but \n \r U+2028 U+2029).
    static let jsDot = #"[^\n\r\x{2028}\x{2029}]"#

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:]

    static func compile(_ pattern: String) -> NSRegularExpression {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[pattern] { return hit }
        // Every pattern here is a compile-time constant; a failure is a
        // programmer error the test suite catches immediately.
        // swiftlint:disable:next force_try
        let re = try! NSRegularExpression(pattern: pattern)
        cache[pattern] = re
        return re
    }

    /// `text.match(re)` (non-global): whole match + captures, or nil.
    static func first(_ pattern: String, _ text: String) -> [String?]? {
        let re = compile(pattern)
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    /// `re.test(text)`.
    static func test(_ pattern: String, _ text: String) -> Bool {
        first(pattern, text) != nil
    }

    /// `text.replace(re, replacement)` for a GLOBAL regex.
    static func replacingAll(_ pattern: String, in text: String, with template: String) -> String {
        let re = compile(pattern)
        let ns = text as NSString
        return re.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }

    /// A literal spelled so it matches case-insensitively with JS (not ICU)
    /// semantics: every ASCII letter becomes a two-member class, everything
    /// else is escaped verbatim. `"back"` → `[Bb][Aa][Cc][Kk]`.
    ///
    /// This is what a ported `/…/i` pattern uses instead of the `i` flag; see
    /// the hazard note above.
    static func caseInsensitive(_ literal: String) -> String {
        var out = ""
        for scalar in literal.unicodeScalars {
            let c = Character(scalar)
            if c.isASCII, c.isLetter {
                out += "[\(c.uppercased())\(c.lowercased())]"
            } else {
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
        }
        return out
    }
}

// MARK: - JS string primitives

/// JS `String.prototype.trim()`: the exact ECMAScript whitespace set.
/// Foundation's `.whitespacesAndNewlines` diverges (strips U+0085, keeps
/// U+FEFF), so ported `.trim()` call sites use this.
func shellTrim(_ s: String) -> String {
    ShellRegex.replacingAll("\\A\(ShellRegex.jsWS)+|\(ShellRegex.jsWS)+\\z", in: s, with: "")
}

/// JS `haystack.includes(needle)`: UTF-16-level containment. Swift's
/// `String.contains` is grapheme-level, so a needle whose last character is
/// glued to a following combining mark ("food" in "food\u{301}court") would
/// be missed there but is found by JS - and by this.
func shellContains(_ haystack: String, _ needle: String) -> Bool {
    let hay = Array(haystack.utf16)
    let ned = Array(needle.utf16)
    guard !ned.isEmpty else { return true }
    guard hay.count >= ned.count else { return false }
    for i in 0...(hay.count - ned.count) where hay[i] == ned[0] {
        if !zip(hay[i..<(i + ned.count)], ned).contains(where: { $0 != $1 }) { return true }
    }
    return false
}

/// JS `s.length` - UTF-16 code units, which is what the shell's 24-character
/// summon-name cut-off is measured in.
func shellUTF16Count(_ s: String) -> Int { s.utf16.count }

/// JS `s.slice(0, end)` in UTF-16 code units. A cut that splits a surrogate
/// pair leaves JS holding a lone surrogate, which becomes U+FFFD as soon as
/// the string is UTF-8-encoded; Swift materializes that same U+FFFD here.
func shellSlice(_ s: String, upTo end: Int) -> String {
    let units = Array(s.utf16)
    guard units.count > end else { return s }
    return String(decoding: units[..<max(0, end)], as: UTF16.self)
}

/// RN `capitalize`: `s.charAt(0).toUpperCase() + s.slice(1)`, grapheme-level
/// (identical for every BMP input; see `GenOSCore.Controller.openDeepLink`
/// for why the grapheme spelling is the deliberate choice for app ids).
func shellCapitalize(_ s: String) -> String {
    s.prefix(1).uppercased() + s.dropFirst()
}
