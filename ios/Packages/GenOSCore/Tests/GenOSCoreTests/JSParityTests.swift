import Foundation
import Testing
@testable import GenOSCore

// JS-primitive parity: jsParseInt / jsSlice / jsDecodeURIComponent.
// Expected values differentially verified against node (see comments).
@Suite struct JsParseIntTests {
    @Test func fullStrWhiteSpaceSetSkipped() {
        // node: parseInt("\u00A05", 10) === 5 (NBSP is StrWhiteSpace; the
        // old ' \t\n\r'-only skip stopped at the NBSP and returned NaN).
        #expect(jsParseInt("\u{A0}5") == 5)
        // U+2028 (LineTerminator), U+FEFF and \v are all skipped too.
        #expect(jsParseInt("\u{2028}\u{FEFF}\u{000B} \t42rest") == 42)
    }

    @Test func longDigitRunsSaturateThroughDoubleLikeJs() {
        // node: parseInt("12345678901234567890123", 10) === 1.2345678901234568e+22
        // (correctly-rounded Double, NOT NaN/nil - the old Int accumulator
        // overflowed to nil and collapsed to the clamp's min bound).
        #expect(jsParseInt("12345678901234567890123") == 1.2345678901234568e+22)
        // node: parseInt("9".repeat(400), 10) === Infinity
        #expect(jsParseInt(String(repeating: "9", count: 400)) == Double.infinity)
        #expect(jsParseInt("-" + String(repeating: "9", count: 400)) == -Double.infinity)
    }

    @Test func nanAndSignHandlingMatchesParseInt() {
        #expect(jsParseInt("abc").isNaN)
        #expect(jsParseInt("").isNaN)
        #expect(jsParseInt("+12") == 12)
        #expect(jsParseInt("-7") == -7)
        #expect(jsParseInt("12ab") == 12)
    }
}

@Suite struct JsSliceTests {
    @Test func truncationCountsUtf16UnitsNotCharacters() {
        // "e\u{301}" is ONE Character but TWO UTF-16 units - JS slice(0, 2)
        // keeps both scalars; Character-level prefix(2) would keep a second
        // Character too many.
        #expect(jsSlice("e\u{301}xy", upTo: 2) == "e\u{301}")
        #expect(jsSlice("abc", upTo: 500) == "abc")
        #expect(jsSlice("data: x", from: 5) == " x")
        #expect(jsSlice("ab", from: 5) == "")
    }

    @Test func sliceSplittingSurrogatePairYieldsReplacementLikeJsUtf8() {
        // node: ("a".repeat(499)+"😀zz").slice(0, 500) ends in a lone high
        // surrogate, which UTF-8-encodes to U+FFFD - Swift materializes the
        // same U+FFFD at slice time.
        let s = String(repeating: "a", count: 499) + "😀zz"
        let sliced = jsSlice(s, upTo: 500)
        #expect(sliced.unicodeScalars.count == 500)
        #expect(sliced.hasSuffix("a\u{FFFD}"))
    }
}

@Suite struct PercentDecodeTests {
    @Test func malformedEscapesReturnNilLikeURIErrorThrow() {
        // node: decodeURIComponent("a%20%") and decodeURIComponent("%ED%A0%80")
        // (a percent-encoded lone surrogate) both throw URIError; the Swift
        // analog pins nil for both so callers hit the same raw-fallback path.
        #expect(jsDecodeURIComponent("a%20%") == nil)
        #expect(jsDecodeURIComponent("%ED%A0%80") == nil)
        #expect(jsDecodeURIComponent("a%20b") == "a b")
    }

    /// FINDING 3: the previous implementation delegated to Foundation's
    /// `removingPercentEncoding`, which SWALLOWS a decoded leading BOM -
    /// "%EF%BB%BF" came back "" and "%EF%BB%BFa" came back "a", while a
    /// MID-string BOM survived. RN and Kotlin keep U+FEFF everywhere.
    @Test func decodedBomSurvivesAtEveryPosition() {
        // node: [...decodeURIComponent("%EF%BB%BF")] === ["﻿"], and
        // decodeURIComponent("%EF%BB%BFa") === "﻿a".
        #expect(jsDecodeURIComponent("%EF%BB%BF") == "\u{FEFF}")
        #expect(jsDecodeURIComponent("%EF%BB%BFa") == "\u{FEFF}a")
        // The position the old implementation happened to get right, pinned so
        // a future "just strip BOMs" regression is caught here too.
        #expect(jsDecodeURIComponent("a%EF%BB%BFb") == "a\u{FEFF}b")
        #expect(jsDecodeURIComponent("%EF%BB%BF%EF%BB%BF") == "\u{FEFF}\u{FEFF}")
    }

