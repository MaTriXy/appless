import Foundation

/// Extract code from markdown fences, or return as-is if no fences found.
/// String-context-aware: a ``` inside a double-quoted string does not close a
/// fence. Port of `parser/parser.js` `stripFences`
/// (spec/openui-lang.md §4 preprocessing).
func stripFences(_ input: String) -> String {
    // UTF-16 code-unit scan, mirroring the JS reference (`input[j]` indexes a
    // code unit): "\r\n" stays two units (CRLF must terminate a lang tag just
    // like LF), a combining mark after `"` cannot hide the quote, and U+1FEF
    // GREEK VARIA (canonically "`") does not count as a fence character.
    let units = Array(input.utf16)
    let n = units.count
    let backtick = ascii16("`")
    let newline = ascii16("\n")

    func indexOfFence(from: Int) -> Int? {
        var i = from
        while i + 2 < n {
            if units[i] == backtick && units[i + 1] == backtick && units[i + 2] == backtick {
                return i
            }
            i += 1
        }
        return nil
    }

    var blocks: [String] = []
    var i = 0
    while i < n {
        guard let fenceStart = indexOfFence(from: i) else { break }
        // Skip language tag until newline
        var j = fenceStart + 3
        while j < n && units[j] != newline { j += 1 }
        if j >= n {
            // No newline after opening fence (streaming) — take everything
            // after fence marker, then drop the first line (lang tag).
            var tail = Array(units[(fenceStart + 3)...])
            // replace(/^[^\n]*\n?/, "")
            var k = 0
            while k < tail.count && tail[k] != newline { k += 1 }
            if k < tail.count { k += 1 } // include the newline
            tail.removeFirst(k)
            blocks.append(String(decoding: tail, as: UTF16.self))
            i = n
            break
        }
        j += 1 // skip the newline
        // Scan for closing ``` while tracking double-quote string context
        var inStr = false
        var closePos = -1
        var k = j
        while k < n {
            let c = units[k]
            if inStr {
                if c == ascii16("\\") && k + 1 < n {
                    k += 2
                    continue
                }
                if c == ascii16("\"") { inStr = false }
                k += 1
                continue
            }
            if c == ascii16("\"") {
                inStr = true
                k += 1
                continue
            }
            if c == backtick && k + 1 < n && units[k + 1] == backtick && k + 2 < n
                && units[k + 2] == backtick
            {
                closePos = k
                break
            }
            k += 1
        }
        if closePos != -1 {
            blocks.append(String(decoding: units[j..<closePos], as: UTF16.self))
            i = closePos + 3
        } else {
            blocks.append(String(decoding: units[j...], as: UTF16.self))
            i = n
        }
    }
    if !blocks.isEmpty { return blocks.joined(separator: "\n") }

    // Fallback: input starts with ``` but wasn't matched.
    // (jsStringHasPrefix: Swift's hasPrefix matches canonically.)
    if jsStringHasPrefix(input, "```") {
        var j = 3
        while j < n && units[j] != newline { j += 1 }
        let start = j < n ? j + 1 : 3
        let body = Array(units[min(start, n)...])
        // lastIndexOf("```")
        var trailing = -1
        if body.count >= 3 {
            var k = body.count - 3
            while k >= 0 {
                if body[k] == backtick && body[k + 1] == backtick && body[k + 2] == backtick {
                    trailing = k
                    break
                }
                k -= 1
            }
        }
        if trailing != -1 {
            return String(decoding: body[0..<trailing], as: UTF16.self)
        }
        return String(decoding: body, as: UTF16.self)
    }
    return input
}

/// Strip `//` and `#` line comments outside of strings (both `"` and `'`
/// delimiters, escape-aware, per line). Port of `stripComments`
/// (spec/openui-lang.md §3.5 comments, §4 preprocessing).
func stripComments(_ input: String) -> String {
    // Split and scan on UTF-16 code units like the JS reference: a combining
    // mark straight after a closing quote must not keep the string context
    // open (it would glue onto the quote's grapheme cluster).
    let lines = jsStringSplit(input, separator: "\n")
    let processed = lines.map { line -> String in
        let units = Array(line.utf16)
        var inStr: UInt16? = nil
        var i = 0
        while i < units.count {
            let c = units[i]
            if let q = inStr {
                if c == ascii16("\\") && i + 1 < units.count {
                    i += 2 // skip escaped char
                    continue
                }
                if c == q { inStr = nil }
                i += 1
                continue
            }
            if c == ascii16("\"") || c == ascii16("'") {
                inStr = c
                i += 1
                continue
            }
            if c == ascii16("/") && i + 1 < units.count && units[i + 1] == ascii16("/") {
                return String(decoding: units[0..<i], as: UTF16.self).jsTrimEnd()
            }
            if c == ascii16("#") {
                return String(decoding: units[0..<i], as: UTF16.self).jsTrimEnd()
            }
            i += 1
        }
        return line
    }
    return processed.joined(separator: "\n")
}

extension String {
    /// JS `String.prototype.trim()` whitespace set (close approximation).
    /// KNOWN-DEVIATION (README.md #7): `whitespacesAndNewlines` also contains
    /// U+0085 NEL, which the JS trim set does not.
    static let jsWhitespace = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{FEFF}\u{A0}"))

    func jsTrim() -> String {
        trimmingCharacters(in: String.jsWhitespace)
    }

    func jsTrimEnd() -> String {
        var s = self
        while let last = s.unicodeScalars.last, String.jsWhitespace.contains(last) {
            s.unicodeScalars.removeLast()
        }
        return s
    }
}
