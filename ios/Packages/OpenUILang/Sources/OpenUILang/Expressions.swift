import Foundation

/// Pratt precedence expression parser — port of lang-core
/// `parser/expressions.js` `parseExpression`
/// (spec/openui-lang.md §5 expression grammar; §5.1 colon corruption,
/// §5.2 multi-line ternaries).
func parseExpression(_ tokens: [Token]) -> ASTNode {
    var pos = 0

    func cur() -> Token { pos < tokens.count ? tokens[pos] : .eof }
    func peekNext() -> Token { pos + 1 < tokens.count ? tokens[pos + 1] : .eof }
    @discardableResult
    func adv() -> Token {
        let tok = cur()
        pos += 1
        return tok
    }
    func eat(_ kind: Token) {
        if cur() == kind { pos += 1 }
    }

    let precTernary = 1, precOr = 2, precAnd = 3, precEq = 4, precCmp = 5
    let precAdd = 6, precMul = 7, precUnary = 8, precMember = 9

    func infixPrec(_ tok: Token) -> Int {
        switch tok {
        case .question: return precTernary
        case .or: return precOr
        case .and: return precAnd
        case .eqeq, .noteq: return precEq
        case .greater, .less, .greaterEq, .lessEq: return precCmp
        case .plus, .minus: return precAdd
        case .star, .slash, .percent: return precMul
        case .dot, .lbrack: return precMember
        default: return 0
        }
    }

    func parseExpr(_ minPrec: Int) -> ASTNode {
        var left = parsePrefix()
        while infixPrec(cur()) > minPrec {
            left = parseInfix(left)
        }
        return left
    }

    func parsePrefix() -> ASTNode {
        let tok = cur()
        switch tok {
        case .str(let v):
            adv()
            return .str(v)
        case .num(let v):
            adv()
            return .num(v)
        case .trueTok:
            adv()
            return .bool(true)
        case .falseTok:
            adv()
            return .bool(false)
        case .nullTok:
            adv()
            return .null
        case .lbrack:
            return parseArr()
        case .lbrace:
            return parseObj()
        case .stateVar(let name):
            adv()
            if cur() == .equals {
                adv()
                let value = parseExpr(0)
                return .assign(target: name, value: value)
            }
            return .stateRef(name)
        case .type(let name):
            // Builtins require @-prefix — only Action is exempt.
            if peekNext() == .lparen && (!Builtins.isBuiltin(name) || name == "Action") {
                return parseComp(name)
            }
            adv()
            return .ref(name)
        case .builtin(let name):
            if peekNext() == .lparen {
                return parseComp(name)
            }
            adv()
            return .ref(name)
        case .ident(let name):
            adv()
            return .ref(name)
        case .not:
            adv()
            return .unaryOp(op: "!", operand: parseExpr(precUnary))
        case .minus:
            adv()
            return .unaryOp(op: "-", operand: parseExpr(precUnary))
        case .lparen:
            adv()
            let inner = parseExpr(0)
            eat(.rparen)
            return inner
        default:
            adv() // unknown token — skip and return Null
            return .null
        }
    }

    func parseInfix(_ left: ASTNode) -> ASTNode {
        let tok = cur()
        switch tok {
        case .plus:
            adv()
            return .binOp(op: "+", left: left, right: parseExpr(precAdd))
        case .minus:
            adv()
            return .binOp(op: "-", left: left, right: parseExpr(precAdd))
        case .star:
            adv()
            return .binOp(op: "*", left: left, right: parseExpr(precMul))
        case .slash:
            adv()
            return .binOp(op: "/", left: left, right: parseExpr(precMul))
        case .percent:
            adv()
            return .binOp(op: "%", left: left, right: parseExpr(precMul))
        case .eqeq:
            adv()
            return .binOp(op: "==", left: left, right: parseExpr(precEq))
        case .noteq:
            adv()
            return .binOp(op: "!=", left: left, right: parseExpr(precEq))
        case .greater:
            adv()
            return .binOp(op: ">", left: left, right: parseExpr(precCmp))
        case .less:
            adv()
            return .binOp(op: "<", left: left, right: parseExpr(precCmp))
        case .greaterEq:
            adv()
            return .binOp(op: ">=", left: left, right: parseExpr(precCmp))
        case .lessEq:
            adv()
            return .binOp(op: "<=", left: left, right: parseExpr(precCmp))
        case .and:
            adv()
            return .binOp(op: "&&", left: left, right: parseExpr(precAnd))
        case .or:
            adv()
            return .binOp(op: "||", left: left, right: parseExpr(precOr))
        case .question:
            adv()
            let then = parseExpr(0)
            eat(.colon)
            let els = parseExpr(0) // right-assoc: parse at lowest prec
            return .ternary(cond: left, then: then, elseNode: els)
        case .dot:
            adv()
            let fieldTok = cur()
            let field: String
            switch fieldTok {
            case .ident(let v), .type(let v):
                adv()
                field = v
            case .str(let v):
                adv()
                field = v
            case .num(let v):
                adv()
                field = jsNumberToString(v)
            case .stateVar(let v):
                adv()
                field = v.hasPrefix("$") ? String(v.dropFirst()) : v
            default:
                adv()
                field = "?"
            }
            return .member(obj: left, field: field)
        case .lbrack:
            adv()
            let idx = parseExpr(0)
            eat(.rbrack)
            return .index(obj: left, index: idx)
        default:
            return left // unreachable if infixPrec is correct
        }
    }

    /// Parse `TypeName(arg1, arg2, ...)` — cur() is the name token.
    func parseComp(_ name: String) -> ASTNode {
        adv() // consume name token
        eat(.lparen)
        var args: [ASTNode] = []
        while cur() != .rparen && cur() != .eof {
            args.append(parseExpr(0))
            if cur() == .comma { adv() }
        }
        eat(.rparen)
        return .comp(name: name, args: args, mappedProps: nil)
    }

    func parseArr() -> ASTNode {
        adv() // skip [
        var els: [ASTNode] = []
        while cur() != .rbrack && cur() != .eof {
            els.append(parseExpr(0))
            if cur() == .comma { adv() }
        }
        eat(.rbrack)
        return .arr(els)
    }

    func parseObj() -> ASTNode {
        adv() // skip {
        var entries: [(key: String, value: ASTNode)] = []
        while cur() != .rbrace && cur() != .eof {
            let kt = cur()
            let key: String
            switch kt {
            case .ident(let v), .type(let v):
                adv()
                key = v
            case .str(let v):
                adv()
                key = v
            case .num(let v):
                adv()
                key = jsNumberToString(v)
            case .stateVar(let v):
                adv()
                key = v.hasPrefix("$") ? String(v.dropFirst()) : v
            default:
                adv()
                key = "?"
            }
            eat(.colon)
            entries.append((key: key, value: parseExpr(0)))
            if cur() == .comma { adv() }
        }
        eat(.rbrace)
        return .obj(entries)
    }

    return parseExpr(0)
}
