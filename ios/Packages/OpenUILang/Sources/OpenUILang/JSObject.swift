import Foundation

/// THE JS plain-object model — one shared abstraction for every lookup the
/// reference implementation performs with `[]`, `in` or `.`.
///
/// Why this file exists at all: lang-core is written in idiomatic JavaScript,
/// so a "plain object" there is never just a map. It carries a `[[Prototype]]`,
/// and three separate families of port bugs all reduced to modelling it as one:
///
///  1. `BUILTINS[node.name]` (evaluator.js:48) is a property GET on an object
///     literal, so it also answers for the twelve `Object.prototype` own names.
///     `@toString(1)` therefore finds `Object.prototype.toString`, reads `.fn`
///     off it (undefined) and calls it — `TypeError: builtin.fn is not a
///     function`, which `evaluate-tree.js` catches into `runtimeErrors`.
///  2. `o["__proto__"] = v` (materialize.js's `Obj` case, evaluate-prop.js's
///     object rebuild) is not a dropped key: it invokes `Object.prototype`'s
///     `__proto__` SETTER and re-points the receiver's `[[Prototype]]`, which
///     lang-core's duck-typing (`isASTNode`, `isElementNode`,
///     `containsDynamicValue`, and the serializer's `isAstNode`) then reads
///     THROUGH.
///  3. `obj.toString` / `obj.constructor` are ordinary member accesses that
///     inherit real function values from the prototype chain.
///
/// Everything the port needs to answer those questions lives here:
/// `prototypeOwnNames` (and its siblings) describe the intrinsics,
/// `prototypeOf` gives every runtime value its `[[Prototype]]`, and `getMember`
/// / `hasProperty` are the single implementations of `.`/`[]` and `in`.
///
/// Mirrors `JsObject.kt`.

/// One own property of an intrinsic prototype object.
enum JSMember {
    /// A native function, rendered `function <name>() { [native code] }`.
    case fn(name: String, arity: Int)
    /// A plain data property (`Array.prototype.length`, `Function.prototype.name`).
    case data(RTValue)
    /// `Object.prototype.__proto__` — an ACCESSOR pair. The getter answers the
    /// RECEIVER's `[[Prototype]]`; the setter re-points it (`RTObject.assign`).
    case protoAccessor
    /// `Function.prototype.arguments` / `.caller` — accessors that always throw
    /// in strict mode (all module code is strict).
    case poisonPill
}

/// The intrinsic prototype objects this value model can reach.
enum JSProtoKind {
    case object, array, number, string, boolean, function
}

/// Build a code-unit-keyed lookup table from V8's own enumeration order.
private func jsTable(_ pairs: [(String, JSMember)]) -> [String: JSMember] {
    var out: [String: JSMember] = [:]
    for (k, v) in pairs { out[k] = v }
    return out
}

enum JSObjects {
    /// V8's message when `Function.prototype.arguments`/`.caller` is read.
    static let poisonPillMessage =
        "'caller', 'callee', and 'arguments' properties may not be accessed on "
        + "strict mode functions or the arguments objects for calls to them"

    /// V8's message for `BUILTINS[name].fn(...)` when `.fn` is undefined.
    static let builtinFnMessage = "builtin.fn is not a function"

    /// The `__proto__` key — the one key plain-object ASSIGNMENT never creates.
    static let protoKey = "__proto__"

    // MARK: - Intrinsic own-property tables
    //
    // Generated verbatim from V8 (`Object.getOwnPropertyNames(X.prototype)`
    // plus each descriptor's kind, function name and arity).

    nonisolated(unsafe) static let objectOwn: [String: JSMember] = jsTable([
        ("constructor", .fn(name: "Object", arity: 1)),
        ("__defineGetter__", .fn(name: "__defineGetter__", arity: 2)),
        ("__defineSetter__", .fn(name: "__defineSetter__", arity: 2)),
        ("hasOwnProperty", .fn(name: "hasOwnProperty", arity: 1)),
        ("__lookupGetter__", .fn(name: "__lookupGetter__", arity: 1)),
        ("__lookupSetter__", .fn(name: "__lookupSetter__", arity: 1)),
        ("isPrototypeOf", .fn(name: "isPrototypeOf", arity: 1)),
        ("propertyIsEnumerable", .fn(name: "propertyIsEnumerable", arity: 1)),
        ("toString", .fn(name: "toString", arity: 0)),
        ("valueOf", .fn(name: "valueOf", arity: 0)),
        ("__proto__", .protoAccessor),
        ("toLocaleString", .fn(name: "toLocaleString", arity: 0)),
    ])