    /// The hand-rolled `Decode` must keep every acceptance AND rejection the
    /// spec has - the paths a naive byte-wise decoder gets wrong.
    @Test func handRolledDecodeMatchesSpecAcceptanceAndRejection() {
        // Accepted (node): NUL, DEL, astral pairs, literal non-ASCII passthrough.
        #expect(jsDecodeURIComponent("%00") == "\u{0}")
        #expect(jsDecodeURIComponent("%7F") == "\u{7F}")
        #expect(jsDecodeURIComponent("%F0%9F%98%80") == "😀")
        #expect(jsDecodeURIComponent("plain-\u{2603}") == "plain-\u{2603}")
        #expect(jsDecodeURIComponent("") == "")
        // Rejected (node throws URIError on every one of these).
        #expect(jsDecodeURIComponent("%C0%80") == nil) // overlong 2-byte
        #expect(jsDecodeURIComponent("%E0%80%80") == nil) // overlong 3-byte
        #expect(jsDecodeURIComponent("%F0%80%80%80") == nil) // overlong 4-byte
        #expect(jsDecodeURIComponent("%F4%90%80%80") == nil) // > U+10FFFF
        #expect(jsDecodeURIComponent("%80") == nil) // stray continuation
        #expect(jsDecodeURIComponent("%FF") == nil) // invalid lead
        #expect(jsDecodeURIComponent("%C2") == nil) // truncated sequence
        #expect(jsDecodeURIComponent("%C2%41") == nil) // bad continuation byte
        #expect(jsDecodeURIComponent("%GG") == nil) // non-hex
        #expect(jsDecodeURIComponent("%2") == nil) // dangling
    }
}

/// FINDING 5: `genMs` rounding. RN uses `Math.round`, whose ties go toward
/// +INFINITY; Swift's `.rounded()` breaks ties AWAY FROM ZERO and `Int(_:)`
/// TRAPS on NaN / out-of-range. Kotlin saturated silently. Both ports now run
/// these exact cases so they cannot drift apart again.
@Suite struct JsMathRoundTests {
    @Test func tiesGoTowardPositiveInfinityNotAwayFromZero() {
        // node: Math.round(x) for each input.
        let cases: [(Double, Double)] = [
            (0.5, 1),
            (-0.5, -0), // Swift .rounded() gives -1
            (1.5, 2),
            (-1.5, -1), // Swift .rounded() gives -2
            (2.5, 3),
            (-2.5, -2), // Swift .rounded() gives -3
            (4.5, 5),
            (-4.5, -4),
            (-0.4, -0),
            (0.4, 0),
            (-1.6, -2),
            (2.4, 2),
            (0, 0),
            (-0.0, -0.0),
            // floor(x + 0.5) answers 1 here because the ADDITION rounds up;
            // node's Math.round answers 0.
            (0.49999999999999994, 0),
            (-0.49999999999999994, -0),
            // Already-integral doubles beyond 2^52 pass straight through.
            (9_007_199_254_740_993.0, 9_007_199_254_740_992.0),
            (1e300, 1e300),
        ]
        for (input, expected) in cases {
            let actual = jsMathRound(input)
            #expect(actual == expected, "jsMathRound(\(input)) == \(actual)")
        }
        #expect(jsMathRound(.nan).isNaN)
        #expect(jsMathRound(.infinity) == .infinity)
        #expect(jsMathRound(-.infinity) == -.infinity)
        // Math.round(-0.5) is -0, not +0.
        #expect(jsMathRound(-0.5).sign == .minus)
    }

