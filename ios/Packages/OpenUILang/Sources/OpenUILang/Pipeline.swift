import Foundation

/// Replays the app's steady-state Renderer pipeline on a parse result
/// (spec/openui-lang.md §1 processing pipeline, Appendix A result shapes):
/// initialize the state store from declarations, evaluate the root element's
/// props, and convert everything into the public (serializable) shapes.
enum Pipeline {
    static func run(_ internalResult: InternalResult) -> ParseResult {
        // Store initialization: defaults only (no persisted values).
        var store: [String: RTValue] = [:]
        for key in internalResult.stateDeclarations.keys {
            store[key] = internalResult.stateDeclarations[key]!
        }
        let evaluator = Evaluator(store: store)
        let evaluatedRoot = internalResult.root.map { evaluator.evaluateElementProps($0) }

        var state: [String: PropValue] = [:]
        for key in internalResult.stateDeclarations.keys {
            state[key] = convertValue(internalResult.stateDeclarations[key]!)
        }

        return ParseResult(
            root: evaluatedRoot.map { convertElement($0) },
            meta: ParseMeta(
                incomplete: internalResult.incomplete,
                unresolved: internalResult.unresolved,
                errors: internalResult.errors
            ),
            state: state,
            // Populated by `Evaluator.evaluateElementProps`'s per-prop catch —
            // the JS `evalCtx.errors` array (fixture
            // `081-tostring-shadow-throws`).
            runtimeErrors: evaluator.runtimeErrors
        )
    }

    // MARK: - RTValue → PropValue conversion (mirrors serialize.mjs)

    static func convertElement(_ el: RTElement) -> ElementNode {
        var props: [String: PropValue] = [:]
        var children: PropValue? = nil
        for (key, value) in el.props.entries {
            if value.isDroppedByJSONStringify { continue }
            if key == "children" {
                children = convertValue(value)
            } else {
                props[key] = convertValue(value)
            }
        }
        return ElementNode(
            component: el.typeName,
            statementId: el.statementId,
            props: props,
            children: children
        )
    }

    static func convertValue(_ v: RTValue) -> PropValue {
        switch v {
        // `JSON.stringify` drops a function-valued property exactly like an
        // `undefined` one (and writes `null` for one inside an array), so a
        // native function inherited from a prototype serializes as nothing.
        case .undefined, .null, .function:
            return .null
        case .bool(let b):
            return .bool(b)
        case .number(let n):
            return .number(n)
        case .string(let s):
            return .string(s)
        case .array(let items):
            return .array(items.map { convertValue($0) })
        case .element(let el):
            return .element(convertElement(el))
        // Array.prototype is an empty array; every other intrinsic prototype
        // is an object with no enumerable own keys.
        case .proto(let kind):
            return kind == .array ? .array([]) : .object(PropObject())
        case .object(let o):
            // serialize.mjs tests in this order, and every test reads through
            // the PROTOTYPE CHAIN (`v.type`, `v.steps`, `"type" in v`, `v.k`)
            // while the plain-object fallback enumerates OWN keys only. So a
            // `{"__proto__": TextContent(…), …}` row serializes as the
            // inherited ELEMENT (fixture `086-proto-component-valued`), and a row whose prototype is
            // an AST node serializes as `{"$ast": <own keys>}` (fixture `085-proto-object-valued`).
            if let el = JSObjects.elementView(v) {
                return .element(convertElement(el))
            }
            // ActionPlan: { steps: [...] }
            if case .array(let steps) = (try? JSObjects.getMember(v, "steps")) ?? .undefined {
                return .action(ActionPlan(steps: steps.map { convertStep($0) }))
            }
            // Bare ActionStep with deferred AST: { type, valueAST }
            if JSObjects.hasProperty(v, "type") && JSObjects.hasProperty(v, "valueAST") {
                return .action(ActionPlan(steps: [convertStep(v)]))
            }
            // serialize.mjs `isAstNode` duck-types ANY object whose `k` is a
            // string as an AST node and wraps it as {"$ast": ...} — including
            // data objects the author happened to shape that way, e.g. a
            // KVList row `{k: "a", v: 1}`. Replicate the quirk (the sibling
            // steps-array → ActionPlan quirk above is replicated the same way).
            if JSObjects.serializerIsAstNode(v) {
                return .ast(convertAstPlain(v))
            }
            return .object(convertPlainObject(o))
        case .ast(let node):
            return .ast(convertAST(node))
        }
    }