    nonisolated(unsafe) static let arrayOwn: [String: JSMember] = jsTable([
        ("length", .data(.number(0))),
        ("constructor", .fn(name: "Array", arity: 1)),
        ("at", .fn(name: "at", arity: 1)),
        ("concat", .fn(name: "concat", arity: 1)),
        ("copyWithin", .fn(name: "copyWithin", arity: 2)),
        ("fill", .fn(name: "fill", arity: 1)),
        ("find", .fn(name: "find", arity: 1)),
        ("findIndex", .fn(name: "findIndex", arity: 1)),
        ("findLast", .fn(name: "findLast", arity: 1)),
        ("findLastIndex", .fn(name: "findLastIndex", arity: 1)),
        ("lastIndexOf", .fn(name: "lastIndexOf", arity: 1)),
        ("pop", .fn(name: "pop", arity: 0)),
        ("push", .fn(name: "push", arity: 1)),
        ("reverse", .fn(name: "reverse", arity: 0)),
        ("shift", .fn(name: "shift", arity: 0)),
        ("unshift", .fn(name: "unshift", arity: 1)),
        ("slice", .fn(name: "slice", arity: 2)),
        ("sort", .fn(name: "sort", arity: 1)),
        ("splice", .fn(name: "splice", arity: 2)),
        ("includes", .fn(name: "includes", arity: 1)),
        ("indexOf", .fn(name: "indexOf", arity: 1)),
        ("join", .fn(name: "join", arity: 1)),
        ("keys", .fn(name: "keys", arity: 0)),
        ("entries", .fn(name: "entries", arity: 0)),
        ("values", .fn(name: "values", arity: 0)),
        ("forEach", .fn(name: "forEach", arity: 1)),
        ("filter", .fn(name: "filter", arity: 1)),
        ("flat", .fn(name: "flat", arity: 0)),
        ("flatMap", .fn(name: "flatMap", arity: 1)),
        ("map", .fn(name: "map", arity: 1)),
        ("every", .fn(name: "every", arity: 1)),
        ("some", .fn(name: "some", arity: 1)),
        ("reduce", .fn(name: "reduce", arity: 1)),
        ("reduceRight", .fn(name: "reduceRight", arity: 1)),
        ("toReversed", .fn(name: "toReversed", arity: 0)),
        ("toSorted", .fn(name: "toSorted", arity: 1)),
        ("toSpliced", .fn(name: "toSpliced", arity: 2)),
        ("with", .fn(name: "with", arity: 2)),
        ("toLocaleString", .fn(name: "toLocaleString", arity: 0)),
        ("toString", .fn(name: "toString", arity: 0)),
    ])

    nonisolated(unsafe) static let numberOwn: [String: JSMember] = jsTable([
        ("constructor", .fn(name: "Number", arity: 1)),
        ("toExponential", .fn(name: "toExponential", arity: 1)),
        ("toFixed", .fn(name: "toFixed", arity: 1)),
        ("toPrecision", .fn(name: "toPrecision", arity: 1)),
        ("toString", .fn(name: "toString", arity: 1)),
        ("valueOf", .fn(name: "valueOf", arity: 0)),
        ("toLocaleString", .fn(name: "toLocaleString", arity: 0)),
    ])