    @Test func narrowingToIntClampsInsteadOfTrapping() {
        #expect(jsRoundToInt(1234.4) == 1234)
        #expect(jsRoundToInt(-0.5) == 0)
        #expect(jsRoundToInt(-2.5) == -2)
        #expect(jsRoundToInt(2.5) == 3)
        // Int(_:) used to TRAP (fatalError) on all four of these.
        #expect(jsRoundToInt(.nan) == 0)
        #expect(jsRoundToInt(.infinity) == Int.max)
        #expect(jsRoundToInt(-.infinity) == Int.min)
        #expect(jsRoundToInt(1e30) == Int.max)
        #expect(jsRoundToInt(-1e30) == Int.min)
        // The exact Int64 boundary: 2^63 is out of range, 2^63 - 1024 is in.
        #expect(jsRoundToInt(9_223_372_036_854_775_808.0) == Int.max)
        #expect(jsRoundToInt(-9_223_372_036_854_775_808.0) == Int.min)
        #expect(jsRoundToInt(9_223_372_036_854_774_784.0) == 9_223_372_036_854_774_784)
    }
}

/// FINDING 4: `openDeepLink`'s fallback name. RN's
/// `appId.charAt(0).toUpperCase() + appId.slice(1)` splits at a UTF-16 CODE
/// UNIT, so an astral first character becomes a lone high surrogate with no
/// case mapping and survives unchanged. DECISION: match RN (Kotlin already
/// does) rather than keep the grapheme-level deviation.
@Suite struct JsCapitalizeFirstTests {
    @Test func astralFirstCharacterIsLeftAloneLikeUtf16CharAt() {
        // node: "\u{10428}eseret".charAt(0).toUpperCase() + ....slice(1)
        //       === "\u{10428}eseret"   (NOT the U+10400 uppercase form)
        #expect(jsCapitalizeFirst("\u{10428}eseret") == "\u{10428}eseret")
        // A non-cased astral first char is unchanged either way.
        #expect(jsCapitalizeFirst("😀app") == "😀app")
    }

    @Test func bmpFirstCharacterStillCapitalizesLikeJs() {
        // The path the fix must NOT break: every BMP case still matches node.
        #expect(jsCapitalizeFirst("stocks") == "Stocks")
        #expect(jsCapitalizeFirst("") == "")
        #expect(jsCapitalizeFirst("a") == "A")
        #expect(jsCapitalizeFirst("A") == "A")
        #expect(jsCapitalizeFirst("1up") == "1up")
        // node: "écho".charAt(0).toUpperCase() + slice(1) === "Écho"
        #expect(jsCapitalizeFirst("e\u{301}cho") == "E\u{301}cho")
        // One code unit can uppercase to SEVERAL, in JS and in Swift alike.
        // node: "ßeta".charAt(0).toUpperCase() + slice(1) === "SSeta"
        #expect(jsCapitalizeFirst("ßeta") == "SSeta")
        // node: "ﬁle".charAt(0).toUpperCase() + slice(1) === "FIle"
        #expect(jsCapitalizeFirst("\u{FB01}le") == "FIle")
    }
}

/// FINDING 6: non-`StreamError` degradation text. RN emits the bare
/// `err.message`; `String(describing:)` emitted a type-and-case description
/// and Kotlin's `toString()` a fully-qualified class prefix, so all three
/// disagreed - in text that reaches the MODEL (tool ERROR string) and the
/// USER (`Screen.error`).
@Suite struct ErrorMessageDegradationTests {
    private struct Carrier: LocalizedError {
        var errorDescription: String? { "network unreachable" }
    }

    private struct Bare: Error {}

    private enum Cases: Error {
        case timedOut
    }

    @Test func bareMessageIsExtractedWithoutTypeDecoration() {
        #expect(jsErrorMessage(StreamError("boom")) == "boom")
        #expect(jsErrorMessage(Carrier()) == "network unreachable")
        // No message to carry: the SIMPLE type name, never "Bare()" and never
        // a module-qualified spelling.
        #expect(jsErrorMessage(Bare()) == "Bare")
        #expect(!jsErrorMessage(Bare()).contains("."))
        #expect(!jsErrorMessage(Bare()).contains("("))
        // String(describing:) would have said "timedOut" - the CASE, which the
        // Kotlin port has no analog for.
        #expect(jsErrorMessage(Cases.timedOut) == "Cases")
    }
}

