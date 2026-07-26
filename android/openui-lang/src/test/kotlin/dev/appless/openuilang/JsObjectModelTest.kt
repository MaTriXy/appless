package dev.appless.openuilang

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Direct unit coverage for `JsObject.kt` — the ~500-line hand-transcribed JS
 * plain-object model. Until this suite existed the file was reachable only
 * indirectly, through fixtures that happened to touch a handful of its rows.
 *
 * Two things are gated here:
 *
 * 1. **The intrinsic tables against V8 itself.** `spec/fixtures/generator/
 *    probes/js-intrinsics.json` is a committed dump of
 *    `Object.getOwnPropertyNames(X.prototype)` plus each descriptor's kind /
 *    function name / arity, regenerable with
 *    `node probes/gen-js-intrinsics.mjs --out probes/js-intrinsics.json`.
 *    The Swift sibling (`JSObjectModelTests.swift`) asserts against the SAME
 *    file, so the two hand-maintained copies cannot drift apart silently —
 *    and neither can drift away from V8.
 * 2. **The chain itself**: `prototypeOf` for every runtime value case,
 *    `getMember` on each intrinsic, the `hasProperty` walk, a `__proto__:
 *    null` cut, the `Function.prototype.arguments`/`.caller` poison pills, and
 *    the `Object.keys` boxing table.
 *
 * Every expected value here was read off node v22 — the probes are quoted
 * inline next to the assertions that use them.
 */
class JsObjectModelTest {

    // ── The V8 dump ────────────────────────────────────────────────────────

    private val intrinsicsFile: File = File(
        FixtureCorpus.fixturesRoot, "generator/probes/js-intrinsics.json"
    )

    /** Kinds as `gen-js-intrinsics.mjs` records them, mapped onto [JsMember]. */
    private fun expectedMember(row: Map<String, JsonValue>, owner: String, key: String): JsMember {
        return when (val kind = (row["kind"] as JsonValue.Str).value) {
            "function" -> JsMember.Fn(
                (row["name"] as JsonValue.Str).value,
                (row["arity"] as JsonValue.Num).value.toInt(),
            )

            "data" -> JsMember.Data(
                when (val v = row["value"]!!) {
                    is JsonValue.Num -> RtValue.Num(v.value)
                    is JsonValue.Str -> RtValue.Str(v.value)
                    else -> error("unsupported data value for $owner.$key: $v")
                }
            )

            // The port splits V8's accessors by WHICH accessor it is: the
            // `__proto__` getter/setter pair is modelled, the
            // `arguments`/`caller` pair throws.
            "accessor" ->
                if (key == "arguments" || key == "caller") JsMember.PoisonPill
                else JsMember.ProtoAccessor

            else -> error("unknown kind $kind")
        }
    }

    @Test
    fun intrinsicTablesMatchV8Dump() {
        assertTrue(intrinsicsFile.isFile, "missing ${intrinsicsFile.path}")
        val doc = JsonValue.parse(intrinsicsFile.readText()) as JsonValue.Obj
        val intrinsics = doc["intrinsics"] as JsonValue.Obj
        val byLabel = mapOf(
            "Object" to JsProtoKind.OBJECT,
            "Array" to JsProtoKind.ARRAY,
            "Number" to JsProtoKind.NUMBER,
            "String" to JsProtoKind.STRING,
            "Boolean" to JsProtoKind.BOOLEAN,
            "Function" to JsProtoKind.FUNCTION,
        )
        assertEquals(byLabel.keys, intrinsics.value.keys)

        for ((label, kind) in byLabel) {
            val rows = (intrinsics[label] as JsonValue.Arr).value.map { it as JsonValue.Obj }
            val table = JsObjects.intrinsicOwn(kind)
            assertEquals(
                rows.map { (it["key"] as JsonValue.Str).value },
                table.keys.toList(),
                "$label.prototype own names (or their order) drifted from V8",
            )
            for (row in rows) {
                val key = (row["key"] as JsonValue.Str).value
                val fields = row.value
                assertEquals(
                    expectedMember(fields, label, key),
                    table[key],
                    "$label.prototype.$key",
                )
            }
        }
    }

    @Test
    fun objectPrototypeHasExactlyTheTwelveNames() {
        // The one table the whole file exists for: `BUILTINS[name]`,
        // `name in RESERVED_CALLS` and `obj.field` all fall through to these.
        assertEquals(
            listOf(
                "__defineGetter__", "__defineSetter__", "__lookupGetter__", "__lookupSetter__",
                "__proto__", "constructor", "hasOwnProperty", "isPrototypeOf",
                "propertyIsEnumerable", "toLocaleString", "toString", "valueOf",
            ),
            JsObjects.PROTOTYPE_OWN_NAMES.keys.sorted(),
        )
    }

