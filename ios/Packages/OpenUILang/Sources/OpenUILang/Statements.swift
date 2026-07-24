import Foundation

/// A raw statement produced by the token splitter.
struct RawStatement {
    enum IdTokenType {
        case ident, type, stateVar
    }
    let id: String
    let idTokenType: IdTokenType
    let tokens: [Token]
}

/// Result of `autoClose`.
struct AutoCloseResult {
    let text: [UInt16]
    let wasIncomplete: Bool
}

/// Auto-close unclosed strings and brackets so partial/streaming input can be
/// parsed without syntax errors. Port of `statements.js` `autoClose`
/// (spec/openui-lang.md §7 auto-closing).
///
/// Scans UTF-16 code units like the JS reference — a combining mark straight
/// after a closing quote/bracket must NOT hide it (it would glue into the
/// same grapheme cluster under `[Character]` scanning).
func autoClose(_ input: [UInt16]) -> AutoCloseResult {
    var stack: [UInt16] = []
    var inStr: UInt16? = nil
    var esc = false
    for c in input {
        if esc {
            esc = false
            continue
        }
        if c == ascii16("\\") && inStr != nil {
            esc = true
            continue
        }
        if let q = inStr {
            if c == q { inStr = nil }
            continue
        }
        if c == ascii16("\"") || c == ascii16("'") {
            inStr = c
            continue
        }
        if c == ascii16("(") || c == ascii16("[") || c == ascii16("{") {
            stack.append(c)
        } else if c == ascii16(")") && stack.last == ascii16("(") {
            stack.removeLast()
        } else if c == ascii16("]") && stack.last == ascii16("[") {
            stack.removeLast()
        } else if c == ascii16("}") && stack.last == ascii16("{") {
            stack.removeLast()
        }
    }
    let wasIncomplete = inStr != nil || !stack.isEmpty
    if !wasIncomplete {
        return AutoCloseResult(text: input, wasIncomplete: false)
    }
    var out = input
    if let q = inStr {
        if esc { out.append(ascii16("\\")) }
        out.append(q) // close with matching quote
    }
    for c in stack.reversed() {
        out.append(
            c == ascii16("(")
                ? ascii16(")") : (c == ascii16("[") ? ascii16("]") : ascii16("}")))
    }
    return AutoCloseResult(text: out, wasIncomplete: true)
}

/// Split the flat token stream into individual statements.
/// Port of `statements.js` `split` (spec/openui-lang.md §6 statement
/// splitting, §2 program structure).
func splitStatements(_ tokens: [Token]) -> [RawStatement] {
    var stmts: [RawStatement] = []
    var pos = 0
    let count = tokens.count

    func skipLine() {
        while pos < count && tokens[pos] != .newline && tokens[pos] != .eof { pos += 1 }
    }

    while pos < count {
        while pos < count && tokens[pos] == .newline { pos += 1 }
        if pos >= count || tokens[pos] == .eof { break }

        let tok = tokens[pos]
        let id: String
        let idType: RawStatement.IdTokenType
        switch tok {
        case .ident(let v): id = v; idType = .ident
        case .type(let v): id = v; idType = .type
        case .stateVar(let v): id = v; idType = .stateVar
        default:
            skipLine()
            continue
        }
        pos += 1

        guard pos < count, tokens[pos] == .equals else {
            skipLine()
            continue
        }
        pos += 1

        var expr: [Token] = []
        var depth = 0
        var ternaryDepth = 0
        while pos < count && tokens[pos] != .eof {
            let tt = tokens[pos]
            if tt == .newline && depth <= 0 && ternaryDepth <= 0 {
                // Look ahead past newlines for a ternary continuation.
                var peek = pos + 1
                while peek < count && tokens[peek] == .newline { peek += 1 }
                let nextT = peek < count ? tokens[peek] : .eof
                if nextT == .question || (nextT == .colon && ternaryDepth > 0) {
                    pos += 1
                    continue
                }
                break // statement boundary
            }
            if tt == .newline {
                pos += 1
                continue
            }
            if tt == .lparen || tt == .lbrack || tt == .lbrace {
                depth += 1
            } else if (tt == .rparen || tt == .rbrack || tt == .rbrace) && depth > 0 {
                depth -= 1
            } else if tt == .question && depth == 0 {
                ternaryDepth += 1
            } else if tt == .colon && depth == 0 && ternaryDepth > 0 {
                ternaryDepth -= 1
            }
            expr.append(tokens[pos])
            pos += 1
        }
        if !expr.isEmpty {
            stmts.append(RawStatement(id: id, idTokenType: idType, tokens: expr))
        }
    }
    return stmts
}