// JSON.parse strictness parity for the hand-rolled parser: where JSON.parse
// throws, JSONValue.parse must return nil so the SSE layer skips the chunk
// exactly where RN's try/catch does.
@Suite struct JSONParseStrictnessTests {
    @Test func leadingZeroNumbersRejectedLikeJsonParse() {
        #expect(JSONValue.parse("01") == nil)
        #expect(JSONValue.parse("-01") == nil)
        #expect(JSONValue.parse("00") == nil)
        #expect(JSONValue.parse("{\"a\":01}") == nil)
        // Still-valid shapes stay accepted.
        #expect(JSONValue.parse("0") == .number(0))
        #expect(JSONValue.parse("-0") == .number(-0.0))
        #expect(JSONValue.parse("0.5") == .number(0.5))
        #expect(JSONValue.parse("0e2") == .number(0))
        #expect(JSONValue.parse("10") == .number(10))
    }

    @Test func rawControlCharsInStringsRejectedLikeJsonParse() {
        // JSON.parse throws on unescaped U+0000-U+001F inside strings.
        #expect(JSONValue.parse("\"a\tb\"") == nil)
        #expect(JSONValue.parse("\"a\u{01}b\"") == nil)
        #expect(JSONValue.parse("{\"k\":\"a\nb\"}") == nil)
        // Escaped forms and DEL (U+007F, allowed by JSON.parse) still work.
        #expect(JSONValue.parse("\"a\\tb\"") == .string("a\tb"))
        #expect(JSONValue.parse("\"a\u{7F}b\"") == .string("a\u{7F}b"))
    }

    @Test func loneSurrogateEscapesBecomeReplacementNotChunkLoss() {
        // node: JSON.parse('"\\ud800x"') yields a 2-unit string carrying the
        // unpaired surrogate, which degrades to U+FFFD the moment it is UTF-8
        // encoded. Swift String cannot hold a lone surrogate at all, so we
        // substitute U+FFFD at parse time: the same NET observable result.
        //
        // Rejecting the document instead (the previous behavior) was strictly
        // worse than the divergence it was avoiding - StreamClient skips a
        // chunk it cannot parse, so ONE bad scalar silently dropped an entire
        // content delta while RN kept the delta and lost only that character.
        #expect(JSONValue.parse("\"\\ud800x\"") == .string("\u{FFFD}x"))
        #expect(JSONValue.parse("\"\\udc00\"") == .string("\u{FFFD}"))
        #expect(JSONValue.parse("\"\\ud800\\ud800\"") == .string("\u{FFFD}\u{FFFD}"))
        // Proper pairs still decode.
        #expect(JSONValue.parse("\"\\ud83d\\ude00\"") == .string("😀"))
    }
}

// JSON.stringify number formatting is ECMAScript Number::toString, whose
// positional/exponential thresholds and exponent spelling differ from Swift's
// "\(d)" (JS writes 10000000000000000 / 0.00001 / 1e-7 where Swift writes
// 1e+16 / 1e-05 / 1e-07). Expectations below are node v22 JSON.stringify
// outputs. The algorithm is shared with OpenUILang's TreeSerializer, which
// pins it against a 267-entry node table.
@Suite struct JSONStringifyNumberTests {
    @Test func numberStringMatchesJsonStringify() {
        let cases: [(Double, String)] = [
            (1e16, "10000000000000000"),
            (9007199254740994, "9007199254740994"),
            (-1e17, "-100000000000000000"),
            (1e-5, "0.00001"),
            (1e-6, "0.000001"),
            (1e-7, "1e-7"),
            (-1e-7, "-1e-7"),
            (1e-10, "1e-10"),
            (1e20, "100000000000000000000"),
            (1e21, "1e+21"),
            (-0.0, "0"),
            (0.1, "0.1"),
            (0.1 + 0.2, "0.30000000000000004"),
            // A literal 5e-324 warns ("underflows and loses precision during
            // conversion to Double") - same value, no warning.
            (Double.leastNonzeroMagnitude, "5e-324"),
            (1.7976931348623157e308, "1.7976931348623157e+308"),
            (pow(2, 56), "72057594037927940"),
            (pow(2, 53), "9007199254740992"),
            (-9007199254740994, "-9007199254740994"),
            (1.0 / 3.0, "0.3333333333333333"),
            (-0.5, "-0.5"),
        ]
        for (input, expected) in cases {
            #expect(JSONValue.numberString(input) == expected, "numberString(\(input))")
        }
        // JSON.stringify emits null for non-finite numbers.
        #expect(JSONValue.numberString(.nan) == "null")
        #expect(JSONValue.numberString(.infinity) == "null")
    }

