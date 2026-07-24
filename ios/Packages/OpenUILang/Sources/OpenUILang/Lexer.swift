import Foundation

/// Token kinds mirroring lang-core `parser/tokens` (numeric T.* constants);
/// spec/openui-lang.md §3.1 tokens.
enum Token: Equatable {
    case newline
    case lparen, rparen, lbrack, rbrack, lbrace, rbrace
    case comma, colon
    case equals, eqeq, noteq
    case not
    case greater, greaterEq, less, lessEq
    case and, or
    case dot, question
    case plus, minus, star, slash, percent
    case str(String)
    case num(Double)
    case ident(String)
    case type(String)
    case stateVar(String)   // value includes the leading `$`
    case builtin(String)    // value excludes the leading `@`
    case trueTok, falseTok, nullTok
    case eof

    /// Token kinds that count as "values" for the minus disambiguation.
    var isValueToken: Bool {
        switch self {
        case .num, .str, .ident, .type, .rparen, .rbrack,
            .trueTok, .falseTok, .nullTok, .stateVar, .builtin:
            return true
        default:
            return false
        }
    }
}

/// Direct port of lang-core `parser/lexer.js` `tokenize`
/// (spec/openui-lang.md §3 lexical grammar; strings §3.2–3.3, numbers §3.4).
func tokenize(_ src: [Character]) -> [Token] {
    var tokens: [Token] = []
    var i = 0
    let n = src.count

    func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }
    func isAlpha(_ c: Character) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_"
    }
    func isWordChar(_ c: Character) -> Bool { isAlpha(c) || isDigit(c) }

    while i < n {
        // Skip horizontal whitespace (not newlines — they're significant)
        while i < n && (src[i] == " " || src[i] == "\t" || src[i] == "\r") { i += 1 }
        if i >= n { break }
        let c = src[i]

        if c == "\n" { tokens.append(.newline); i += 1; continue }
        if c == "(" { tokens.append(.lparen); i += 1; continue }
        if c == ")" { tokens.append(.rparen); i += 1; continue }
        if c == "[" { tokens.append(.lbrack); i += 1; continue }
        if c == "]" { tokens.append(.rbrack); i += 1; continue }
        if c == "{" { tokens.append(.lbrace); i += 1; continue }
        if c == "}" { tokens.append(.rbrace); i += 1; continue }
        if c == "," { tokens.append(.comma); i += 1; continue }
        if c == ":" { tokens.append(.colon); i += 1; continue }

        if c == "=" {
            if i + 1 < n && src[i + 1] == "=" { tokens.append(.eqeq); i += 2 }
            else { tokens.append(.equals); i += 1 }
            continue
        }
        if c == "!" {
            if i + 1 < n && src[i + 1] == "=" { tokens.append(.noteq); i += 2 }
            else { tokens.append(.not); i += 1 }
            continue
        }
        if c == ">" {
            if i + 1 < n && src[i + 1] == "=" { tokens.append(.greaterEq); i += 2 }
            else { tokens.append(.greater); i += 1 }
            continue
        }
        if c == "<" {
            if i + 1 < n && src[i + 1] == "=" { tokens.append(.lessEq); i += 2 }
            else { tokens.append(.less); i += 1 }
            continue
        }
        // A lone `&` lexes as `&&`; a lone `|` lexes as `||`.
        if c == "&" {
            tokens.append(.and)
            i += (i + 1 < n && src[i + 1] == "&") ? 2 : 1
            continue
        }
        if c == "|" {
            tokens.append(.or)
            i += (i + 1 < n && src[i + 1] == "|") ? 2 : 1
            continue
        }
        if c == "." { tokens.append(.dot); i += 1; continue }
        if c == "?" { tokens.append(.question); i += 1; continue }
        if c == "+" { tokens.append(.plus); i += 1; continue }
        if c == "*" { tokens.append(.star); i += 1; continue }
        if c == "/" { tokens.append(.slash); i += 1; continue }
        if c == "%" { tokens.append(.percent); i += 1; continue }

        // ── String literal: "..." ─────────────────────────────────────────
        if c == "\"" {
            let start = i
            i += 1
            var isClosed = false
            while i < n {
                if src[i] == "\\" {
                    i += 2 // skip backslash and the escaped character
                } else if src[i] == "\"" {
                    i += 1 // include the closing quote
                    isClosed = true
                    break
                } else {
                    i += 1
                }
            }
            let end = min(i, n)
            let raw = Array(src[start..<end])
            tokens.append(.str(parseDoubleQuotedString(raw: raw, isClosed: isClosed)))
            continue
        }

        // ── String literal: '...' (single quotes) ─────────────────────────
        if c == "'" {
            i += 1
            var result = ""
            while i < n {
                if src[i] == "\\" {
                    i += 1
                    if i < n {
                        let esc = src[i]
                        if esc == "'" { result.append("'") }
                        else if esc == "\\" { result.append("\\") }
                        else if esc == "n" { result.append("\n") }
                        else if esc == "t" { result.append("\t") }
                        else { result.append(esc) } // pass through other escaped chars
                        i += 1
                    }
                } else if src[i] == "'" {
                    i += 1
                    break
                } else {
                    result.append(src[i])
                    i += 1
                }
            }
            tokens.append(.str(result))
            continue
        }

        // ── Minus: negative number literal or subtraction operator ────────
        var startNumber = false
        if c == "-" {
            let afterValue = tokens.last?.isValueToken ?? false
            if !afterValue && i + 1 < n && isDigit(src[i + 1]) {
                startNumber = true // negative number literal
            } else {
                tokens.append(.minus)
                i += 1
                continue
            }
        }

        // ── Number literal: 42, -3, 1.5, 1e10 ────────────────────────────
        if isDigit(c) || startNumber {
            let start = i
            if src[i] == "-" { i += 1 }
            while i < n && isDigit(src[i]) { i += 1 }
            if i < n && src[i] == "." && i + 1 < n && isDigit(src[i + 1]) {
                i += 1
                while i < n && isDigit(src[i]) { i += 1 }
            }
            if i < n && (src[i] == "e" || src[i] == "E") {
                i += 1
                if i < n && (src[i] == "+" || src[i] == "-") { i += 1 }
                while i < n && isDigit(src[i]) { i += 1 }
            }
            let slice = String(src[start..<i])
            // JS `+slice` semantics: a trailing exponent marker yields NaN.
            tokens.append(.num(Double(slice) ?? .nan))
            continue
        }

        // ── State variable: $identifier ───────────────────────────────────
        if c == "$" && i + 1 < n && isAlpha(src[i + 1]) {
            let start = i
            i += 1
            while i < n && isWordChar(src[i]) { i += 1 }
            tokens.append(.stateVar(String(src[start..<i])))
            continue
        }

        // ── Keyword or identifier ─────────────────────────────────────────
        if isAlpha(c) {
            let start = i
            while i < n && isWordChar(src[i]) { i += 1 }
            let word = String(src[start..<i])
            if word == "true" { tokens.append(.trueTok); continue }
            if word == "false" { tokens.append(.falseTok); continue }
            if word == "null" { tokens.append(.nullTok); continue }
            if c >= "A" && c <= "Z" {
                tokens.append(.type(word))
            } else {
                tokens.append(.ident(word))
            }
            continue
        }

        // ── Builtin call: @identifier ─────────────────────────────────────
        if c == "@" && i + 1 < n && isAlpha(src[i + 1]) {
            i += 1
            let start = i
            while i < n && isWordChar(src[i]) { i += 1 }
            tokens.append(.builtin(String(src[start..<i])))
            continue
        }

        i += 1 // skip any other character (e.g. #, emojis)
    }
    tokens.append(.eof)
    return tokens
}