    /// serialize.mjs `serializeAst`: a deep plain-JSON conversion applied to
    /// values inside an `$ast` wrapper. Unlike `convertValue` it never
    /// re-detects ActionPlans/ActionSteps/elements — nested objects stay plain
    /// objects (keys sorted by the serializer, `undefined` entries dropped),
    /// nested elements are spread as plain objects of their own fields, and
    /// non-finite numbers still become `{"$number": ...}` (sanitizeNumber).
    private static func convertAstPlain(_ v: RTValue) -> PropValue {
        switch v {
        case .undefined, .null, .function:
            return .null
        case .proto(let kind):
            return kind == .array ? .array([]) : .object(PropObject())
        case .bool(let b):
            return .bool(b)
        case .number(let n):
            return .number(n)
        case .string(let s):
            return .string(s)
        case .array(let items):
            return .array(items.map { convertAstPlain($0) })
        case .object(let o):
            var out = PropObject()
            for (key, value) in o.entries {
                if value.isDroppedByJSONStringify { continue }
                jsAssign(&out, key, convertAstPlain(value))
            }
            return .object(out)
        case .element(let el):
            // In JS an ElementNode is itself a plain object of its fields.
            var out: PropObject = [
                "type": .string("element"),
                "typeName": .string(el.typeName),
                "props": convertAstPlain(.object(el.props)),
                "partial": .bool(el.partial),
                "hasDynamicProps": .bool(el.hasDynamicProps),
            ]
            if let sid = el.statementId {
                out["statementId"] = .string(sid)
            }
            return .object(out)
        case .ast(let node):
            return convertAST(node)
        }
    }

    private static func convertPlainObject(_ o: RTObject) -> PropObject {
        var out = PropObject()
        for (key, value) in o.entries {
            if value.isDroppedByJSONStringify { continue }
            jsAssign(&out, key, convertValue(value))
        }
        return out
    }

    /// serialize.mjs writes its output objects with `out[key] = …` — plain JS
    /// ASSIGNMENT, which routes `"__proto__"` through `Object.prototype`'s
    /// setter and never creates an own key. So even where a `__proto__` entry
    /// survived materialization/evaluation (`Object.fromEntries` in
    /// `evaluator.js`'s Obj case does keep it), it disappears from the emitted
    /// JSON. Fixture `080-proto-object-key`.
    private static func jsAssign(_ out: inout PropObject, _ key: String, _ value: PropValue) {
        if key == RTObject.protoKey { return }
        out[key] = value
    }

    /// serializeStep: sorted keys (handled by the serializer), undefined
    /// entries omitted, `valueAST` wrapped as `$ast` (the `.ast` case handles
    /// that already).
    private static func convertStep(_ step: RTValue) -> PropValue {
        switch step {
        case .object(let o):
            return .object(convertPlainObject(o))
        case .element(let el):
            // JS serializeStep iterates the element's own fields.
            var out: PropObject = [
                "type": .string("element"),
                "typeName": .string(el.typeName),
                "props": .object(convertPlainObject(el.props)),
                "partial": .bool(el.partial),
                "hasDynamicProps": .bool(el.hasDynamicProps),
            ]
            if let sid = el.statementId {
                out["statementId"] = .string(sid)
            }
            return .object(out)
        default:
            return convertValue(step)
        }
    }

    /// Deep AST → plain JSON tree (kind tag + fields, keys sorted by the
    /// serializer). Numbers keep NaN/Infinity — the serializer emits
    /// `{"$number": ...}` for them.
    static func convertAST(_ node: ASTNode) -> PropValue {
        switch node {
        case .str(let v):
            return .object(["k": .string("Str"), "v": .string(v)])
        case .num(let v):
            return .object(["k": .string("Num"), "v": .number(v)])
        case .bool(let v):
            return .object(["k": .string("Bool"), "v": .bool(v)])
        case .null:
            return .object(["k": .string("Null")])
        case .arr(let els):
            return .object(["k": .string("Arr"), "els": .array(els.map { convertAST($0) })])
        case .obj(let entries):
            return .object([
                "k": .string("Obj"),
                "entries": .array(entries.map { entry in
                    .array([.string(entry.key), convertAST(entry.value)])
                }),
            ])
        case .comp(let name, let args, let mappedProps):
            var out: PropObject = [
                "k": .string("Comp"),
                "name": .string(name),
                "args": .array(args.map { convertAST($0) }),
            ]
            if let mapped = mappedProps {
                var m = PropObject()
                for (key, value) in mapped {
                    m[key] = convertAST(value)
                }
                out["mappedProps"] = .object(m)
            }
            return .object(out)
        case .ref(let n):
            return .object(["k": .string("Ref"), "n": .string(n)])
        case .stateRef(let n):
            return .object(["k": .string("StateRef"), "n": .string(n)])
        case .runtimeRef(let n, let refType):
            return .object([
                "k": .string("RuntimeRef"), "n": .string(n), "refType": .string(refType),
            ])
        case .binOp(let op, let left, let right):
            return .object([
                "k": .string("BinOp"), "op": .string(op),
                "left": convertAST(left), "right": convertAST(right),
            ])
        case .unaryOp(let op, let operand):
            return .object([
                "k": .string("UnaryOp"), "op": .string(op), "operand": convertAST(operand),
            ])
        case .ternary(let cond, let then, let elseNode):
            return .object([
                "k": .string("Ternary"), "cond": convertAST(cond),
                "then": convertAST(then), "else": convertAST(elseNode),
            ])
        case .member(let obj, let field):
            return .object([
                "k": .string("Member"), "obj": convertAST(obj), "field": .string(field),
            ])
        case .index(let obj, let index):
            return .object([
                "k": .string("Index"), "obj": convertAST(obj), "index": convertAST(index),
            ])
        case .assign(let target, let value):
            return .object([
                "k": .string("Assign"), "target": .string(target), "value": convertAST(value),
            ])
        case .ph(let n):
            return .object(["k": .string("Ph"), "n": .string(n)])
        }
    }
}
