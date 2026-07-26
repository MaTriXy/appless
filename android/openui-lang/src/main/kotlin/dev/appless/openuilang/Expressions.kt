package dev.appless.openuilang

private const val PREC_TERNARY = 1
private const val PREC_OR = 2
private const val PREC_AND = 3
private const val PREC_EQ = 4
private const val PREC_CMP = 5
private const val PREC_ADD = 6
private const val PREC_MUL = 7
private const val PREC_UNARY = 8
private const val PREC_MEMBER = 9

/**
 * Pratt precedence expression parser — port of lang-core
 * `parser/expressions.js` `parseExpression` (spec/openui-lang.md §5 expression
 * grammar; §5.1 named-argument corruption, §5.2 multi-line ternaries).
 */
internal fun parseExpression(tokens: List<Token>): AstNode = ExpressionParser(tokens).parse()

private class ExpressionParser(private val tokens: List<Token>) {
    private var pos = 0
    private val eof = Token(TokType.EOF)

    fun parse(): AstNode = parseExpr(0)

    private fun cur(): Token = if (pos < tokens.size) tokens[pos] else eof

    private fun peekNext(): Token = if (pos + 1 < tokens.size) tokens[pos + 1] else eof

    private fun adv(): Token {
        val tok = cur()
        pos++
        return tok
    }

    private fun eat(kind: TokType) {
        if (cur().t == kind) pos++
    }

    private fun infixPrec(tok: Token): Int = when (tok.t) {
        TokType.QUESTION -> PREC_TERNARY
        TokType.OR -> PREC_OR
        TokType.AND -> PREC_AND
        TokType.EQEQ, TokType.NOTEQ -> PREC_EQ
        TokType.GREATER, TokType.LESS, TokType.GREATER_EQ, TokType.LESS_EQ -> PREC_CMP
        TokType.PLUS, TokType.MINUS -> PREC_ADD
        TokType.STAR, TokType.SLASH, TokType.PERCENT -> PREC_MUL
        TokType.DOT, TokType.LBRACK -> PREC_MEMBER
        else -> 0
    }

    private fun parseExpr(minPrec: Int): AstNode {
        var left = parsePrefix()
        while (infixPrec(cur()) > minPrec) {
            left = parseInfix(left)
        }
        return left
    }

    private fun parsePrefix(): AstNode {
        val tok = cur()
        when (tok.t) {
            TokType.STR -> { adv(); return AstNode.Str(tok.s) }
            TokType.NUM -> { adv(); return AstNode.Num(tok.n) }
            TokType.TRUE -> { adv(); return AstNode.Bool(true) }
            TokType.FALSE -> { adv(); return AstNode.Bool(false) }
            TokType.NULL -> { adv(); return AstNode.Null }
            TokType.LBRACK -> return parseArr()
            TokType.LBRACE -> return parseObj()
            TokType.STATE_VAR -> {
                val name = tok.s
                adv()
                // Assignment: `$var = expr` (Equals, NOT EqEq).
                if (cur().t == TokType.EQUALS) {
                    adv()
                    return AstNode.Assign(name, parseExpr(0))
                }
                return AstNode.StateRef(name)
            }

            TokType.TYPE -> {
                val name = tok.s
                // Builtins require an @-prefix — only `Action` is exempt.
                if (peekNext().t == TokType.LPAREN &&
                    (!Builtins.isBuiltin(name) || name == "Action")
                ) {
                    return parseComp(name)
                }
                adv()
                return AstNode.Ref(name)
            }

            TokType.BUILTIN -> {
                if (peekNext().t == TokType.LPAREN) return parseComp(tok.s)
                adv()
                return AstNode.Ref(tok.s)
            }

            TokType.IDENT -> { adv(); return AstNode.Ref(tok.s) }
            TokType.NOT -> { adv(); return AstNode.UnaryOp("!", parseExpr(PREC_UNARY)) }
            TokType.MINUS -> { adv(); return AstNode.UnaryOp("-", parseExpr(PREC_UNARY)) }
            TokType.LPAREN -> {
                adv()
                val inner = parseExpr(0)
                eat(TokType.RPAREN)
                return inner
            }

            else -> {
                adv() // error recovery: consume the token and yield Null
                return AstNode.Null
            }
        }
    }

