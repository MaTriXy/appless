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
        let evaluatedRoot: RTValue? = internalResult.root.map {
            evaluator.evaluateElementProps($0)
        }

        var state: [String: PropValue] = [:]
        for key in internalResult.stateDeclarations.keys {
            state[key] = convertValue(internalResult.stateDeclarations[key]!)
        }

        // `serializeExpected`: `evaluatedRoot ? serializeElement(evaluatedRoot) : null`.
        // The evaluated root can have LOST its element identity (the
        // `{ ...el, props }` spread drops inherited fields), in which case the
        // reference calls `serializeElement` on a non-element anyway and
        // `el.typeName` comes out `undefined` — see `convertRootLike`.
        return ParseResult(
            root: evaluatedRoot.map { convertRootLike($0) },
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
        convertElementFields(
            typeName: .string(el.typeName),
            statementId: el.statementId.map { RTValue.string($0) } ?? .undefined,
            props: .object(el.props)
        )
    }

    private static func convertElementRef(_ ref: JSElementRef) -> ElementNode {
        convertElementFields(
            typeName: .string(ref.typeName), statementId: ref.statementId, props: ref.props)
    }

    /// serialize.mjs `serializeElement`. Every field is read off the receiver
    /// through the prototype chain by the caller; `props` is then enumerated by
    /// `Object.keys(el.props)` — an OWN-key enumeration of whatever that GET
    /// produced, so a non-object `props` is not an error (`Object.keys(7)` is
    /// `[]`, `Object.keys("ab")` is `["0","1"]`).
    ///
    /// `statementId` is copied VERBATIM (`out.statementId = el.statementId`) —
    /// no `serializeValue`, hence no `$ast`/`$action`/`$number` treatment; see
    /// `rawJSON`.
    private static func convertElementFields(
        typeName: RTValue, statementId: RTValue, props: RTValue
    ) -> ElementNode {
        var out: [String: PropValue] = [:]
        var children: PropValue? = nil
        for key in JSObjects.objectKeys(props) ?? [] {
            // `props[key] = …` / `children = …` — plain assignment again.
            if key == RTObject.protoKey { continue }
            let value = (try? JSObjects.getMember(props, key)) ?? .undefined
            if value.isDroppedByJSONStringify { continue }
            if key == "children" {
                children = convertValue(value)
            } else {
                out[key] = convertValue(value)
            }
        }
        // `out.component = el.typeName`. Only the root slot can reach this with
        // a non-string `typeName`, and there it is always `undefined`: every
        // other caller went through a duck-type test that already required a
        // STRING `typeName`, and the one that did not (`serializeExpected`'s
        // root) sees a `{...el}` spread, which either kept the own — hence
        // string-checked — `typeName` or dropped it entirely.
        var component = ""
        var present = false
        if case .string(let name) = typeName {
            component = name
            present = true
        }
        return ElementNode(
            component: component,
            statementId: rawJSON(statementId),
            props: out,
            children: children,
            componentPresent: present
        )
    }

    /// `serializeExpected`'s root slot: `evaluatedRoot ?
    /// serializeElement(evaluatedRoot) : null`. The call is UNCONDITIONAL, so a
    /// root that lost its element identity during evaluation (the
    /// `{ ...el, props }` spread drops fields that were only INHERITED) is
    /// still run through `serializeElement` — `el.typeName` then reads
    /// `undefined` and `JSON.stringify` omits the `component` key entirely
    /// (fixture `096-duck-element-proto-spread`).
    private static func convertRootLike(_ v: RTValue) -> ElementNode {
        if let ref = JSObjects.serializerElementRef(v) { return convertElementRef(ref) }
        return convertElementFields(
            typeName: (try? JSObjects.getMember(v, "typeName")) ?? .undefined,
            statementId: (try? JSObjects.getMember(v, "statementId")) ?? .undefined,
            props: (try? JSObjects.getMember(v, "props")) ?? .undefined
        )
    }

    /// Plain `JSON.stringify` semantics for a value the reference serializer
    /// copies VERBATIM instead of routing through `serializeValue`: no
    /// element/action/AST duck-typing and, notably, no `{"$number": …}` — raw
    /// `JSON.stringify` writes `null` for NaN and ±Infinity.
    ///
    /// `nil` means the value is dropped entirely: `undefined` and functions are
    /// omitted from the emitted object.
    static func rawJSON(_ v: RTValue) -> PropValue? {
        switch v {
        case .undefined, .function: return nil
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n): return n.isFinite ? .number(n) : .null
        case .string(let s): return .string(s)
        case .array(let items): return .array(items.map { rawJSON($0) ?? .null })
        case .proto(let kind): return kind == .array ? .array([]) : .object(PropObject())
        case .object, .element, .ast:
            // `JSON.stringify` reads the SOURCE object's own keys; unlike the
            // serializer's rebuild there is no `out[key] = …` assignment here,
            // so an own `"__proto__"` key IS emitted
            // (`JSON.stringify(Object.fromEntries([["__proto__",1]]))` is
            // `{"__proto__":1}`).
            var out = PropObject()
            for key in JSObjects.objectKeys(v) ?? [] {
                let member = (try? JSObjects.getMember(v, key)) ?? .undefined
                if let converted = rawJSON(member) { out[key] = converted }
            }
            return .object(out)
        }
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
            // NOTE the serializer's `isElementNode` is LOOSER than the
            // runtime one: only `type === "element"` and a string `typeName`,
            // no `props`/`partial` check (serialize.mjs:9-11).
            if let ref = JSObjects.serializerElementRef(v) {
                return .element(convertElementRef(ref))
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

    /// serialize.mjs `serializeStep` — verbatim:
    ///
    /// ```js
    /// function serializeStep(step) {
    ///   const out = {};
    ///   for (const key of Object.keys(step).sort()) {
    ///     const v = step[key];
    ///     if (v === undefined) continue;
    ///     out[key] = key === "valueAST" ? { $ast: serializeAst(v) } : serializeValue(v);
    ///   }
    ///   return out;
    /// }
    /// ```
    ///
    /// Two rules that are easy to get wrong, and this port did:
    ///
    /// 1. It is `Object.keys(step)`, NOT a type switch. A step that is not a
    ///    plain object is BOXED, so it always serializes as an OBJECT:
    ///    `{steps: [1, 2]}` gives `[{}, {}]`, `{steps: ["ab"]}` gives
    ///    `[{"0":"a","1":"b"}]`, `{steps: [[1, 2]]}` gives `[{"0":1,"1":2}]`
    ///    and `{steps: [true]}` gives `[{}]` (fixture
    ///    `091-action-steps-nonobject`).
    /// 2. `valueAST` is wrapped by KEY NAME, not by value type. `{type: "set",
    ///    valueAST: 1}` gives `"valueAST": {"$ast": 1}`, and any other key
    ///    holding an AST value is wrapped by `serializeValue`'s own AST branch
    ///    instead (fixture `092-action-valueast-by-key`).
    ///
    /// A step of `null`/`undefined` makes the REFERENCE THROW
    /// (`Object.keys(null)`), taking the fixture generator with it, so no
    /// expected tree exists for it; the port emits `{}` — see the READMEs'
    /// KNOWN-DEVIATIONS.
    private static func convertStep(_ step: RTValue) -> PropValue {
        var out = PropObject()
        for key in JSObjects.objectKeys(step) ?? [] {
            let value = (try? JSObjects.getMember(step, key)) ?? .undefined
            if case .undefined = value { continue }
            if key == "valueAST" {
                // `{ $ast: serializeAst(v) }`; a function `v` survives
                // `serializeAst` untouched and `JSON.stringify` then drops the
                // `$ast` key, leaving `{}`.
                if case .function = value {
                    out[key] = .object(PropObject())
                } else {
                    out[key] = .ast(convertAstPlain(value))
                }
            } else {
                if value.isDroppedByJSONStringify { continue }
                jsAssign(&out, key, convertValue(value))
            }
        }
        return .object(out)
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
