import Foundation

/// Insertion-ordered map used for statement caches and state declarations.
/// `set` on an existing key overwrites the value but keeps the original key
/// position (JS `Map.set` semantics). Keyed on `JSKey` (UTF-16 code-unit
/// identity) to mirror JS `Map` — statement ids and `$state` names are
/// ASCII-only under the current lexer, so this is defense-in-depth rather
/// than an observable fix.
struct OrderedMap<Value> {
    private(set) var keys: [String] = []
    private var storage: [JSKey: Value] = [:]

    subscript(key: String) -> Value? {
        get { storage[JSKey(key)] }
        set {
            guard let newValue else { return }
            let k = JSKey(key)
            if storage[k] == nil { keys.append(key) }
            storage[k] = newValue
        }
    }

    func has(_ key: String) -> Bool { storage[JSKey(key)] != nil }
    var values: [Value] { keys.map { storage[JSKey($0)]! } }
    var count: Int { keys.count }
    var isEmpty: Bool { keys.isEmpty }
}

/// The pre-runtime-evaluation parse result (lang-core `ParseResult` minus the
/// query/mutation statement lists, which are always empty for AppLess).
struct InternalResult {
    var root: RTElement?
    var incomplete: Bool
    var unresolved: [String]
    var errors: [ParseError]
    var stateDeclarations: OrderedMap<RTValue>

    static func empty(incomplete: Bool = true) -> InternalResult {
        InternalResult(
            root: nil, incomplete: incomplete, unresolved: [], errors: [],
            stateDeclarations: OrderedMap<RTValue>())
    }
}

private let defaultRootStatementId = "root"

func isComponentStatement(_ stmt: TypedStatement) -> Bool {
    guard stmt.kind == .value, case .comp(let name, _, _) = stmt.expr else { return false }
    return !Builtins.isBuiltin(name) && !Builtins.isReservedCall(name)
}

func pickEntryId(
    _ stmtMap: OrderedMap<TypedStatement>, _ typedStmts: [TypedStatement],
    _ firstId: String, _ rootName: String?
) -> String {
    if stmtMap.has(defaultRootStatementId) { return defaultRootStatementId }
    if let rootName, stmtMap.has(rootName) { return rootName }
    if let rootName {
        let preferred = typedStmts.first { stmt in
            guard isComponentStatement(stmt), case .comp(let name, _, _) = stmt.expr else {
                return false
            }
            return name == rootName
        }
        if let preferred { return preferred.id }
    }
    if let firstComponent = typedStmts.first(where: isComponentStatement) {
        return firstComponent.id
    }
    return firstId
}

/// Port of `extractStatements`: materialize state defaults and auto-declare
/// referenced-but-undeclared `$vars` with `null`.
private func extractStatements(
    _ stmts: [TypedStatement], _ ctx: MaterializeContext
) -> OrderedMap<RTValue> {
    var stateDeclarations = OrderedMap<RTValue>()
    for stmt in stmts where stmt.kind == .state {
        stateDeclarations[stmt.id] = materializeValue(stmt.expr, ctx)
    }
    for stmt in stmts {
        let nodes: [ASTNode]
        switch stmt.kind {
        case .state, .value:
            nodes = [stmt.expr]
        case .query, .mutation:
            if case .comp(_, let args, _) = stmt.expr {
                nodes = args
            } else {
                nodes = []
            }
        }
        for node in nodes {
            for dep in collectStateRefs(node) where !stateDeclarations.has(dep) {
                stateDeclarations[dep] = .null
            }
        }
    }
    return stateDeclarations
}

/// Port of `buildResult` (spec/openui-lang.md §8.1 entry selection).
func buildResult(
    stmtMap: OrderedMap<TypedStatement>,
    typedStmts: [TypedStatement],
    firstId: String,
    wasIncomplete: Bool,
    cat: [String: [LibrarySchema.Param]],
    rootName: String?
) -> InternalResult {
    let entryId = pickEntryId(stmtMap, typedStmts, firstId, rootName)
    guard stmtMap.has(entryId) else {
        return .empty(incomplete: wasIncomplete)
    }
    var syms: [String: ASTNode] = [:]
    for id in stmtMap.keys {
        syms[id] = stmtMap[id]!.expr
    }

    let ctx = MaterializeContext(
        syms: syms, cat: cat, partial: wasIncomplete, currentStatementId: entryId)
    let materialized = materializeValue(syms[entryId]!, ctx)
    var root: RTElement? = nil
    if case .element(var el) = materialized {
        el.statementId = entryId
        root = el
    }
    let stateDeclarations = extractStatements(typedStmts, ctx)
    return InternalResult(
        root: root,
        incomplete: wasIncomplete,
        unresolved: ctx.unres,
        errors: ctx.errors,
        stateDeclarations: stateDeclarations
    )
}

/// Port of lang-core `createStreamParser` — the incremental statement scanner
/// with prefix-extension caching (spec/openui-lang.md §10 streaming
/// semantics; §10.1 architecture, §10.2 set() reset rule, §10.6 duplicate
/// ids). This is the single parsing entry point; the batch parser is
/// `set(fullText)` on a fresh instance (matching how the fixture generator
/// drives the reference implementation).
final class StreamCore {
    private let cat: [String: [LibrarySchema.Param]]
    private let rootName: String?

    private var buf: [Character] = []
    private var bufString: String = ""
    private var completedEnd = 0
    private var completedStmtMap = OrderedMap<TypedStatement>()
    private var completedCount = 0
    private var firstId = ""