    private fun parseInfix(left: AstNode): AstNode {
        val tok = cur()
        return when (tok.t) {
            TokType.PLUS -> { adv(); AstNode.BinOp("+", left, parseExpr(PREC_ADD)) }
            TokType.MINUS -> { adv(); AstNode.BinOp("-", left, parseExpr(PREC_ADD)) }
            TokType.STAR -> { adv(); AstNode.BinOp("*", left, parseExpr(PREC_MUL)) }
            TokType.SLASH -> { adv(); AstNode.BinOp("/", left, parseExpr(PREC_MUL)) }
            TokType.PERCENT -> { adv(); AstNode.BinOp("%", left, parseExpr(PREC_MUL)) }
            TokType.EQEQ -> { adv(); AstNode.BinOp("==", left, parseExpr(PREC_EQ)) }
            TokType.NOTEQ -> { adv(); AstNode.BinOp("!=", left, parseExpr(PREC_EQ)) }
            TokType.GREATER -> { adv(); AstNode.BinOp(">", left, parseExpr(PREC_CMP)) }
            TokType.LESS -> { adv(); AstNode.BinOp("<", left, parseExpr(PREC_CMP)) }
            TokType.GREATER_EQ -> { adv(); AstNode.BinOp(">=", left, parseExpr(PREC_CMP)) }
            TokType.LESS_EQ -> { adv(); AstNode.BinOp("<=", left, parseExpr(PREC_CMP)) }
            TokType.AND -> { adv(); AstNode.BinOp("&&", left, parseExpr(PREC_AND)) }
            TokType.OR -> { adv(); AstNode.BinOp("||", left, parseExpr(PREC_OR)) }
            TokType.QUESTION -> {
                adv()
                val then = parseExpr(0)
                eat(TokType.COLON)
                val orElse = parseExpr(0) // right-assoc: parse at the lowest prec
                AstNode.Ternary(left, then, orElse)
            }

            TokType.DOT -> {
                adv()
                AstNode.Member(left, readKeyLikeToken())
            }

            TokType.LBRACK -> {
                adv()
                val idx = parseExpr(0)
                eat(TokType.RBRACK)
                AstNode.Index(left, idx)
            }

            else -> left // unreachable if infixPrec is correct
        }
    }

    /**
     * Member field / object key extraction. `Ident`, `Type`, string and number
     * tokens contribute their text (numbers stringified with JS
     * `Number::toString`); `$key` has its `$` stripped; anything else becomes
     * `"?"`. In every branch the token IS consumed.
     */
    private fun readKeyLikeToken(): String {
        val tok = cur()
        adv()
        return when (tok.t) {
            TokType.IDENT, TokType.TYPE, TokType.STR -> tok.s
            TokType.NUM -> jsNumberToString(tok.n)
            TokType.STATE_VAR -> if (tok.s.startsWith("$")) tok.s.substring(1) else tok.s
            else -> "?"
        }
    }

    /** Parses `TypeName(arg1, arg2, …)`; [cur] is the name token. */
    private fun parseComp(name: String): AstNode {
        adv() // consume the name token
        eat(TokType.LPAREN)
        val args = ArrayList<AstNode>()
        while (cur().t != TokType.RPAREN && cur().t != TokType.EOF) {
            args.add(parseExpr(0))
            if (cur().t == TokType.COMMA) adv() // a missing comma is tolerated
        }
        eat(TokType.RPAREN)
        return AstNode.Comp(name, args)
    }

    private fun parseArr(): AstNode {
        adv() // skip [
        val els = ArrayList<AstNode>()
        while (cur().t != TokType.RBRACK && cur().t != TokType.EOF) {
            els.add(parseExpr(0))
            if (cur().t == TokType.COMMA) adv()
        }
        eat(TokType.RBRACK)
        return AstNode.Arr(els)
    }

    private fun parseObj(): AstNode {
        adv() // skip {
        val entries = ArrayList<Pair<String, AstNode>>()
        while (cur().t != TokType.RBRACE && cur().t != TokType.EOF) {
            val key = readKeyLikeToken()
            eat(TokType.COLON)
            entries.add(key to parseExpr(0))
            if (cur().t == TokType.COMMA) adv()
        }
        eat(TokType.RBRACE)
        return AstNode.Obj(entries)
    }
}