    // ── prototypeOf, every runtime value case ──────────────────────────────

    @Test
    fun prototypeOfCoversEveryRuntimeValue() {
        // `null` (Kotlin) = no [[Prototype]] concept at all (JS throws on a
        // member access); RtValue.Null = a genuinely prototype-less object.
        assertNull(JsObjects.prototypeOf(RtValue.Undefined))
        assertNull(JsObjects.prototypeOf(RtValue.Null))

        assertEquals(RtValue.Proto(JsProtoKind.ARRAY), JsObjects.prototypeOf(RtValue.Arr(listOf())))
        assertEquals(RtValue.Proto(JsProtoKind.NUMBER), JsObjects.prototypeOf(RtValue.Num(1.0)))
        assertEquals(RtValue.Proto(JsProtoKind.STRING), JsObjects.prototypeOf(RtValue.Str("x")))
        assertEquals(RtValue.Proto(JsProtoKind.BOOLEAN), JsObjects.prototypeOf(RtValue.Bool(true)))
        assertEquals(
            RtValue.Proto(JsProtoKind.FUNCTION),
            JsObjects.prototypeOf(RtValue.Func("toString", 0)),
        )

        // ElementNodes and AST nodes are plain object literals in JS.
        val el = RtElement("TextContent", RtObject(), partial = false, hasDynamicProps = false)
        assertEquals(JsObjects.OBJECT_PROTOTYPE, JsObjects.prototypeOf(RtValue.Element(el)))
        assertEquals(JsObjects.OBJECT_PROTOTYPE, JsObjects.prototypeOf(RtValue.Ast(AstNode.Null)))

        // A plain object literal starts at Object.prototype; Object.prototype
        // itself is the END of every chain.
        assertEquals(JsObjects.OBJECT_PROTOTYPE, JsObjects.prototypeOf(RtValue.Obj(RtObject())))
        assertEquals(RtValue.Null, JsObjects.prototypeOf(RtValue.Proto(JsProtoKind.OBJECT)))
        for (kind in JsProtoKind.entries.filter { it != JsProtoKind.OBJECT }) {
            assertEquals(
                JsObjects.OBJECT_PROTOTYPE,
                JsObjects.prototypeOf(RtValue.Proto(kind)),
                "$kind.prototype's own [[Prototype]] is Object.prototype",
            )
        }
    }

    // ── getMember on each intrinsic ────────────────────────────────────────

    @Test
    fun getMemberResolvesEachIntrinsic() {
        // node: (1).toFixed.name === "toFixed" && (1).toFixed.length === 1
        assertEquals(RtValue.Func("toFixed", 1), JsObjects.getMember(RtValue.Num(1.0), "toFixed"))
        assertEquals(RtValue.Func("Number", 1), JsObjects.getMember(RtValue.Num(1.0), "constructor"))
        // node: "ab".padStart.length === 1 ; "ab".length === 2
        assertEquals(RtValue.Func("padStart", 1), JsObjects.getMember(RtValue.Str("ab"), "padStart"))
        assertEquals(RtValue.Num(2.0), JsObjects.getMember(RtValue.Str("ab"), "length"))
        // node: "ab"[1] === "b" ; "ab"[9] === undefined
        assertEquals(RtValue.Str("b"), JsObjects.getMember(RtValue.Str("ab"), "1"))
        assertEquals(RtValue.Undefined, JsObjects.getMember(RtValue.Str("ab"), "9"))
        // node: [].flatMap.length === 1 ; [1,2].length === 2 ; [1,2][0] === 1
        val arr = RtValue.Arr(listOf(RtValue.Num(1.0), RtValue.Num(2.0)))
        assertEquals(RtValue.Func("flatMap", 1), JsObjects.getMember(arr, "flatMap"))
        assertEquals(RtValue.Num(2.0), JsObjects.getMember(arr, "length"))
        assertEquals(RtValue.Num(1.0), JsObjects.getMember(arr, "0"))
        // node: true.valueOf.name === "valueOf"
        assertEquals(RtValue.Func("valueOf", 0), JsObjects.getMember(RtValue.Bool(true), "valueOf"))
        // node: String.prototype.trimLeft.name === "trimStart" (the alias
        // reports its canonical name).
        assertEquals(
            RtValue.Func("trimStart", 0),
            JsObjects.getMember(RtValue.Str(""), "trimLeft"),
        )
        // A native function's own `name`/`length`, and Function.prototype's.
        val fn = RtValue.Func("toString", 0)
        assertEquals(RtValue.Str("toString"), JsObjects.getMember(fn, "name"))
        assertEquals(RtValue.Num(0.0), JsObjects.getMember(fn, "length"))
        assertEquals(RtValue.Func("bind", 1), JsObjects.getMember(fn, "bind"))
        // Inherited from Object.prototype at the end of the chain.
        assertEquals(RtValue.Func("hasOwnProperty", 1), JsObjects.getMember(fn, "hasOwnProperty"))
    }

