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