    nonisolated(unsafe) static let stringOwn: [String: JSMember] = jsTable([
        ("length", .data(.number(0))),
        ("constructor", .fn(name: "String", arity: 1)),
        ("anchor", .fn(name: "anchor", arity: 1)),
        ("at", .fn(name: "at", arity: 1)),
        ("big", .fn(name: "big", arity: 0)),
        ("blink", .fn(name: "blink", arity: 0)),
        ("bold", .fn(name: "bold", arity: 0)),
        ("charAt", .fn(name: "charAt", arity: 1)),
        ("charCodeAt", .fn(name: "charCodeAt", arity: 1)),
        ("codePointAt", .fn(name: "codePointAt", arity: 1)),
        ("concat", .fn(name: "concat", arity: 1)),
        ("endsWith", .fn(name: "endsWith", arity: 1)),
        ("fontcolor", .fn(name: "fontcolor", arity: 1)),
        ("fontsize", .fn(name: "fontsize", arity: 1)),
        ("fixed", .fn(name: "fixed", arity: 0)),
        ("includes", .fn(name: "includes", arity: 1)),
        ("indexOf", .fn(name: "indexOf", arity: 1)),
        ("isWellFormed", .fn(name: "isWellFormed", arity: 0)),
        ("italics", .fn(name: "italics", arity: 0)),
        ("lastIndexOf", .fn(name: "lastIndexOf", arity: 1)),
        ("link", .fn(name: "link", arity: 1)),
        ("localeCompare", .fn(name: "localeCompare", arity: 1)),
        ("match", .fn(name: "match", arity: 1)),
        ("matchAll", .fn(name: "matchAll", arity: 1)),
        ("normalize", .fn(name: "normalize", arity: 0)),
        ("padEnd", .fn(name: "padEnd", arity: 1)),
        ("padStart", .fn(name: "padStart", arity: 1)),
        ("repeat", .fn(name: "repeat", arity: 1)),
        ("replace", .fn(name: "replace", arity: 2)),
        ("replaceAll", .fn(name: "replaceAll", arity: 2)),
        ("search", .fn(name: "search", arity: 1)),
        ("slice", .fn(name: "slice", arity: 2)),
        ("small", .fn(name: "small", arity: 0)),
        ("split", .fn(name: "split", arity: 2)),
        ("strike", .fn(name: "strike", arity: 0)),
        ("sub", .fn(name: "sub", arity: 0)),
        ("substr", .fn(name: "substr", arity: 2)),
        ("substring", .fn(name: "substring", arity: 2)),
        ("sup", .fn(name: "sup", arity: 0)),
        ("startsWith", .fn(name: "startsWith", arity: 1)),
        ("toString", .fn(name: "toString", arity: 0)),
        ("toWellFormed", .fn(name: "toWellFormed", arity: 0)),
        ("trim", .fn(name: "trim", arity: 0)),
        ("trimStart", .fn(name: "trimStart", arity: 0)),
        ("trimLeft", .fn(name: "trimStart", arity: 0)),
        ("trimEnd", .fn(name: "trimEnd", arity: 0)),
        ("trimRight", .fn(name: "trimEnd", arity: 0)),
        ("toLocaleLowerCase", .fn(name: "toLocaleLowerCase", arity: 0)),
        ("toLocaleUpperCase", .fn(name: "toLocaleUpperCase", arity: 0)),
        ("toLowerCase", .fn(name: "toLowerCase", arity: 0)),
        ("toUpperCase", .fn(name: "toUpperCase", arity: 0)),
        ("valueOf", .fn(name: "valueOf", arity: 0)),
    ])

    nonisolated(unsafe) static let booleanOwn: [String: JSMember] = jsTable([
        ("constructor", .fn(name: "Boolean", arity: 1)),
        ("toString", .fn(name: "toString", arity: 0)),
        ("valueOf", .fn(name: "valueOf", arity: 0)),
    ])

    nonisolated(unsafe) static let functionOwn: [String: JSMember] = jsTable([
        ("length", .data(.number(0))),
        ("name", .data(.string(""))),
        ("arguments", .poisonPill),
        ("caller", .poisonPill),
        ("constructor", .fn(name: "Function", arity: 1)),
        ("apply", .fn(name: "apply", arity: 2)),
        ("bind", .fn(name: "bind", arity: 1)),
        ("call", .fn(name: "call", arity: 1)),
        ("toString", .fn(name: "toString", arity: 0)),
    ])


    /// `Object.prototype`'s own property names — THE table the whole file
    /// exists for. Every lookup lang-core performs on a plain object literal
    /// (`BUILTINS[name]`, `name in RESERVED_CALLS`, `obj.field`) falls through
    /// to exactly these twelve names when the own lookup misses.
    static var prototypeOwnNames: [String: JSMember] { objectOwn }

    static func intrinsicOwn(_ kind: JSProtoKind) -> [String: JSMember] {
        switch kind {
        case .object: return objectOwn
        case .array: return arrayOwn
        case .number: return numberOwn
        case .string: return stringOwn
        case .boolean: return booleanOwn
        case .function: return functionOwn
        }
    }

    /// The default `[[Prototype]]` of a plain object literal.
    nonisolated(unsafe) static let objectPrototype: RTValue = .proto(.object)

    // MARK: - The chain