    @Test
    fun protoAccessorAnswersTheReceiversPrototype() {
        // The getter is found on Object.prototype but answers the RECEIVER's
        // [[Prototype]], not the link it was found on.
        assertEquals(
            RtValue.Proto(JsProtoKind.ARRAY),
            JsObjects.getMember(RtValue.Arr(listOf()), "__proto__"),
        )
        assertEquals(
            JsObjects.OBJECT_PROTOTYPE,
            JsObjects.getMember(RtValue.Obj(RtObject()), "__proto__"),
        )
    }

    @Test
    fun poisonPillsThrowV8sMessage() {
        val fn = RtValue.Func("toString", 0)
        for (key in listOf("arguments", "caller")) {
            val e = assertFailsWith<JsTypeError> { JsObjects.getMember(fn, key) }
            assertEquals(JsObjects.POISON_PILL_MESSAGE, e.message)
        }
        // `in` never invokes the accessor, so it does NOT throw.
        assertTrue(JsObjects.hasProperty(fn, "arguments"))
        assertTrue(JsObjects.hasProperty(fn, "caller"))
    }

    // ── hasProperty: the chain walk ────────────────────────────────────────

    @Test
    fun hasPropertyWalksTheWholeChain() {
        val o = RtObject()
        o["own"] = RtValue.Num(1.0)
        val v = RtValue.Obj(o)
        assertTrue(JsObjects.hasProperty(v, "own"))
        // Inherited from Object.prototype — this is what makes
        // `name in RESERVED_CALLS` answer true for all twelve names.
        for (name in JsObjects.PROTOTYPE_OWN_NAMES.keys) {
            assertTrue(JsObjects.hasProperty(v, name), "`$name in {}` should be true")
        }
        assertTrue(!JsObjects.hasProperty(v, "nope"))

        // Two links deep: an own key on the prototype object.
        val base = RtObject()
        base["inherited"] = RtValue.Str("yes")
        val child = RtObject()
        child.assign(RtObject.PROTO_KEY, RtValue.Obj(base))
        assertTrue(JsObjects.hasProperty(RtValue.Obj(child), "inherited"))
        assertEquals(RtValue.Str("yes"), JsObjects.getMember(RtValue.Obj(child), "inherited"))
    }

    @Test
    fun protoNullCutsTheChain() {
        // `{"__proto__": null, a: 1}` inherits NOTHING — which is exactly why
        // `String(obj)` throws for it (fixture 087).
        val cut = RtObject()
        cut.assign(RtObject.PROTO_KEY, RtValue.Null)
        cut["a"] = RtValue.Num(1.0)
        val v = RtValue.Obj(cut)
        assertEquals(RtValue.Null, JsObjects.prototypeOf(v))
        assertEquals(RtValue.Num(1.0), JsObjects.getMember(v, "a"))
        for (name in JsObjects.PROTOTYPE_OWN_NAMES.keys) {
            assertEquals(RtValue.Undefined, JsObjects.getMember(v, name), "cut.$name")
            assertTrue(!JsObjects.hasProperty(v, name), "`$name in cut` should be false")
        }
        // With no inherited `__proto__` SETTER left, assignment creates an
        // ordinary own key instead of re-pointing.
        assertTrue(!JsObjects.inheritsProtoAccessor(v))
        cut.assign(RtObject.PROTO_KEY, RtValue.Obj(RtObject()))
        assertTrue(cut.has(RtObject.PROTO_KEY))
        assertEquals(RtValue.Null, JsObjects.prototypeOf(v))
    }

    // ── Object.keys, the boxing table ──────────────────────────────────────

