import Foundation

/// Extract code from markdown fences, or return as-is if no fences found.
/// String-context-aware: a ``` inside a double-quoted string does not close a
/// fence. Port of `parser/parser.js` `stripFences`
/// (spec/openui-lang.md §4 preprocessing).
func stripFences(_ input: String) -> String {
    let chars = Array(input)
    let n = chars.count

    func indexOfFence(from: Int) -> Int? {
        var i = from
        while i + 2 < n {
            if chars[i] == "`" && chars[i + 1] == "`" && chars[i + 2] == "`" { return i }
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
        while j < n && chars[j] != "\n" { j += 1 }
        if j >= n {
            // No newline after opening fence (streaming) — take everything
            // after fence marker, then drop the first line (lang tag).
            var tail = Array(chars[(fenceStart + 3)...])
            // replace(/^[^\n]*\n?/, "")
            var k = 0
            while k < tail.count && tail[k] != "\n" { k += 1 }
            if k < tail.count { k += 1 } // include the newline
            tail.removeFirst(k)
            blocks.append(String(tail))
            i = n
            break
        }
        j += 1 // skip the newline
        // Scan for closing ``` while tracking double-quote string context
        var inStr = false
        var closePos = -1
        var k = j
        while k < n {
            let c = chars[k]
            if inStr {
                if c == "\\" && k + 1 < n {
                    k += 2
                    continue
                }
                if c == "\"" { inStr = false }
                k += 1
                continue
            }
            if c == "\"" {
                inStr = true
                k += 1
                continue
            }
            if c == "`" && k + 1 < n && chars[k + 1] == "`" && k + 2 < n && chars[k + 2] == "`" {
                closePos = k
                break
            }
            k += 1
        }
        if closePos != -1 {
            blocks.append(String(chars[j..<closePos]))
            i = closePos + 3
        } else {
            blocks.append(String(chars[j...]))
            i = n
        }
    }
    if !blocks.isEmpty { return blocks.joined(separator: "\n") }

    // Fallback: input starts with ``` but wasn't matched.
    if input.hasPrefix("```") {
        var j = 3
        while j < n && chars[j] != "\n" { j += 1 }
        let start = j < n ? j + 1 : 3
        let body = Array(chars[min(start, n)...])
        // lastIndexOf("```")
        var trailing = -1
        if body.count >= 3 {
            var k = body.count - 3
            while k >= 0 {
                if body[k] == "`" && body[k + 1] == "`" && body[k + 2] == "`" {
                    trailing = k
                    break
                }
                k -= 1
            }
        }
        if trailing != -1 {
            return String(body[0..<trailing])
        }
        return String(body)
    }
    return input
}

/// Strip `//` and `#` line comments outside of strings (both `"` and `'`
/// delimiters, escape-aware, per line). Port of `stripComments`
/// (spec/openui-lang.md §3.5 comments, §4 preprocessing).
func stripComments(_ input: String) -> String {
    let lines = input.components(separatedBy: "\n")
    let processed = lines.map { line -> String in
        let chars = Array(line)
        var inStr: Character? = nil
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = inStr {
                if c == "\\" && i + 1 < chars.count {
                    i += 2 // skip escaped char
                    continue
                }
                if c == q { inStr = nil }
                i += 1
                continue
            }
            if c == "\"" || c == "'" {
                inStr = c
                i += 1
                continue
            }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                return String(chars[0..<i]).jsTrimEnd()
            }
            if c == "#" {
                return String(chars[0..<i]).jsTrimEnd()
            }
            i += 1
        }
        return line
    }
    return processed.joined(separator: "\n")
}

extension String {
    /// JS `String.prototype.trim()` whitespace set (close approximation).
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