    /// `Object.getPrototypeOf(v)` — `nil` means the value has no
    /// `[[Prototype]]` concept at all (`undefined` / `null`, where JS throws on
    /// member access); `.null` means a genuinely prototype-less object.
    static func prototypeOf(_ v: RTValue) -> RTValue? {
        switch v {
        case .undefined, .null: return nil
        case .object(let o): return o.prototype
        case .array: return .proto(.array)
        case .number: return .proto(.number)
        case .string: return .proto(.string)
        case .bool: return .proto(.boolean)
        case .function: return .proto(.function)
        // ElementNodes and AST nodes are plain object literals in JS.
        case .element, .ast: return objectPrototype
        case .proto(let kind): return kind == .object ? .null : objectPrototype
        }
    }

    /// The own property's value, or `nil` when the key is not own.
    private static func ownMember(_ v: RTValue, _ key: String) -> JSMember? {
        switch v {
        case .object(let o):
            return o[key].map { .data($0) }
        case .proto(let kind):
            return intrinsicOwn(kind)[key]
        case .function(let name, let arity):
            if key == "length" { return .data(.number(Double(arity))) }
            if key == "name" { return .data(.string(name)) }
            return nil
        case .array(let items):
            if key == "length" { return .data(.number(Double(items.count))) }
            if let i = jsCanonicalArrayIndex(key), Int(i) < items.count {
                return .data(items[Int(i)])
            }
            return nil
        case .string(let s):
            let units = Array(s.utf16)
            if key == "length" { return .data(.number(Double(units.count))) }
            if let i = jsCanonicalArrayIndex(key), Int(i) < units.count {
                return .data(.string(String(utf16CodeUnits: [units[Int(i)]], count: 1)))
            }
            return nil
        // An ElementNode is a plain object of its own fields; so is an AST node.
        case .element(let el):
            return elementOwn(el, key).map { .data($0) }
        case .ast(let node):
            return astOwn(node, key).map { .data($0) }
        case .number, .bool, .undefined, .null:
            return nil
        }
    }

    /// `receiver[key]` — own lookup, then the whole prototype chain.
    static func getMember(_ receiver: RTValue, _ key: String) throws -> RTValue {
        try getMemberWithOwner(receiver, key)?.value ?? .undefined
    }

    /// `getMember` plus the chain link the property was found on — needed by
    /// `ToPrimitive`, which behaves differently depending on WHICH intrinsic
    /// `toString` it ended up resolving.
    static func getMemberWithOwner(
        _ receiver: RTValue, _ key: String
    ) throws -> (value: RTValue, owner: RTValue)? {
        var cur = receiver
        while true {
            if let own = ownMember(cur, key) {
                let value: RTValue
                switch own {
                case .data(let v): value = v
                case .fn(let name, let arity): value = .function(name: name, arity: arity)
                // The getter answers the RECEIVER's prototype, not the
                // prototype of the link the accessor was found on.
                case .protoAccessor: value = prototypeOf(receiver) ?? .undefined
                case .poisonPill: throw JSTypeError(message: poisonPillMessage)
                }
                return (value, cur)
            }
            guard let proto = prototypeOf(cur) else { return nil }
            if case .null = proto { return nil }
            cur = proto
        }
    }

    /// The `in` operator: own lookup plus the whole prototype chain.
    static func hasProperty(_ receiver: RTValue, _ key: String) -> Bool {
        var cur = receiver
        while true {
            if ownMember(cur, key) != nil { return true }
            guard let proto = prototypeOf(cur) else { return false }
            if case .null = proto { return false }
            cur = proto
        }
    }

    /// True when the receiver still inherits `Object.prototype`'s `__proto__`
    /// SETTER — the precondition for `o["__proto__"] = v` re-pointing the
    /// prototype instead of creating an own key (an object whose chain was cut
    /// with `"__proto__": null` has no setter, so there assignment DOES create
    /// an own key).
    static func inheritsProtoAccessor(_ start: RTValue) -> Bool {
        var cur = prototypeOf(start)
        while let link = cur {
            if case .null = link { return false }
            if case .protoAccessor? = ownMember(link, protoKey) { return true }
            cur = prototypeOf(link)
        }
        return false
    }

    // MARK: - Own fields of the port's structured objects

    private static func elementOwn(_ el: RTElement, _ key: String) -> RTValue? {
        switch key {
        case "type": return .string("element")
        case "typeName": return .string(el.typeName)
        case "props": return .object(el.props)
        case "partial": return .bool(el.partial)
        case "hasDynamicProps": return .bool(el.hasDynamicProps)
        case "statementId": return el.statementId.map { .string($0) }
        default: return nil
        }
    }