    /// Pins the RAW serialized bytes - key ordering AND number formatting -
    /// rather than laundering them through a re-parse, which is what every
    /// other body assertion does.
    @Test func stringifiedEmitsExactBytes() {
        let body = JSONValue.object([
            "model": .string("gemma-4-31b"),
            "temperature": .number(0.8),
            "max_completion_tokens": .number(3072),
            "stream": .bool(true),
        ])
        // Compare UTF-8 BYTES: Swift's String == is canonical equivalence and
        // would absorb a normalization-level escaping bug.
        #expect(
            Data(body.stringified().utf8)
                == Data(#"{"model":"gemma-4-31b","temperature":0.8,"max_completion_tokens":3072,"stream":true}"#.utf8)
        )
        // Nested objects keep INSERTION order at every depth, exactly like
        // JSON.stringify - node: JSON.stringify({zeta:1e16, alpha:1e-7,
        // nested:{b:-0, a:[1,null]}}) === the string below. The previous
        // expectation here sorted the nested keys, which encoded the bug this
        // ordered representation fixes.
        let form: [(String, JSONValue)] = [
            ("zeta", .number(1e16)),
            ("alpha", .number(1e-7)),
            ("nested", .object(["b": .number(-0.0), "a": .array([.number(1), .null])])),
        ]
        #expect(
            Data(JSONValue.stringifyOrdered(form).utf8)
                == Data(#"{"zeta":10000000000000000,"alpha":1e-7,"nested":{"b":0,"a":[1,null]}}"#.utf8)
        )
    }

    /// FINDING 1: `stringifyOrdered` preserved caller order only at the TOP
    /// level; nested values fell through to sorted keys. Form state is THREE
    /// levels deep (`{formName: {fieldName: {value, componentType}}}`), so
    /// every submitted form was alphabetized where RN and Kotlin emit
    /// insertion order.
    @Test func insertionOrderIsPreservedAtEveryDepth() {
        // node: JSON.stringify({signup:{email:{value:"a@b.c",componentType:"TextField"},
        //                               age:{value:30,componentType:"Slider"}}})
        let formState: [(String, JSONValue)] = [
            ("signup", .object([
                "email": .object(["value": .string("a@b.c"), "componentType": .string("TextField")]),
                "age": .object(["value": .number(30), "componentType": .string("Slider")]),
            ])),
        ]
        #expect(
            Data(JSONValue.stringifyOrdered(formState).utf8) == Data(
                #"{"signup":{"email":{"value":"a@b.c","componentType":"TextField"},"age":{"value":30,"componentType":"Slider"}}}"#.utf8
            )
        )

        // Four levels, every one REVERSE-alphabetical, so a sort anywhere in
        // the recursion is visible - the path the fix does not naturally take.
        let deep: [(String, JSONValue)] = [
            ("z", .object(["y": .object(["x": .object(["w": .number(1), "a": .number(2)]), "a": .number(3)])])),
            ("a", .number(4)),
        ]
        #expect(
            Data(JSONValue.stringifyOrdered(deep).utf8)
                == Data(#"{"z":{"y":{"x":{"w":1,"a":2},"a":3}},"a":4}"#.utf8)
        )

