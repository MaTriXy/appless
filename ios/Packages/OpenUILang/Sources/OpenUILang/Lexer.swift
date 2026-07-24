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
///
/// Operates on UTF-16 code units, exactly like the JS reference (`src[i]`
/// indexes a JS string, i.e. a code unit). Scanning `[Character]` (grapheme
/// clusters) instead was wrong twice over: "\r\n" is ONE Swift Character (the
/// CRLF cluster), so the whitespace/newline tests never fired for CRLF input;
/// and a combining mark straight after a quote/digit/paren glues onto that
/// cluster, so `c == "\""` etc. never matched. Token values are reconstructed
/// from code-unit ranges via `String(decoding:as: UTF16.self)`.
func tokenize(_ src: [UInt16]) -> [Token] {
    var tokens: [Token] = []
    var i = 0
    let n = src.count

    // Code-unit range checks are exact by construction: e.g. U+212A KELVIN
    // SIGN (canonically "K") is a single code unit 0x212A and does NOT satisfy
    // `c >= "A" && c <= "Z"`, matching the JS lexer.
    func isDigit(_ c: UInt16) -> Bool { c >= ascii16("0") && c <= ascii16("9") }
    func isAlpha(_ c: UInt16) -> Bool {
        (c >= ascii16("a") && c <= ascii16("z")) || (c >= ascii16("A") && c <= ascii16("Z"))
            || c == ascii16("_")
    }
    func isWordChar(_ c: UInt16) -> Bool { isAlpha(c) || isDigit(c) }
    func slice(_ range: Range<Int>) -> String {
        String(decoding: src[range], as: UTF16.self)
    }

    while i < n {
        // Skip horizontal whitespace (not newlines — they're significant).
        // A lone \r (and the \r of a \r\n pair) is horizontal whitespace.
        while i < n
            && (src[i] == ascii16(" ") || src[i] == ascii16("\t") || src[i] == ascii16("\r"))
        { i += 1 }
        if i >= n { break }
        let c = src[i]

        if c == ascii16("\n") { tokens.append(.newline); i += 1; continue }
        if c == ascii16("(") { tokens.append(.lparen); i += 1; continue }
        if c == ascii16(")") { tokens.append(.rparen); i += 1; continue }
        if c == ascii16("[") { tokens.append(.lbrack); i += 1; continue }
        if c == ascii16("]") { tokens.append(.rbrack); i += 1; continue }
        if c == ascii16("{") { tokens.append(.lbrace); i += 1; continue }
        if c == ascii16("}") { tokens.append(.rbrace); i += 1; continue }
        if c == ascii16(",") { tokens.append(.comma); i += 1; continue }
        if c == ascii16(":") { tokens.append(.colon); i += 1; continue }

        if c == ascii16("=") {
            if i + 1 < n && src[i + 1] == ascii16("=") { tokens.append(.eqeq); i += 2 }
            else { tokens.append(.equals); i += 1 }
            continue
        }
        if c == ascii16("!") {
            if i + 1 < n && src[i + 1] == ascii16("=") { tokens.append(.noteq); i += 2 }
            else { tokens.append(.not); i += 1 }
            continue
        }
        if c == ascii16(">") {
            if i + 1 < n && src[i + 1] == ascii16("=") { tokens.append(.greaterEq); i += 2 }
            else { tokens.append(.greater); i += 1 }
            continue
        }
        if c == ascii16("<") {
            if i + 1 < n && src[i + 1] == ascii16("=") { tokens.append(.lessEq); i += 2 }
            else { tokens.append(.less); i += 1 }
            continue
        }
        // A lone `&` lexes as `&&`; a lone `|` lexes as `||`.
        if c == ascii16("&") {
            tokens.append(.and)
            i += (i + 1 < n && src[i + 1] == ascii16("&")) ? 2 : 1
            continue
        }
        if c == ascii16("|") {
            tokens.append(.or)
            i += (i + 1 < n && src[i + 1] == ascii16("|")) ? 2 : 1
            continue
        }
        if c == ascii16(".") { tokens.append(.dot); i += 1; continue }
        if c == ascii16("?") { tokens.append(.question); i += 1; continue }
        if c == ascii16("+") { tokens.append(.plus); i += 1; continue }
        if c == ascii16("*") { tokens.append(.star); i += 1; continue }
        if c == ascii16("/") { tokens.append(.slash); i += 1; continue }
        if c == ascii16("%") { tokens.append(.percent); i += 1; continue }

        // ── String literal: "..." ─────────────────────────────────────────
        if c == ascii16("\"") {
            let start = i
            i += 1
            var isClosed = false
            while i < n {
                if src[i] == ascii16("\\") {
                    i += 2 // skip backslash and the escaped character
                } else if src[i] == ascii16("\"") {
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
        if c == ascii16("'") {
            i += 1
            var result: [UInt16] = []
            while i < n {
                if src[i] == ascii16("\\") {
                    i += 1
                    if i < n {
                        let esc = src[i]
                        if esc == ascii16("'") { result.append(ascii16("'")) }
                        else if esc == ascii16("\\") { result.append(ascii16("\\")) }
                        else if esc == ascii16("n") { result.append(ascii16("\n")) }
                        else if esc == ascii16("t") { result.append(ascii16("\t")) }
                        else { result.append(esc) } // pass through other escaped chars
                        i += 1
                    }
                } else if src[i] == ascii16("'") {
                    i += 1
                    break
                } else {
                    result.append(src[i])
                    i += 1
                }
            }
            tokens.append(.str(String(decoding: result, as: UTF16.self)))
            continue
        }

        // ── Minus: negative number literal or subtraction operator ────────
        var startNumber = false
        if c == ascii16("-") {
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
            if src[i] == ascii16("-") { i += 1 }
            while i < n && isDigit(src[i]) { i += 1 }
            if i < n && src[i] == ascii16(".") && i + 1 < n && isDigit(src[i + 1]) {
                i += 1
                while i < n && isDigit(src[i]) { i += 1 }
            }
            if i < n && (src[i] == ascii16("e") || src[i] == ascii16("E")) {
                i += 1
                if i < n && (src[i] == ascii16("+") || src[i] == ascii16("-")) { i += 1 }
                while i < n && isDigit(src[i]) { i += 1 }
            }
            // JS `+slice` semantics: a trailing exponent marker yields NaN.
            tokens.append(.num(Double(slice(start..<i)) ?? .nan))
            continue
        }

        // ── State variable: $identifier ───────────────────────────────────
        if c == ascii16("$") && i + 1 < n && isAlpha(src[i + 1]) {
            let start = i
            i += 1
            while i < n && isWordChar(src[i]) { i += 1 }
            tokens.append(.stateVar(slice(start..<i)))
            continue
        }

        // ── Keyword or identifier ─────────────────────────────────────────
        if isAlpha(c) {
            let start = i
            while i < n && isWordChar(src[i]) { i += 1 }
            let word = slice(start..<i)
            if word == "true" { tokens.append(.trueTok); continue }
            if word == "false" { tokens.append(.falseTok); continue }
            if word == "null" { tokens.append(.nullTok); continue }
            if c >= ascii16("A") && c <= ascii16("Z") {
                tokens.append(.type(word))
            } else {
                tokens.append(.ident(word))
            }
            continue
        }

        // ── Builtin call: @identifier ─────────────────────────────────────
        if c == ascii16("@") && i + 1 < n && isAlpha(src[i + 1]) {
            i += 1
            let start = i
            while i < n && isWordChar(src[i]) { i += 1 }
            tokens.append(.builtin(slice(start..<i)))
            continue
        }

        i += 1 // skip any other code unit (e.g. #, emoji surrogates)
    }
    tokens.append(.eof)
    return tokens
}

/// Reproduces the double-quote branch: hand the raw code-unit slice (with
/// quotes; a closing quote appended if unclosed) to a JSON string parser; on
/// failure fall back to the raw text with the boundary quotes stripped and no
/// unescaping at all.
func parseDoubleQuotedString(raw: [UInt16], isClosed: Bool) -> String {
    var candidate = raw
    if !isClosed { candidate.append(ascii16("\"")) }
    if let parsed = parseJSONStringLiteral(candidate) {
        return parsed
    }
    // Fallback: rawString.replace(/^"|"$/g, "") — strip one leading and one
    // trailing quote code unit (which may be the same unit).
    var stripped = raw
    if stripped.first == ascii16("\"") { stripped.removeFirst() }
    if stripped.last == ascii16("\"") { stripped.removeLast() }
    return String(decoding: stripped, as: UTF16.self)
}

/// Strict JSON string literal parser (RFC 8259) over UTF-16 code units,
/// matching `JSON.parse` on a single string token. Returns nil on any invalid
/// escape, control character, or malformed shape.
///
/// `\uXXXX` escapes append their code unit verbatim, so a `😀` pair
/// combines into one scalar exactly as in JS — at the final
/// `String(decoding:as: UTF16.self)`. An UNPAIRED surrogate is preserved by
/// JS but cannot live in a Swift String; the decode substitutes U+FFFD
/// (KNOWN-DEVIATION, README.md #2).
func parseJSONStringLiteral(_ units: [UInt16]) -> String? {
    guard units.count >= 2, units.first == ascii16("\""), units.last == ascii16("\"")
    else { return nil }
    var out: [UInt16] = []
    var i = 1
    let end = units.count - 1

    // JSON hex digits are exactly [0-9a-fA-F] — code-unit exact (JS rejects
    // e.g. fullwidth digits, which `Character.hexDigitValue` would accept).
    func hexDigit(_ u: UInt16) -> UInt32? {
        switch u {
        case ascii16("0")...ascii16("9"): return UInt32(u - ascii16("0"))
        case ascii16("a")...ascii16("f"): return UInt32(u - ascii16("a")) + 10
        case ascii16("A")...ascii16("F"): return UInt32(u - ascii16("A")) + 10
        default: return nil
        }
    }

    while i < end {
        let c = units[i]
        if c == ascii16("\\") {
            i += 1
            guard i < end else { return nil }
            switch units[i] {
            case ascii16("\""): out.append(ascii16("\""))
            case ascii16("\\"): out.append(ascii16("\\"))
            case ascii16("/"): out.append(ascii16("/"))
            case ascii16("b"): out.append(0x08)
            case ascii16("f"): out.append(0x0C)
            case ascii16("n"): out.append(ascii16("\n"))
            case ascii16("r"): out.append(ascii16("\r"))
            case ascii16("t"): out.append(ascii16("\t"))
            case ascii16("u"):
                var value: UInt32 = 0
                for k in 1...4 {
                    guard i + k < units.count, let d = hexDigit(units[i + k]) else { return nil }
                    value = value * 16 + d
                }
                i += 4
                out.append(UInt16(value))
            default:
                return nil // invalid escape → whole-string raw fallback
            }
            i += 1
        } else {
            // JSON.parse rejects unescaped control characters (< U+0020).
            if c < 0x20 { return nil }
            if c == ascii16("\"") { return nil } // interior unescaped quote (defensive)
            out.append(c)
            i += 1
        }
    }
    return String(decoding: out, as: UTF16.self)
}
