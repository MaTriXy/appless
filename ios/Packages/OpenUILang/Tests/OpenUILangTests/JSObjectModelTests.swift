import Foundation
import Testing

@testable import OpenUILang

/// Direct unit coverage for `JSObject.swift` — the ~500-line hand-transcribed
/// JS plain-object model. Until this suite existed the file was reachable only
/// indirectly, through fixtures that happened to touch a handful of its rows.
///
/// Two things are gated here:
///
/// 1. **The intrinsic tables against V8 itself.** `spec/fixtures/generator/
///    probes/js-intrinsics.json` is a committed dump of
///    `Object.getOwnPropertyNames(X.prototype)` plus each descriptor's kind /
///    function name / arity, regenerable with
///    `node probes/gen-js-intrinsics.mjs --out probes/js-intrinsics.json`.
///    The Kotlin sibling (`JsObjectModelTest.kt`) asserts against the SAME
///    file, so the two hand-maintained copies cannot drift apart silently —
///    and neither can drift away from V8.
/// 2. **The chain itself**: `prototypeOf` for every runtime value case,
///    `getMember` on each intrinsic, the `hasProperty` walk, a `__proto__:
///    null` cut, the `Function.prototype.arguments`/`.caller` poison pills,
///    and the `Object.keys` boxing table.
///
/// Every expected value here was read off node v22 — the probes are quoted
/// inline next to the assertions that use them.
@Suite struct JSObjectModelTests {

    // MARK: - The V8 dump

    private static let intrinsicsURL: URL = FixtureCorpus.fixturesRoot
        .appendingPathComponent("generator/probes/js-intrinsics.json")
        .standardizedFileURL