/// Reproduces the double-quote branch: hand the raw slice (with quotes; a
/// closing quote appended if unclosed) to a JSON string parser; on failure
/// fall back to the raw text with the boundary quotes stripped and no
/// unescaping at all.
func parseDoubleQuotedString(raw: [Character], isClosed: Bool) -> String {
    var candidate = raw
    if !isClosed { candidate.append("\"") }
    if let parsed = parseJSONStringLiteral(candidate) {
        return parsed
    }
    // Fallback: rawString.replace(/^"|"$/g, "") — strip one leading and one
    // trailing quote character (which may be the same character).
    var stripped = raw
    if stripped.first == "\"" { stripped.removeFirst() }
    if stripped.last == "\"" { stripped.removeLast() }
    return String(stripped)
}

/// Strict JSON string literal parser (RFC 8259), matching `JSON.parse` on a
/// single string token. Returns nil on any invalid escape, control character,
/// or malformed shape.
func parseJSONStringLiteral(_ chars: [Character]) -> String? {
    guard chars.count >= 2, chars.first == "\"", chars.last == "\"" else { return nil }
    var out = ""
    var i = 1
    let end = chars.count - 1
    var pendingHighSurrogate: UInt32? = nil

    func flushSurrogate() {
        if let high = pendingHighSurrogate {
            // KNOWN-DEVIATION (README.md #2): JS preserves lone UTF-16
            // surrogates; Swift String cannot — substitute U+FFFD.
            out.append("\u{FFFD}")
            _ = high
            pendingHighSurrogate = nil
        }
    }

    while i < end {
        let c = chars[i]
        if c == "\\" {
            i += 1
            guard i < end else { return nil }
            let e = chars[i]
            switch e {
            case "\"": flushSurrogate(); out.append("\"")
            case "\\": flushSurrogate(); out.append("\\")
            case "/": flushSurrogate(); out.append("/")
            case "b": flushSurrogate(); out.append("\u{08}")
            case "f": flushSurrogate(); out.append("\u{0C}")
            case "n": flushSurrogate(); out.append("\n")
            case "r": flushSurrogate(); out.append("\r")
            case "t": flushSurrogate(); out.append("\t")
            case "u":
                var value: UInt32 = 0
                for k in 1...4 {
                    guard i + k < chars.count, let d = chars[i + k].hexDigitValue else { return nil }
                    value = value * 16 + UInt32(d)
                }
                i += 4
                if value >= 0xD800 && value <= 0xDBFF {
                    flushSurrogate()
                    pendingHighSurrogate = value
                } else if value >= 0xDC00 && value <= 0xDFFF {
                    if let high = pendingHighSurrogate {
                        let combined = 0x10000 + ((high - 0xD800) << 10) + (value - 0xDC00)
                        if let scalar = Unicode.Scalar(combined) {
                            out.unicodeScalars.append(scalar)
                        } else {
                            out.append("\u{FFFD}")
                        }
                        pendingHighSurrogate = nil
                    } else {
                        out.append("\u{FFFD}") // lone low surrogate
                    }
                } else {
                    flushSurrogate()
                    if let scalar = Unicode.Scalar(value) {
                        out.unicodeScalars.append(scalar)
                    } else {
                        out.append("\u{FFFD}")
                    }
                }
            default:
                return nil // invalid escape → whole-string raw fallback
            }
            i += 1
        } else {
            flushSurrogate()
            // JSON.parse rejects unescaped control characters (< U+0020).
            for scalar in c.unicodeScalars where scalar.value < 0x20 {
                _ = scalar
                return nil
            }
            if c == "\"" { return nil } // interior unescaped quote (defensive)
            out.append(c)
            i += 1
        }
    }
    flushSurrogate()
    return out
}