    init(schema: LibrarySchema) {
        self.cat = schema.paramOrder
        self.rootName = schema.root
    }

    @discardableResult
    func set(_ fullText: String) -> InternalResult {
        // JS: `fullText.length < buf.length || !fullText.startsWith(buf)` and
        // `fullText.slice(buf.length)` — all in UTF-16 code units. Swift's
        // `count`/`hasPrefix`/`dropFirst` work on grapheme clusters with
        // canonical matching, which would (a) accept an NFC/NFD variant as a
        // prefix-extension where JS resets, and (b) mis-slice the delta when
        // a combining mark merges into the previous cluster.
        let newUnits = Array(fullText.utf16)
        if newUnits.count < bufString.utf16.count
            || !newUnits.starts(with: bufString.utf16)
        {
            reset()
        }
        let prefixCount = bufString.utf16.count
        if newUnits.count > prefixCount {
            let delta = String(decoding: newUnits[prefixCount...], as: UTF16.self)
            buf.append(contentsOf: delta)
            bufString = fullText
        }
        return currentResult()
    }

    private func reset() {
        buf = []
        bufString = ""
        completedEnd = 0
        completedStmtMap = OrderedMap<TypedStatement>()
        completedCount = 0
        firstId = ""
    }

    private func addStmt(_ text: String) {
        let cleaned = stripComments(text).jsTrim()
        if cleaned.isEmpty || jsStringHasPrefix(cleaned, "```") { return }
        for s in splitStatements(tokenize(Array(cleaned))) {
            let expr = parseExpression(s.tokens)
            let stmt = classifyStatement(s, expr)
            completedStmtMap[s.id] = stmt
            completedCount += 1
            if firstId.isEmpty { firstId = s.id }
        }
    }

    /// Scan `buf` from the watermark for newly completed statements.
    /// Returns the start index of the current pending (incomplete) statement.
    private func scanNewCompleted() -> Int {
        var depth = 0
        var ternaryDepth = 0
        var inStr: Character? = nil
        var esc = false
        var stmtStart = completedEnd
        var i = completedEnd
        while i < buf.count {
            let c = buf[i]
            if esc {
                esc = false
                i += 1
                continue
            }
            if c == "\\" && inStr != nil {
                esc = true
                i += 1
                continue
            }
            if let q = inStr {
                if c == q { inStr = nil }
                i += 1
                continue
            }
            if c == "\"" || c == "'" {
                inStr = c
                i += 1
                continue
            }
            if c == "(" || c == "[" || c == "{" {
                depth += 1
            } else if c == ")" || c == "]" || c == "}" {
                depth = max(0, depth - 1)
            } else if c == "?" && depth == 0 {
                ternaryDepth += 1
            } else if c == ":" && depth == 0 && ternaryDepth > 0 {
                ternaryDepth -= 1
            } else if c == "\n" && depth <= 0 && ternaryDepth <= 0 {
                // Look ahead past whitespace — ternary continuation?
                var peek = i + 1
                while peek < buf.count,
                    buf[peek] == " " || buf[peek] == "\t" || buf[peek] == "\r" || buf[peek] == "\n"
                {
                    peek += 1
                }
                if peek < buf.count,
                    buf[peek] == "?" || (buf[peek] == ":" && ternaryDepth > 0)
                {
                    i += 1
                    continue // ternary continuation — don't split
                }
                let t = String(buf[stmtStart..<i]).jsTrim()
                if !t.isEmpty { addStmt(t) }
                stmtStart = i + 1
                completedEnd = i + 1
            }
            i += 1
        }
        return stmtStart
    }

    func currentResult() -> InternalResult {
        let pendingStart = scanNewCompleted()
        let pendingText = String(buf[min(pendingStart, buf.count)...]).jsTrim()

        func completedOnly(_ incomplete: Bool) -> InternalResult {
            if completedCount == 0 { return .empty() }
            return buildResult(
                stmtMap: completedStmtMap, typedStmts: completedStmtMap.values,
                firstId: firstId, wasIncomplete: incomplete, cat: cat, rootName: rootName)
        }

        if pendingText.isEmpty {
            return completedOnly(false)
        }
        let cleaned = stripComments(stripFences(pendingText)).jsTrim()
        if cleaned.isEmpty {
            return completedOnly(false)
        }
        let closed = autoClose(Array(cleaned))
        let stmts = splitStatements(tokenize(closed.text))
        if stmts.isEmpty {
            if completedCount == 0 { return .empty(incomplete: closed.wasIncomplete) }
            return buildResult(
                stmtMap: completedStmtMap, typedStmts: completedStmtMap.values,
                firstId: firstId, wasIncomplete: closed.wasIncomplete, cat: cat,
                rootName: rootName)
        }
        // Merge: completed cache + re-parsed pending statements. Pending
        // statements can only add NEW ids — they cannot overwrite completed.
        var allStmtMap = completedStmtMap
        for s in stmts {
            if completedStmtMap.has(s.id) { continue }
            let expr = parseExpression(s.tokens)
            allStmtMap[s.id] = classifyStatement(s, expr)
        }
        let fid = firstId.isEmpty ? stmts[0].id : firstId
        return buildResult(
            stmtMap: allStmtMap, typedStmts: allStmtMap.values, firstId: fid,
            wasIncomplete: closed.wasIncomplete, cat: cat, rootName: rootName)
    }
}