    private static func loadIntrinsics() throws -> [String: [[String: JSONValue]]] {
        let data = try Data(contentsOf: intrinsicsURL)
        let doc = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let top) = doc, case .object(let intrinsics)? = top["intrinsics"] else {
            throw TestFailure("js-intrinsics.json has no `intrinsics` object")
        }
        var out: [String: [[String: JSONValue]]] = [:]
        for (label, rows) in intrinsics {
            guard case .array(let items) = rows else {
                throw TestFailure("\(label) is not an array")
            }
            out[label] = items.map {
                if case .object(let o) = $0 { return o }
                return [:]
            }
        }
        return out
    }

    struct TestFailure: Error { let message: String
        init(_ m: String) { message = m }
    }

    /// Kinds as `gen-js-intrinsics.mjs` records them, mapped onto `JSMember`.
    private func matches(_ member: JSMember?, _ row: [String: JSONValue], key: String) -> Bool {
        guard let member, case .string(let kind)? = row["kind"] else { return false }
        switch (kind, member) {
        case ("function", .fn(let name, let arity)):
            guard case .string(let wantName)? = row["name"],
                case .number(let wantArity)? = row["arity"]
            else { return false }
            return name == wantName && arity == Int(wantArity)
        case ("data", .data(let value)):
            switch (row["value"], value) {
            case (.number(let want)?, .number(let got)): return want == got
            case (.string(let want)?, .string(let got)): return want == got
            default: return false
            }
        // The port splits V8's accessors by WHICH accessor it is: the
        // `__proto__` getter/setter pair is modelled, the `arguments`/`caller`
        // pair throws.
        case ("accessor", .poisonPill):
            return key == "arguments" || key == "caller"
        case ("accessor", .protoAccessor):
            return key == "__proto__"
        default:
            return false
        }
    }

    @Test func intrinsicTablesMatchV8Dump() throws {
        let intrinsics = try Self.loadIntrinsics()
        let byLabel: [String: JSProtoKind] = [
            "Object": .object, "Array": .array, "Number": .number,
            "String": .string, "Boolean": .boolean, "Function": .function,
        ]
        #expect(Set(intrinsics.keys) == Set(byLabel.keys))
        for (label, kind) in byLabel {
            let rows = try #require(intrinsics[label])
            let table = JSObjects.intrinsicOwn(kind)
            let names: [String] = rows.compactMap {
                if case .string(let k)? = $0["key"] { return k }
                return nil
            }
            #expect(
                names.count == table.count,
                "\(label).prototype: V8 has \(names.count) own names, the port table has \(table.count)"
            )
            for (row, key) in zip(rows, names) {
                #expect(matches(table[key], row, key: key), "\(label).prototype.\(key)")
            }
        }
    }

    @Test func objectPrototypeHasExactlyTheTwelveNames() {
        // The one table the whole file exists for: `BUILTINS[name]`,
        // `name in RESERVED_CALLS` and `obj.field` all fall through to these.
        #expect(
            JSObjects.prototypeOwnNames.keys.sorted() == [
                "__defineGetter__", "__defineSetter__", "__lookupGetter__", "__lookupSetter__",
                "__proto__", "constructor", "hasOwnProperty", "isPrototypeOf",
                "propertyIsEnumerable", "toLocaleString", "toString", "valueOf",
            ])
    }


    // `RTValue` is deliberately not `Equatable` (the port compares trees as
    // canonical JSON bytes, never by value), so scalar assertions go through
    // these.
    private func isUndefined(_ v: RTValue?) -> Bool {
        if case .undefined? = v { return true }
        return false
    }
    private func num(_ v: RTValue?) -> Double? {
        if case .number(let n)? = v { return n }
        return nil
    }
    private func str(_ v: RTValue?) -> String? {
        if case .string(let s)? = v { return s }
        return nil
    }
    private func isNullProto(_ v: RTValue?) -> Bool {
        if case .null? = v { return true }
        return false
    }

    // MARK: - prototypeOf, every runtime value case

    private func isProto(_ v: RTValue?, _ kind: JSProtoKind) -> Bool {
        if case .proto(let k)? = v { return k == kind }
        return false
    }

    @Test func prototypeOfCoversEveryRuntimeValue() {
        // `nil` = no [[Prototype]] concept at all (JS throws on a member
        // access); `.null` = a genuinely prototype-less object.
        #expect(JSObjects.prototypeOf(.undefined) == nil)
        #expect(JSObjects.prototypeOf(.null) == nil)

        #expect(isProto(JSObjects.prototypeOf(.array([])), .array))
        #expect(isProto(JSObjects.prototypeOf(.number(1)), .number))
        #expect(isProto(JSObjects.prototypeOf(.string("x")), .string))
        #expect(isProto(JSObjects.prototypeOf(.bool(true)), .boolean))
        #expect(isProto(JSObjects.prototypeOf(.function(name: "toString", arity: 0)), .function))

        // ElementNodes and AST nodes are plain object literals in JS.
        let el = RTElement(typeName: "TextContent", props: RTObject(), partial: false, hasDynamicProps: false)
        #expect(isProto(JSObjects.prototypeOf(.element(el)), .object))
        #expect(isProto(JSObjects.prototypeOf(.ast(.null)), .object))

        // A plain object literal starts at Object.prototype; Object.prototype
        // itself is the END of every chain.
        #expect(isProto(JSObjects.prototypeOf(.object(RTObject())), .object))
        if !isNullProto(JSObjects.prototypeOf(.proto(.object))) {
            Issue.record("Object.prototype's own [[Prototype]] must be null")
        }
        for kind: JSProtoKind in [.array, .number, .string, .boolean, .function] {
            #expect(
                isProto(JSObjects.prototypeOf(.proto(kind)), .object),
                "\(kind).prototype's own [[Prototype]] is Object.prototype")
        }
    }

    // MARK: - getMember on each intrinsic

    private func isFn(_ v: RTValue?, _ name: String, _ arity: Int) -> Bool {
        if case .function(let n, let a)? = v { return n == name && a == arity }
        return false
    }

    @Test func getMemberResolvesEachIntrinsic() throws {
        // node: (1).toFixed.name === "toFixed" && (1).toFixed.length === 1
        #expect(isFn(try JSObjects.getMember(.number(1), "toFixed"), "toFixed", 1))
        #expect(isFn(try JSObjects.getMember(.number(1), "constructor"), "Number", 1))
        // node: "ab".padStart.length === 1 ; "ab".length === 2 ; "ab"[1] === "b"
        #expect(isFn(try JSObjects.getMember(.string("ab"), "padStart"), "padStart", 1))
        #expect(num(try JSObjects.getMember(.string("ab"), "length")) == 2)
        #expect(str(try JSObjects.getMember(.string("ab"), "1")) == "b")
        #expect(isUndefined(try JSObjects.getMember(.string("ab"), "9")))
        // node: [].flatMap.length === 1 ; [1,2].length === 2 ; [1,2][0] === 1
        let arr = RTValue.array([.number(1), .number(2)])
        #expect(isFn(try JSObjects.getMember(arr, "flatMap"), "flatMap", 1))
        #expect(num(try JSObjects.getMember(arr, "length")) == 2)
        #expect(num(try JSObjects.getMember(arr, "0")) == 1)
        // node: true.valueOf.name === "valueOf"
        #expect(isFn(try JSObjects.getMember(.bool(true), "valueOf"), "valueOf", 0))
        // node: String.prototype.trimLeft.name === "trimStart" (the alias
        // reports its canonical name).
        #expect(isFn(try JSObjects.getMember(.string(""), "trimLeft"), "trimStart", 0))
        // A native function's own `name`/`length`, and Function.prototype's.
        let fn = RTValue.function(name: "toString", arity: 0)
        #expect(str(try JSObjects.getMember(fn, "name")) == "toString")
        #expect(num(try JSObjects.getMember(fn, "length")) == 0)
        #expect(isFn(try JSObjects.getMember(fn, "bind"), "bind", 1))
        // Inherited from Object.prototype at the end of the chain.
        #expect(isFn(try JSObjects.getMember(fn, "hasOwnProperty"), "hasOwnProperty", 1))
    }

    @Test func protoAccessorAnswersTheReceiversPrototype() throws {
        // The getter is found on Object.prototype but answers the RECEIVER's
        // [[Prototype]], not the link it was found on.
        #expect(isProto(try JSObjects.getMember(.array([]), "__proto__"), .array))
        #expect(isProto(try JSObjects.getMember(.object(RTObject()), "__proto__"), .object))
    }

    @Test func poisonPillsThrowV8sMessage() {
        let fn = RTValue.function(name: "toString", arity: 0)
        for key in ["arguments", "caller"] {
            #expect(throws: JSTypeError.self) { _ = try JSObjects.getMember(fn, key) }
            do {
                _ = try JSObjects.getMember(fn, key)
            } catch let e as JSTypeError {
                #expect(e.message == JSObjects.poisonPillMessage)
            } catch {
                Issue.record("wrong error type for \(key)")
            }
            // `in` never invokes the accessor, so it does NOT throw.
            #expect(JSObjects.hasProperty(fn, key))
        }
    }

    // MARK: - hasProperty: the chain walk

    @Test func hasPropertyWalksTheWholeChain() throws {
        var o = RTObject()
        o["own"] = .number(1)
        let v = RTValue.object(o)
        #expect(JSObjects.hasProperty(v, "own"))
        // Inherited from Object.prototype — this is what makes
        // `name in RESERVED_CALLS` answer true for all twelve names.
        for name in JSObjects.prototypeOwnNames.keys {
            #expect(JSObjects.hasProperty(v, name), "`\(name) in {}` should be true")
        }
        #expect(!JSObjects.hasProperty(v, "nope"))

        // Two links deep: an own key on the prototype object.
        var base = RTObject()
        base["inherited"] = .string("yes")
        var child = RTObject()
        child.assign(RTObject.protoKey, .object(base))
        #expect(JSObjects.hasProperty(.object(child), "inherited"))
        #expect(str(try JSObjects.getMember(.object(child), "inherited")) == "yes")
    }

    @Test func protoNullCutsTheChain() throws {
        // `{"__proto__": null, a: 1}` inherits NOTHING — which is exactly why
        // `String(obj)` throws for it (fixture 087).
        var cut = RTObject()
        cut.assign(RTObject.protoKey, .null)
        cut["a"] = .number(1)
        let v = RTValue.object(cut)
        if !isNullProto(JSObjects.prototypeOf(v)) { Issue.record("chain not cut") }
        #expect(num(try JSObjects.getMember(v, "a")) == 1)
        for name in JSObjects.prototypeOwnNames.keys {
            #expect(isUndefined(try JSObjects.getMember(v, name)), "cut.\(name)")
            #expect(!JSObjects.hasProperty(v, name), "`\(name) in cut` should be false")
        }
        // With no inherited `__proto__` SETTER left, assignment creates an
        // ordinary own key instead of re-pointing.
        #expect(!JSObjects.inheritsProtoAccessor(v))
        cut.assign(RTObject.protoKey, .object(RTObject()))
        #expect(cut.has(RTObject.protoKey))
        if !isNullProto(JSObjects.prototypeOf(.object(cut))) {
            Issue.record("assignment must not re-point a cut chain")
        }
    }

    // MARK: - Object.keys, the boxing table

    @Test func objectKeysBoxesPrimitivesLikeV8() {
        // node -e 'console.log(Object.keys(1), Object.keys(true), Object.keys("ab"),
        //          Object.keys([1,2]), Object.keys(Array.prototype),
        //          Object.keys(function f(){}))'
        //   -> [] [] [ '0', '1' ] [ '0', '1' ] [] []
        #expect(JSObjects.objectKeys(.number(1)) == [])
        #expect(JSObjects.objectKeys(.bool(true)) == [])
        #expect(JSObjects.objectKeys(.string("ab")) == ["0", "1"])
        #expect(JSObjects.objectKeys(.array([.number(1), .number(2)])) == ["0", "1"])
        #expect(JSObjects.objectKeys(.function(name: "toString", arity: 0)) == [])
        for kind: JSProtoKind in [.object, .array, .number, .string, .boolean, .function] {
            #expect(
                JSObjects.objectKeys(.proto(kind)) == [],
                "no own property of \(kind).prototype is enumerable")
        }
        // A surrogate pair is TWO code units, so an astral character
        // contributes two index keys — the port indexes UTF-16, like JS.
        #expect(JSObjects.objectKeys(.string("a😀b")) == ["0", "1", "2", "3"])

        // `Object.keys(undefined)`/`(null)` THROW in JS; the port signals that
        // with a nil answer (see Pipeline.convertStep).
        #expect(JSObjects.objectKeys(.undefined) == nil)
        #expect(JSObjects.objectKeys(.null) == nil)

        // Element and AST nodes are plain object literals: their own keys are
        // exactly the fields they carry.
        var el = RTElement(
            typeName: "TextContent", props: RTObject(), partial: false, hasDynamicProps: true)
        #expect(
            JSObjects.objectKeys(.element(el))
                == ["type", "typeName", "props", "partial", "hasDynamicProps"])
        el.statementId = "row"
        #expect(
            JSObjects.objectKeys(.element(el))
                == ["type", "typeName", "props", "partial", "hasDynamicProps", "statementId"])
        #expect(JSObjects.objectKeys(.ast(.str("x"))) == ["k", "v"])
        #expect(JSObjects.objectKeys(.ast(.null)) == ["k"])
        #expect(
            JSObjects.objectKeys(.ast(.runtimeRef(name: "q", refType: "query")))
                == ["k", "n", "refType"])
    }

    // MARK: - The two duck-type guards

    @Test func serializerGuardIsLooserThanTheRuntimeGuard() {
        // serialize.mjs checks `type`/`typeName` only; parser/types.js also
        // demands a non-null object `props` and a boolean `partial`.
        var o = RTObject()
        o["type"] = .string("element")
        o["typeName"] = .string("Weird")
        o["props"] = .number(7)
        #expect(JSObjects.serializerElementRef(.object(o))?.typeName == "Weird")
        #expect(JSObjects.runtimeElementRef(.object(o)) == nil)

        o["props"] = .object(RTObject())
        #expect(JSObjects.runtimeElementRef(.object(o)) == nil)  // `partial` missing
        o["partial"] = .bool(false)
        #expect(JSObjects.runtimeElementRef(.object(o))?.typeName == "Weird")
        // A duck-typed object is NOT the port's typed element.
        #expect(JSObjects.runtimeElementRef(.object(o))?.element == nil)
    }

    @Test func elementIdentityIsInheritedThroughTheChain() {
        var base = RTObject()
        base["type"] = .string("element")
        base["typeName"] = .string("TextContent")
        var baseProps = RTObject()
        baseProps["text"] = .string("inherited")
        base["props"] = .object(baseProps)
        base["partial"] = .bool(false)
        var child = RTObject()
        child.assign(RTObject.protoKey, .object(base))
        child["z"] = .number(1)
        #expect(JSObjects.runtimeElementRef(.object(child))?.typeName == "TextContent")
        // An OWN `type` that is still `"element"` does not break the identity —
        // the guard is a value test, not an ownership test.
        child["type"] = .string("element")
        #expect(JSObjects.runtimeElementRef(.object(child))?.typeName == "TextContent")
        // An own `type` with any other value DOES.
        child["type"] = .string("notelement")
        #expect(JSObjects.runtimeElementRef(.object(child)) == nil)
    }
}