    @Test
    fun objectKeysBoxesPrimitivesLikeV8() {
        // node -e 'console.log(Object.keys(1), Object.keys(true), Object.keys("ab"),
        //          Object.keys([1,2]), Object.keys(Array.prototype),
        //          Object.keys(function f(){}))'
        //   -> [] [] [ '0', '1' ] [ '0', '1' ] [] []
        assertEquals(emptyList(), JsObjects.objectKeys(RtValue.Num(1.0)))
        assertEquals(emptyList(), JsObjects.objectKeys(RtValue.Bool(true)))
        assertEquals(listOf("0", "1"), JsObjects.objectKeys(RtValue.Str("ab")))
        assertEquals(
            listOf("0", "1"),
            JsObjects.objectKeys(RtValue.Arr(listOf(RtValue.Num(1.0), RtValue.Num(2.0)))),
        )
        assertEquals(emptyList(), JsObjects.objectKeys(RtValue.Func("toString", 0)))
        for (kind in JsProtoKind.entries) {
            assertEquals(
                emptyList(),
                JsObjects.objectKeys(RtValue.Proto(kind)),
                "no own property of $kind.prototype is enumerable",
            )
        }
        // A lone surrogate pair is TWO code units, so an astral character
        // contributes two index keys — the port indexes UTF-16, like JS.
        assertEquals(listOf("0", "1", "2", "3"), JsObjects.objectKeys(RtValue.Str("a😀b")))

        // `Object.keys(undefined)`/`(null)` THROW in JS; the port signals that
        // with a null answer (see Pipeline.convertStep).
        assertNull(JsObjects.objectKeys(RtValue.Undefined))
        assertNull(JsObjects.objectKeys(RtValue.Null))

        // Element and AST nodes are plain object literals: their own keys are
        // exactly the fields they carry.
        val el = RtElement("TextContent", RtObject(), partial = false, hasDynamicProps = true)
        assertEquals(
            listOf("type", "typeName", "props", "partial", "hasDynamicProps"),
            JsObjects.objectKeys(RtValue.Element(el)),
        )
        assertEquals(
            listOf("type", "typeName", "props", "partial", "hasDynamicProps", "statementId"),
            JsObjects.objectKeys(RtValue.Element(el.withStatementId("row"))),
        )
        assertEquals(listOf("k", "v"), JsObjects.objectKeys(RtValue.Ast(AstNode.Str("x"))))
        assertEquals(listOf("k"), JsObjects.objectKeys(RtValue.Ast(AstNode.Null)))
        assertEquals(
            listOf("k", "n", "refType"),
            JsObjects.objectKeys(RtValue.Ast(AstNode.RuntimeRef("q", "query"))),
        )
    }

    // ── The two duck-type guards ───────────────────────────────────────────

    @Test
    fun serializerGuardIsLooserThanTheRuntimeGuard() {
        // serialize.mjs checks `type`/`typeName` only; parser/types.js also
        // demands a non-null object `props` and a boolean `partial`.
        val o = RtObject()
        o["type"] = RtValue.Str("element")
        o["typeName"] = RtValue.Str("Weird")
        o["props"] = RtValue.Num(7.0)
        val v = RtValue.Obj(o)
        assertEquals("Weird", JsObjects.serializerElementRef(v)?.typeName)
        assertNull(JsObjects.runtimeElementRef(v))

        o["props"] = RtValue.Obj(RtObject())
        assertNull(JsObjects.runtimeElementRef(v)) // `partial` still missing
        o["partial"] = RtValue.Bool(false)
        assertEquals("Weird", JsObjects.runtimeElementRef(v)?.typeName)
        // A duck-typed object is NOT the port's typed element.
        assertNull(JsObjects.runtimeElementRef(v)?.element)
    }

    @Test
    fun elementIdentityIsInheritedThroughTheChain() {
        val base = RtObject()
        base["type"] = RtValue.Str("element")
        base["typeName"] = RtValue.Str("TextContent")
        base["props"] = RtValue.Obj(RtObject(listOf("text" to RtValue.Str("inherited"))))
        base["partial"] = RtValue.Bool(false)
        val child = RtObject()
        child.assign(RtObject.PROTO_KEY, RtValue.Obj(base))
        child["z"] = RtValue.Num(1.0)
        val ref = JsObjects.runtimeElementRef(RtValue.Obj(child))
        assertEquals("TextContent", ref?.typeName)
        // An OWN `type` that is still `"element"` does not break the identity —
        // the guard is a value test, not an ownership test.
        child["type"] = RtValue.Str("element")
        assertEquals("TextContent", JsObjects.runtimeElementRef(RtValue.Obj(child))?.typeName)
        // An own `type` with any other value DOES.
        child["type"] = RtValue.Str("notelement")
        assertNull(JsObjects.runtimeElementRef(RtValue.Obj(child)))
    }
}