        // Objects nested inside ARRAYS recurse through the same path.
        let inArray = JSONValue.object([
            "items": .array([.object(["b": .number(1), "a": .number(2)])]),
        ])
        #expect(Data(inArray.stringified().utf8) == Data(#"{"items":[{"b":1,"a":2}]}"#.utf8))
    }

    /// FINDING 1 (second half): `OrdinaryOwnPropertyKeys` promotes CANONICAL
    /// array-index keys ahead of everything else in ascending NUMERIC order,
    /// so "2" precedes "10" - a plain lexicographic sort emitted "10" first,
    /// and plain insertion order would emit them as written.
    @Test func canonicalArrayIndexKeysSortNumericallyFirst() {
        // node: JSON.stringify({f:{"10":1,"2":2,"b":3}}) === {"f":{"2":2,"10":1,"b":3}}
        let nested: [(String, JSONValue)] = [
            ("f", .object(["10": .number(1), "2": .number(2), "b": .number(3)])),
        ]
        #expect(
            Data(JSONValue.stringifyOrdered(nested).utf8)
                == Data(#"{"f":{"2":2,"10":1,"b":3}}"#.utf8)
        )

        // NON-canonical numeric-looking keys are NOT array indices and stay in
        // insertion order among the rest. node:
        // JSON.stringify({"01":1,"1.0":2,"+1":3,"-1":4,"1e2":5,"4294967295":6,"4294967294":7,"1":8})
        // === {"1":8,"4294967294":7,"01":1,"1.0":2,"+1":3,"-1":4,"1e2":5,"4294967295":6}
        let tricky = JSONValue.object([
            "01": .number(1),
            "1.0": .number(2),
            "+1": .number(3),
            "-1": .number(4),
            "1e2": .number(5),
            "4294967295": .number(6), // 2^32-1: one PAST the last array index
            "4294967294": .number(7), // 2^32-2: the LAST array index
            "1": .number(8),
        ])
        #expect(
            Data(tricky.stringified().utf8) == Data(
                #"{"1":8,"4294967294":7,"01":1,"1.0":2,"+1":3,"-1":4,"1e2":5,"4294967295":6}"#.utf8
            )
        )

        // Empty-key and "0" edges. node: JSON.stringify({"":1,"0":2,"b":3})
        // === {"0":2,"":1,"b":3}
        #expect(
            Data(JSONValue.object(["": .number(1), "0": .number(2), "b": .number(3)]).stringified().utf8)
                == Data(#"{"0":2,"":1,"b":3}"#.utf8)
        )
    }

    /// The paths ordering could silently regress through: re-assignment keeps
    /// a key's ORIGINAL position with its LAST value (JS `o.a=1;o.b=2;o.a=3`),
    /// parsing keeps DOCUMENT order, and `==` stays order-INSENSITIVE so
    /// structural assertions are unaffected by ordering.
    @Test func objectKeyPositionsFollowJsAssignmentAndParseOrder() {
        var obj = JSONObject()
        obj["a"] = .number(1)
        obj["b"] = .number(2)
        obj["a"] = .number(3)
        #expect(Data(JSONValue.object(obj).stringified().utf8) == Data(#"{"a":3,"b":2}"#.utf8))

        // A duplicate in the ordered pair list behaves the same way.
        #expect(
            Data(JSONValue.stringifyOrdered([("a", .number(1)), ("b", .number(2)), ("a", .number(3))]).utf8)
                == Data(#"{"a":3,"b":2}"#.utf8)
        )

        // node: JSON.stringify(JSON.parse('{"z":1,"a":{"y":2,"b":3}}')) round-trips verbatim.
        let parsed = try? #require(JSONValue.parse(#"{"z":1,"a":{"y":2,"b":3}}"#))
        #expect(Data((parsed?.stringified() ?? "").utf8) == Data(#"{"z":1,"a":{"y":2,"b":3}}"#.utf8))

        #expect(JSONValue.object(["a": .number(1), "b": .number(2)])
            == JSONValue.object(["b": .number(2), "a": .number(1)]))
    }

    /// encodeJSONString had no direct coverage - escaping shipped pinned only
    /// by ASCII payloads. JSON.stringify uses the two-character shortcuts,
    /// \uXXXX for the remaining C0 controls, leaves "/" and U+007F DEL raw, and
    /// does NOT escape U+2028/U+2029 (a classic port bug: some serializers do).
    @Test func encodeJSONStringMatchesJsonStringifyBytes() {
        let cases: [(String, String)] = [
            ("plain", #""plain""#),
            ("quote\" back\\slash", #""quote\" back\\slash""#),
            ("tab\tnewline\ncr\r", #""tab\tnewline\ncr\r""#),
            ("form\u{0C}back\u{08}", #""form\fback\b""#),
            ("ctrl\u{01}\u{1F}", #""ctrl\u0001\u001f""#),
            ("slash/and\u{7F}del", "\"slash/and\u{7F}del\""),
            ("line\u{2028}para\u{2029}", "\"line\u{2028}para\u{2029}\""),
            ("astral\u{1F327}end", "\"astral\u{1F327}end\""),
            ("nbsp\u{A0}bom\u{FEFF}", "\"nbsp\u{A0}bom\u{FEFF}\""),
            ("combining e\u{301}", "\"combining e\u{301}\""),
        ]
        for (input, expected) in cases {
            let hex = input.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " ")
            #expect(
                Data(JSONValue.encodeJSONString(input).utf8) == Data(expected.utf8),
                "encodeJSONString(scalars: \(hex))"
            )
        }
    }
}