    /// The own fields of an AST node, which is a plain object literal in JS.
    private static func astOwn(_ node: ASTNode, _ key: String) -> RTValue? {
        if key == "k" { return .string(node.kindTag) }
        switch node {
        case .str(let v): return key == "v" ? .string(v) : nil
        case .num(let v): return key == "v" ? .number(v) : nil
        case .bool(let v): return key == "v" ? .bool(v) : nil
        case .null: return nil
        case .ph(let n), .ref(let n), .stateRef(let n): return key == "n" ? .string(n) : nil
        case .runtimeRef(let n, let refType):
            if key == "n" { return .string(n) }
            if key == "refType" { return .string(refType) }
            return nil
        case .arr(let els):
            return key == "els" ? .array(els.map { .ast($0) }) : nil
        case .obj(let entries):
            guard key == "entries" else { return nil }
            return .array(entries.map { .array([.string($0.key), .ast($0.value)]) })
        case .comp(let name, let args, let mappedProps):
            if key == "name" { return .string(name) }
            if key == "args" { return .array(args.map { .ast($0) }) }
            if key == "mappedProps" {
                guard let mapped = mappedProps else { return nil }
                var o = RTObject()
                for (k, v) in mapped { o[k] = .ast(v) }
                return .object(o)
            }
            return nil
        case .binOp(let op, let left, let right):
            if key == "op" { return .string(op) }
            if key == "left" { return .ast(left) }
            if key == "right" { return .ast(right) }
            return nil
        case .unaryOp(let op, let operand):
            if key == "op" { return .string(op) }
            if key == "operand" { return .ast(operand) }
            return nil
        case .ternary(let cond, let then, let elseNode):
            if key == "cond" { return .ast(cond) }
            if key == "then" { return .ast(then) }
            if key == "else" { return .ast(elseNode) }
            return nil
        case .member(let obj, let field):
            if key == "obj" { return .ast(obj) }
            if key == "field" { return .string(field) }
            return nil
        case .index(let obj, let index):
            if key == "obj" { return .ast(obj) }
            if key == "index" { return .ast(index) }
            return nil
        case .assign(let target, let value):
            if key == "target" { return .string(target) }
            if key == "value" { return .ast(value) }
            return nil
        }
    }

    // MARK: - Duck-typing, prototype-chain aware

    /// `parser/ast.js` `isASTNode(value)`: an object (not an array) whose `k` —
    /// read through the PROTOTYPE CHAIN — is one of the AST discriminants.
    ///
    /// Returns the underlying node when the port can name it. A value inherits
    /// AST-ness from a real `.ast` link in its chain; a plain object that
    /// merely *looks* like an AST node without one is KNOWN-DEVIATION #6 (see
    /// README) and answers `nil` here, as before.
    static func astNodeView(_ v: RTValue) -> ASTNode? {
        if case .ast(let node) = v { return node }
        guard case .object(let o) = v else { return nil }
        // An own `k` shadows the chain — deviation #6 territory.
        if o.has("k") { return nil }
        var cur = prototypeOf(v)
        while let link = cur {
            if case .null = link { return nil }
            if case .ast(let node) = link { return node }
            if case .object(let lo) = link, lo.has("k") { return nil }
            cur = prototypeOf(link)
        }
        return nil
    }

    /// The serializer's looser `isAstNode(v)`: ANY object (not an array) whose
    /// `k` is a string, AST discriminant or not (serialize.mjs:14).
    static func serializerIsAstNode(_ v: RTValue) -> Bool {
        if case .ast = v { return true }
        switch v {
        case .object, .element, .proto, .function:
            if case .string? = try? getMember(v, "k") { return true }
            return false
        default:
            return false
        }
    }

    /// `parser/types.js` `isElementNode(value)`, read through the prototype
    /// chain: `type === "element"`, string `typeName`, non-null object `props`,
    /// boolean `partial`.
    static func elementView(_ v: RTValue) -> RTElement? {
        if case .element(let el) = v { return el }
        guard case .object(let o) = v else { return nil }
        // Own fields shadowing the inherited element identity are deviation #6.
        if o.has("type") || o.has("typeName") { return nil }
        var cur = prototypeOf(v)
        while let link = cur {
            if case .null = link { return nil }
            if case .element(let el) = link { return el }
            if case .object(let lo) = link, lo.has("type") || lo.has("typeName") { return nil }
            cur = prototypeOf(link)
        }
        return nil
    }
}
