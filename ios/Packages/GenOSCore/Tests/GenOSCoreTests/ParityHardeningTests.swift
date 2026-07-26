import Foundation
import Testing
@testable import GenOSCore

// Findings closed in this file come from a differential review whose ORACLE is
// the real RN source (src/genos/{stream,store,tools}.ts) executed under node
// with only `expo/fetch` and `src/config` stubbed. Every expectation below was
// produced by running that oracle or a bare `node -e`, never by reading either
// port. The generating command is named on each suite.

// MARK: - Finding 1: UTF-16 splice vs grapheme rounding

/// `JSRegex.replacingFirst` used to call `NSString.replacingCharacters(in:with:)`,
/// and swift-corelibs-foundation rounds an `NSRange` to GRAPHEME-CLUSTER
/// boundaries before splicing. A combining mark is one grapheme with the
/// character it follows, so any match ENDING immediately before a combining
/// mark under-deleted.
///
/// The hazard is a CLASS, not a case: it fires wherever a ported pattern ends
/// on a delimiter that a model can glue a combining mark onto. The previous
/// suite pinned exactly one instance of it - the CLOSING fence, which goes
/// through `jsUTF16Index`/`jsSlice` (`LangHelpersTests`) - while the OPENING
/// fence, one line above and on the buggy path, had no combining-mark case at
/// all. So these tests cover BOTH sides of EVERY fence and delimiter, and add
/// two properties over the whole class.
///
/// Expectations from the RN oracle (`probe1.ts` against src/genos/store.ts):
///
///     open fence + CM              [` ` ` U+301 \n x] => [U+301 \n x]
///     open fence lang + CM         [` ` ` l a n g U+301 \n x] => [U+301 \n x]
///     close fence + CM (pinned)    [` ` ` \n x \n ` ` ` U+301] => [x]
///     close fence CM, no open      [x \n ` ` ` U+301] => [x \n ` ` ` U+301]
@MainActor
@Suite struct JSRegexSpliceTests {
    private static let cm = "\u{301}" // COMBINING ACUTE ACCENT

    /// All 13 cases the RN oracle was run over, verbatim. Combining marks sit
    /// on BOTH sides of BOTH fences, plus the leading-whitespace and
    /// no-trailing-newline variants that take the other branch of `cleanLang`.
    @Test func cleanLangMatchesRNWithCombiningMarksOnEveryFence() {
        let cm = Self.cm
        let cases: [(name: String, input: String, expected: String)] = [
            // --- OPENING fence: the branch that was broken. ---
            ("open fence + CM", "```" + cm + "\nx", cm + "\nx"),
            ("open fence lang + CM", "```lang" + cm + "\nx", cm + "\nx"),
            ("open fence lang + CM + ws", "```lang" + cm + " \nx", cm + " \nx"),
            ("bare open, no newline", "```" + cm + "x", cm + "x"),
            ("open fence CRLF", "```" + cm + "\r\nx", cm + "\r\nx"),
            ("astral straight after fence", "```\u{1F600}\nx", "\u{1F600}\nx"),
            // --- CLOSING fence, `opened` branch (jsUTF16Index/jsSlice). ---
            ("close fence + CM", "```\nx\n```" + cm, "x"),
            ("open+close both CM", "```" + cm + "\nx\n```" + cm, cm + "\nx"),
            // --- CLOSING fence, NOT-opened branch (replacingFirst again). ---
            ("close fence CM, no open", "x\n```" + cm, "x\n```" + cm),
            ("close CM after ws, no open", "x\n``` " + cm, "x\n``` " + cm),
            ("CRLF close, no open", "x\n```\r\n", "x"),
            // --- No fence at all. ---
            ("lead ws CM before fence", " " + cm + "```\nx", " " + cm + "```\nx"),
            ("no fence, leading CM", cm + "x", cm + "x"),
        ]
        for c in cases {
            #expect(
                Array(Lang.cleanLang(c.input).unicodeScalars.map(\.value))
                    == Array(c.expected.unicodeScalars.map(\.value)),
                "\(c.name): cleanLang mismatch vs RN oracle"
            )
        }
    }

    /// PROPERTY over the hazard class, with an INDEPENDENT oracle:
    /// `replacingAll` splices at the UTF-16 level itself (verified against node
    /// - see `replacingAllWasNeverAffected`), so for a pattern with exactly ONE
    /// match the two must agree. This catches the whole class rather than the
    /// one fence that happened to break.
    @Test func replacingFirstAgreesWithReplacingAllOnEverySingleMatchSplice() {
        // Every ASCII delimiter the ported patterns end on, and a combining
        // mark, a surrogate pair, and a CRLF glued straight after each.
        let delimiters = ["`", "\n", " ", "\t", "\"", ")", ",", "@", "-", "_"]
        let tails = [Self.cm, "\u{301}\u{327}", "\u{1F600}", "\r\n", "", "a"]
        let templates = ["", "X", "[$0]"]
        var checked = 0
        for d in delimiters {
            for tail in tails {
                for template in templates {
                    let text = "pre" + d + tail + "post"
                    let pattern = NSRegularExpression.escapedPattern(for: d)
                    // Only compare where the match really is unique.
                    guard JSRegex.all(pattern, text).count == 1 else { continue }
                    let first = JSRegex.replacingFirst(pattern, in: text, with: template)
                    let all = JSRegex.replacingAll(pattern, in: text, with: template)
                    #expect(
                        Array(first.utf16) == Array(all.utf16),
                        "delimiter \(d.debugDescription) tail \(tail.debugDescription) template \(template)"
                    )
                    checked += 1
                }
            }
        }
        #expect(checked >= 100, "property covered too few combinations: \(checked)")
    }

    /// PROPERTY: a splice must delete EXACTLY the matched UTF-16 units. This is
    /// the invariant grapheme rounding violated - the old code under-deleted,
    /// and for a match whose range collapsed entirely it INSERTED the template
    /// while deleting nothing.
    @Test func replacingFirstConservesUTF16UnitCounts() {
        let bases = ["ab" + Self.cm + "c", "```" + Self.cm + "\nx", "a\u{1F600}b", "x\r\ny"]
        let patterns = ["b", "```", "a", "\\n", "[abx]"]
        for text in bases {
            for pattern in patterns {
                guard let m = JSRegex.first(pattern, text), m[0] != nil else { continue }
                let matchedUnits = m[0]!.utf16.count
                let deleted = JSRegex.replacingFirst(pattern, in: text, with: "")
                #expect(
                    deleted.utf16.count == text.utf16.count - matchedUnits,
                    "pattern \(pattern) on \(text.debugDescription) deleted the wrong unit count"
                )
            }
        }
    }

    /// The path the fix does NOT take. `stringByReplacingMatches` was already
    /// correct, and is left delegating; this pins that so a future "consistency"
    /// rewrite cannot regress it into the same hazard.
    ///
    ///     $ node -e 'console.log(JSON.stringify("ab́c".replace(/b/g,"X")))'
    ///     "aX́c"
    ///     $ node -e 'console.log(JSON.stringify("áb́c".replace(/[ab]/g,"")))'
    ///     "́́c"
    @Test func replacingAllWasNeverAffected() {
        let cm = Self.cm
        #expect(JSRegex.replacingAll("b", in: "ab" + cm + "c", with: "X") == "a" + "X" + cm + "c")
        #expect(JSRegex.replacingAll("[ab]", in: "a" + cm + "b" + cm + "c", with: "") == cm + cm + "c")
        // jsTrim rides on replacingAll: a combining mark adjacent to stripped
        // whitespace must survive, on both ends.
        #expect(jsTrim(" " + cm + "abc" + cm + " ") == cm + "abc" + cm)
        #expect(jsTrim("\u{FEFF}" + cm + "abc") == cm + "abc")
    }
}

// MARK: - Findings 4/5: ECMAScript ToString

/// `jsStringCoerce` is JS `String(value)` / `"" + value`, NOT `JSON.stringify`.
/// It used to return JSON text for arrays and objects, and BOTH READMEs called
/// that a permanent deviation on the grounds that "a non-string never survives
/// the non-empty check" - which is false: `String([1,2])` is "1,2".
///
/// Table generated by `node gen-tostring.mjs` (JSON document → `String(value)`):
///
///     [1,2]        "1,2"          {"a":1}   "[object Object]"
///     []           ""             {}        "[object Object]"
///     [null]       ""             [[]]      ""
///     [null,null]  ","            ["",""]   ","
///     [[1],[2]]    "1,2"          [1,[2,[3]]]  "1,2,3"
///     [{"a":1}]    "[object Object]"
///     1e999        "Infinity"     -1e999    "-Infinity"
///     1e21         "1e+21"        -0        "0"
@Suite struct JSToStringTests {
    @Test func jsStringCoerceMatchesNodeStringForEveryShape() {
        // (JSON document, node `String(JSON.parse(doc))`).
        let table: [(String, String)] = [
            ("null", ""), // call sites fuse `?? ""` / a truthiness guard
            ("\"hi\"", "hi"), ("\"\"", ""),
            ("3072", "3072"), ("1e-7", "1e-7"), ("0", "0"), ("-0", "0"),
            ("1e21", "1e+21"), ("1e999", "Infinity"), ("-1e999", "-Infinity"),
            ("3.5", "3.5"), ("-2.5", "-2.5"),
            ("9007199254740993", "9007199254740992"),
            ("true", "true"), ("false", "false"),
            ("[1,2]", "1,2"), ("[]", ""), ("[null]", ""),
            ("[\"a\",\"b\"]", "a,b"), ("[[1],[2]]", "1,2"), ("[1,[2,[3]]]", "1,2,3"),
            ("[[]]", ""), ("[{\"a\":1}]", "[object Object]"),
            ("[null,null]", ","), ("[\"\",\"\"]", ","), ("[true,false]", "true,false"),
            ("[1e999]", "Infinity"), ("[-0]", "0"),
            ("{\"a\":1}", "[object Object]"), ("{}", "[object Object]"),
        ]
        for (doc, expected) in table {
            let parsed = JSONValue.parse(doc)
            #expect(parsed != nil, "fixture \(doc) failed to parse")
            #expect(jsStringCoerce(parsed) == expected, "String(\(doc))")
        }
    }

    /// The path ToString takes that `JSON.stringify` does not: non-finite
    /// numbers. `numberString` renders them "null" (correct for a request
    /// body); ToString must not.
    ///
    ///     $ node -e 'console.log(String(1/0), String(-1/0), String(0/0))'
    ///     Infinity -Infinity NaN
    @Test func nonFiniteNumbersStringifyDifferentlyFromJSONStringify() {
        #expect(jsNumberToString(.infinity) == "Infinity")
        #expect(jsNumberToString(-.infinity) == "-Infinity")
        #expect(jsNumberToString(.nan) == "NaN")
        // ... while the JSON.stringify rule still renders them null.
        #expect(JSONValue.numberString(.infinity) == "null")
        #expect(JSONValue.numberString(.nan) == "null")
        // Reachable: JSON.parse("1e999") is Infinity, not an error.
        #expect(JSONValue.parse("1e999")?.numberValue == .infinity)
        #expect(jsStringCoerce(JSONValue.parse("1e999")) == "Infinity")
    }
}

// MARK: - Findings 2/5: hostile tool_call index + non-string deltas

@MainActor
@Suite struct StreamHostileChunkTests {
    private func toolCallChunk(index: String, id: String, args: String) -> String {
        let escaped = args.replacingOccurrences(of: "\"", with: "\\\"")
        return "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":\(index),"
            + "\"id\":\"\(id)\",\"function\":{\"name\":\"web_search\",\"arguments\":\"\(escaped)\"}}]}}]}\n"
    }

    /// FINDING 2. RN keys its accumulator `Map` by the RAW Number, so `3.2` and
    /// `3.7` are TWO distinct calls. Both ports narrowed to `Int`, collapsing
    /// them onto key 3 and CONCATENATING the two `arguments` blobs into
    /// `{"query":"x"}{"query":"y"}` - which fails `JSON.parse` and degrades to
    /// `args={}`, so one tool round went out instead of two.
    ///
    /// The hazard is the CLASS "any Double→Int narrowing", not one literal, so
    /// the pairs below are chosen to collapse under DIFFERENT narrowings - a
    /// test using only 3.2/3.7 passes against `jsRoundToInt` (3 and 4) and so
    /// would have certified the Swift port while the Kotlin sibling, which
    /// truncated, merged them:
    ///
    ///     (3.2, 3.4)  collapse under BOTH truncation and rounding
    ///     (3.7, 4.2)  collapse under rounding only
    ///     (3.2, 3.7)  collapse under truncation only
    ///     (0.4, 0.5)  straddle the rounding tie
    ///     (-0.4,-0.6) negative, and RN sorts them call_b before call_a
    ///     (1e300,1e301) beyond Int64, where narrowing used to have to clamp
    ///
    /// RN oracle (`probe2b.ts`) - every pair is TWO calls:
    ///
    ///     3.2    /3.4     calls=2 ids=["call_a","call_b"]
    ///     3.7    /4.2     calls=2 ids=["call_a","call_b"]
    ///     3.2    /3.7     calls=2 ids=["call_a","call_b"]
    ///     0.4    /0.5     calls=2 ids=["call_a","call_b"]
    ///     -0.4   /-0.6    calls=2 ids=["call_b","call_a"]
    ///     1e+300 /1e+301  calls=2 ids=["call_a","call_b"]
    @Test func fractionalIndicesStayTwoDistinctCalls() async {
        let pairs: [(String, String, [String], [String])] = [
            ("3.2", "3.4", ["call_a", "call_b"], ["x", "y"]),
            ("3.7", "4.2", ["call_a", "call_b"], ["x", "y"]),
            ("3.2", "3.7", ["call_a", "call_b"], ["x", "y"]),
            ("0.4", "0.5", ["call_a", "call_b"], ["x", "y"]),
            ("-0.4", "-0.6", ["call_b", "call_a"], ["y", "x"]),
            ("1e300", "1e301", ["call_a", "call_b"], ["x", "y"]),
        ]
        for (a, b, expectedIDs, expectedQueries) in pairs {
            let http = ScriptedHTTP()
            await http.enqueue(.sse([
                toolCallChunk(index: a, id: "call_a", args: "{\"query\":\"x\"}"),
                toolCallChunk(index: b, id: "call_b", args: "{\"query\":\"y\"}"),
                sseFinish("tool_calls"),
                sseDone,
            ]))
            await http.enqueue(.sse([sseContent("second round"), sseFinish("stop"), sseDone]))
            let recorder = StreamRecorder()
            let client = makeStreamClient(http: http, tools: EchoTool())
            await client.streamScreen(
                messages: [ChatMessage(role: .user, content: "q")],
                handlers: recorder.handlers(),
                token: StreamCancelToken()
            )
            #expect(recorder.toolRounds.count == 1, "index \(a)/\(b)")
            #expect(recorder.toolRounds.first?.count == 2, "index \(a)/\(b) must not merge")
            #expect(
                recorder.toolRounds.first?.map { jsStringCoerce($0.args["query"]) } == expectedQueries,
                "index \(a)/\(b)"
            )
            // And both survive onto the wire, in ascending index order.
            let bodies = await http.requestBodies()
            let messages = bodies[1]["messages"]?.arrayValue ?? []
            let assistant = messages.first { $0["role"]?.stringValue == "assistant" }
            #expect(
                assistant?["tool_calls"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == expectedIDs,
                "index \(a)/\(b)"
            )
            #expect(
                messages.filter { $0["role"]?.stringValue == "tool" }
                    .map { $0["tool_call_id"]?.stringValue } == expectedIDs,
                "index \(a)/\(b)"
            )
        }
    }

    /// PROBE on the path the fix does NOT take: keys that RN's `Map` DOES
    /// unify must still unify here. A JS Map key uses SameValueZero, under
    /// which -0 and +0 are the SAME key, and an absent/null `index` falls to 0.
    ///
    /// RN oracle (`probe2.ts`, scenarios C/E/F) - all three merge into ONE call
    /// whose arguments are the concatenation, which then fails JSON.parse:
    ///
    ///     E. index -0 / 0
    ///       toolRound calls: [{"name":"web_search","args":{}}]
    ///       assistant.tool_calls: [{"id":"call_b", ... "arguments":
    ///                               "{\"query\":\"x\"}{\"query\":\"y\"}"}]
    @Test func keysRNUnifiesAreStillUnified() async {
        for (a, b) in [("3.7", "3.7"), ("-0", "0"), ("null", "0")] {
            let http = ScriptedHTTP()
            await http.enqueue(.sse([
                toolCallChunk(index: a, id: "call_a", args: "{\"query\":\"x\"}"),
                toolCallChunk(index: b, id: "call_b", args: "{\"query\":\"y\"}"),
                sseFinish("tool_calls"),
                sseDone,
            ]))
            await http.enqueue(.sse([sseContent("second"), sseFinish("stop"), sseDone]))
            let recorder = StreamRecorder()
            let client = makeStreamClient(http: http, tools: EchoTool())
            await client.streamScreen(
                messages: [ChatMessage(role: .user, content: "q")],
                handlers: recorder.handlers(),
                token: StreamCancelToken()
            )
            #expect(recorder.toolRounds.first?.count == 1, "index \(a)/\(b) must merge like RN")
            // Concatenated arguments are unparseable, so RN degrades to {}.
            #expect(recorder.toolRounds.first?.first?.args.isEmpty == true, "index \(a)/\(b)")
            let bodies = await http.requestBodies()
            let messages = bodies[1]["messages"]?.arrayValue ?? []
            let assistant = messages.first { $0["role"]?.stringValue == "assistant" }
            #expect(
                assistant?["tool_calls"]?[0]?["function"]?["arguments"]?.stringValue
                    == "{\"query\":\"x\"}{\"query\":\"y\"}",
                "index \(a)/\(b)"
            )
        }
    }

    /// The regression guard from commit 676f009 still holds with the accumulator
    /// keyed by Double: no narrowing happens at all now, so the trapping
    /// `Int(_: Double)` initializer is unreachable by construction.
    @Test func hostileIndicesStillDoNotTrapTheProcess() async {
        for index in ["1e300", "1e999", "-1e999", "-1e300", "3.7", "-0", "0.5"] {
            let http = ScriptedHTTP()
            await http.enqueue(.sse([
                toolCallChunk(index: index, id: "c", args: "{\"query\":\"x\"}"),
                sseFinish("tool_calls"),
                sseDone,
            ]))
            await http.enqueue(.sse([sseContent("second round"), sseFinish("stop"), sseDone]))
            let recorder = StreamRecorder()
            let client = makeStreamClient(http: http, tools: EchoTool())
            await client.streamScreen(
                messages: [ChatMessage(role: .user, content: "q")],
                handlers: recorder.handlers(),
                token: StreamCancelToken()
            )
            #expect(recorder.errors.isEmpty, "index \(index) surfaced an error")
            #expect(recorder.deltas == ["second round"], "index \(index)")
        }
    }

    /// FINDING 5a. RN: `msg = typeof error === "string" ? error : error.message`
    /// then `new Error(msg || "stream error")`, and `new Error` runs ToString on
    /// a non-string argument.
    ///
    /// RN oracle (`probe56.ts`), left column is the `error` value:
    ///
    ///     {"message":42}          => "42"
    ///     {"message":true}        => "true"
    ///     {"message":[1,2]}       => "1,2"
    ///     {"message":{"nested":1}}=> "[object Object]"
    ///     {"message":0}           => "stream error"   (falsy)
    ///     {"message":false}       => "stream error"
    ///     {"message":null}        => "stream error"
    ///     {"message":""}          => "stream error"
    ///     42                      => "stream error"   (not a string, no .message)
    ///     true / [] / {}          => "stream error"
    ///     "boom"                  => "boom"
    ///     0 / ""                  => (falsy: no error at all, onDone instead)
    @Test func nonStringErrorMessagesAreToStringCoercedLikeRN() async {
        let cases: [(payload: String, expected: String)] = [
            ("{\"message\":42}", "42"),
            ("{\"message\":true}", "true"),
            ("{\"message\":[1,2]}", "1,2"),
            ("{\"message\":{\"nested\":1}}", "[object Object]"),
            ("{\"message\":1e999}", "Infinity"),
            // Falsy `msg` still falls through to the generic text.
            ("{\"message\":0}", "stream error"),
            ("{\"message\":false}", "stream error"),
            ("{\"message\":null}", "stream error"),
            ("{\"message\":\"\"}", "stream error"),
            // Truthy non-string error with no usable `.message`.
            ("42", "stream error"),
            ("true", "stream error"),
            ("[]", "stream error"),
            ("{}", "stream error"),
            // A string error passes through verbatim.
            ("\"boom\"", "boom"),
        ]
        for c in cases {
            let http = ScriptedHTTP()
            await http.enqueue(.sse(["data: {\"error\":\(c.payload)}\n", sseDone]))
            let recorder = StreamRecorder()
            let client = makeStreamClient(http: http)
            await client.streamScreen(
                messages: [ChatMessage(role: .user, content: "q")],
                handlers: recorder.handlers(),
                token: StreamCancelToken()
            )
            #expect(recorder.errors == [c.expected], "error payload \(c.payload)")
        }
    }

    /// PROBE on the path the fix does NOT take: a FALSY `chunk.error` is not an
    /// error at all in RN (`if (chunk.error)`), so the stream completes.
    ///
    /// RN oracle (`probe56.ts`): `error=0` and `error=""` both give
    /// `done: {"truncated":false,"dropped":false}` and no onError.
    @Test func falsyErrorValuesAreNotErrors() async {
        for payload in ["0", "\"\"", "false", "null"] {
            let http = ScriptedHTTP()
            await http.enqueue(.sse([
                "data: {\"error\":\(payload)}\n", sseContent("ok"), sseFinish("stop"), sseDone,
            ]))
            let recorder = StreamRecorder()
            let client = makeStreamClient(http: http)
            await client.streamScreen(
                messages: [ChatMessage(role: .user, content: "q")],
                handlers: recorder.handlers(),
                token: StreamCancelToken()
            )
            #expect(recorder.errors.isEmpty, "error payload \(payload) must not throw")
            #expect(recorder.doneInfos.count == 1, "error payload \(payload)")
        }
    }

    /// FINDING 5b. RN: `if (delta.content) { content += delta.content;
    /// onDelta(delta.content) }` - a truthy guard, then string concatenation,
    /// which coerces. Requiring a string dropped the delta entirely AND
    /// shortened the assistant replay message in the next round's body.
    ///
    /// RN oracle (`probe56.ts`): content=5 → deltas [5]; content=0/false/null/""
    /// → deltas []; and the round-2 assistant message carries `"content":"5"`.
    @Test func nonStringDeltaContentIsForwardedCoerced() async {
        let cases: [(payload: String, expected: [String])] = [
            ("5", ["5"]),
            ("true", ["true"]),
            ("{\"a\":1}", ["[object Object]"]),
            ("[1,2]", ["1,2"]),
            ("1e999", ["Infinity"]),
            ("\"ok\"", ["ok"]),
            // Falsy content is skipped, exactly as in RN.
            ("0", []), ("false", []), ("null", []), ("\"\"", []),
        ]
        for c in cases {
            let http = ScriptedHTTP()
            await http.enqueue(.sse([
                "data: {\"choices\":[{\"delta\":{\"content\":\(c.payload)}}]}\n",
                sseFinish("stop"), sseDone,
            ]))
            let recorder = StreamRecorder()
            let client = makeStreamClient(http: http)
            await client.streamScreen(
                messages: [ChatMessage(role: .user, content: "q")],
                handlers: recorder.handlers(),
                token: StreamCancelToken()
            )
            #expect(recorder.deltas == c.expected, "delta.content \(c.payload)")
            #expect(recorder.errors.isEmpty, "delta.content \(c.payload)")
        }
    }

    /// The coerced content must also reach the WIRE as the assistant replay
    /// message, which is where a dropped delta was observable to the model.
    ///
    /// RN oracle (`probe56.ts`, finding 5c):
    ///     assistant.content in round 2 body: "5"
    @Test func coercedContentReachesTheNextRoundsBody() async {
        let http = ScriptedHTTP()
        await http.enqueue(.sse([
            "data: {\"choices\":[{\"delta\":{\"content\":5}}]}\n",
            toolCallChunk(index: "0", id: "c1", args: "{\"query\":\"q\"}"),
            sseFinish("tool_calls"),
            sseDone,
        ]))
        await http.enqueue(.sse([sseContent("x"), sseFinish("stop"), sseDone]))
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http, tools: EchoTool())
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "q")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        let bodies = await http.requestBodies()
        let assistant = (bodies[1]["messages"]?.arrayValue ?? [])
            .first { $0["role"]?.stringValue == "assistant" }
        #expect(assistant?["content"]?.stringValue == "5")
    }

    /// RN concatenates `arguments` fragments onto a STRING, so a non-string
    /// fragment coerces rather than being dropped.
    ///
    /// RN oracle (`probe7.ts`): `{"arguments":9}` produces
    /// `"function":{"name":7,"arguments":"9"}` on the wire.
    @Test func nonStringArgumentFragmentsCoerceLikeStringConcat() async {
        let http = ScriptedHTTP()
        await http.enqueue(.sse([
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\","
                + "\"function\":{\"name\":\"web_search\",\"arguments\":9}}]}}]}\n",
            sseFinish("tool_calls"),
            sseDone,
        ]))
        await http.enqueue(.sse([sseContent("x"), sseFinish("stop"), sseDone]))
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http, tools: EchoTool())
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "q")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        let bodies = await http.requestBodies()
        let assistant = (bodies[1]["messages"]?.arrayValue ?? [])
            .first { $0["role"]?.stringValue == "assistant" }
        #expect(assistant?["tool_calls"]?[0]?["function"]?["arguments"]?.stringValue == "9")
    }

    /// RN's `dropped` consults the RAW `finish_reason` for truthiness, not a
    /// string. A truthy non-string one therefore means NOT dropped - and with
    /// no content that is the difference between a clean `onDone` and a thrown
    /// "stream dropped before any content arrived".
    ///
    /// RN oracle (`probe7.ts`):
    ///     fr=42, content "abc", no [DONE]  => done {"truncated":false,"dropped":false}
    ///     fr=42, no content,    no [DONE]  => done {"truncated":false,"dropped":false}
    ///     fr="",  no content,   no [DONE]  => error "stream dropped before any content arrived"
    @Test func truthyNonStringFinishReasonMeansNotDropped() async {
        for fr in ["42", "true", "{\"a\":1}"] {
            let http = ScriptedHTTP()
            await http.enqueue(.sse([
                "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\(fr)}]}\n",
            ]))
            let recorder = StreamRecorder()
            let client = makeStreamClient(http: http)
            await client.streamScreen(
                messages: [ChatMessage(role: .user, content: "q")],
                handlers: recorder.handlers(),
                token: StreamCancelToken()
            )
            #expect(recorder.errors.isEmpty, "finish_reason \(fr)")
            #expect(
                recorder.doneInfos == [StreamEndInfo(truncated: false, dropped: false)],
                "finish_reason \(fr)"
            )
        }
        // PROBE the other path: a FALSY finish_reason with no content and no
        // [DONE] is still a dropped stream.
        for fr in ["\"\"", "0", "null", "false"] {
            let http = ScriptedHTTP()
            await http.enqueue(.sse([
                "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\(fr)}]}\n",
            ]))
            let recorder = StreamRecorder()
            let client = makeStreamClient(http: http)
            await client.streamScreen(
                messages: [ChatMessage(role: .user, content: "q")],
                handlers: recorder.handlers(),
                token: StreamCancelToken()
            )
            #expect(recorder.errors == ["stream dropped before any content arrived"], "finish_reason \(fr)")
        }
        // And a truthy STRING finish_reason still drives truncated/tool_calls.
        let http = ScriptedHTTP()
        await http.enqueue(.sse([sseContent("a"), sseFinish("length")]))
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "q")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.doneInfos == [StreamEndInfo(truncated: true, dropped: false)])
    }
}

// MARK: - Findings 3/6: documented divergences, pinned as they actually behave

@MainActor
@Suite struct DocumentedDivergenceTests {
    /// FINDING 3, Swift side. ES2019 well-formed `JSON.stringify` ESCAPES an
    /// unpaired surrogate rather than encoding it:
    ///
    ///     $ node -e 'console.log(Buffer.from(JSON.stringify("pre\ud83dpost")).toString("hex"))'
    ///     227072655c7564383364706f737422        // "pre\ud83dpost"
    ///
    /// A Swift `String` cannot hold a lone surrogate at all, so this port
    /// substitutes U+FFFD at PARSE time (README KNOWN-DEVIATIONS #1) and the
    /// escape has nothing left to apply to. The Kotlin sibling, whose JVM
    /// `String` does hold the unit, now emits the RN bytes exactly.
    ///
    /// This test pins what the Swift port ACTUALLY puts on the wire, so the
    /// divergence is visible rather than assumed away - the README used to
    /// claim the net result matched RN on "every path in this package", which
    /// this output falsifies.
    @Test func loneSurrogateWireBytesDivergeFromRNAndAreDocumented() {
        // The parser has already replaced the lone surrogate by the time any
        // encoder sees it.
        let parsed = JSONValue.parse("\"pre\\ud83dpost\"")
        #expect(parsed?.stringValue == "pre\u{FFFD}post")

        let bytes = Array(Data(JSONValue.string(parsed?.stringValue ?? "").stringified().utf8))
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        // Raw UTF-8 U+FFFD (ef bf bd), NOT RN's six-byte \ud83d escape.
        #expect(hex == "227072" + "65" + "efbfbd" + "706f737422")
        #expect(hex != "227072655c7564383364706f737422", "RN's bytes - documented as unreachable here")

        // A WELL-FORMED pair is unaffected in both runtimes.
        //   $ node -e 'console.log(Buffer.from(JSON.stringify("pre\u{1F4A9}post")).toString("hex"))'
        //   22707265f09f92a9706f737422
        let pair = JSONValue.parse("\"pre\\ud83d\\udca9post\"")
        #expect(pair?.stringValue == "pre\u{1F4A9}post")
        let pairHex = Array(Data(JSONValue.string(pair?.stringValue ?? "").stringified().utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(pairHex == "22707265f09f92a9706f737422")
    }

    /// FINDING 6. RN's SUCCESS path calls `onDone` unconditionally; only the
    /// catch path checks `signal.aborted`. Both ports additionally suppress
    /// `onDelta`/`onDone` once the token is cancelled.
    ///
    /// RN oracle (`probe56.ts`), aborting during the first delta with a
    /// transport that ignores the signal:
    ///
    ///     delta:a | ABORTED | delta:b | done:{"truncated":false,"dropped":false}
    ///
    /// The ports stop after `delta:a`. This is DOCUMENTED, not fixed, in both
    /// READMEs: production `cancel()` always races a real transport that aborts
    /// the request (RN's fetch rejects, taking the silent catch path), and the
    /// controller's `stale()` check is the guard both runtimes actually rely
    /// on. This test pins the port behavior so the divergence cannot drift.
    @Test func cancelSuppressesLaterHandlersUnlikeRNSuccessPath() async {
        let http = ScriptedHTTP()
        await http.enqueue(.sse([sseContent("a"), sseContent("b"), sseFinish("stop"), sseDone]))
        let token = StreamCancelToken()
        let recorder = StreamRecorder()
        var seen: [String] = []
        let handlers = StreamHandlers(
            onDelta: { d in
                seen.append("delta:" + d)
                if d == "a" { token.cancel() }
            },
            onDone: { _ in seen.append("done") },
            onError: { e in seen.append("error:" + jsErrorMessage(e)) }
        )
        _ = recorder
        let client = makeStreamClient(http: http)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "q")],
            handlers: handlers,
            token: token
        )
        // RN would be ["delta:a", "delta:b", "done"].
        #expect(seen == ["delta:a"], "cancel must suppress every later handler")

        // PROBE the path the guard does NOT take: without a cancel, the same
        // script delivers everything, so the guard is not simply swallowing.
        let http2 = ScriptedHTTP()
        await http2.enqueue(.sse([sseContent("a"), sseContent("b"), sseFinish("stop"), sseDone]))
        var seen2: [String] = []
        let handlers2 = StreamHandlers(
            onDelta: { d in seen2.append("delta:" + d) },
            onDone: { _ in seen2.append("done") },
            onError: { e in seen2.append("error:" + jsErrorMessage(e)) }
        )
        let client2 = makeStreamClient(http: http2)
        await client2.streamScreen(
            messages: [ChatMessage(role: .user, content: "q")],
            handlers: handlers2,
            token: StreamCancelToken()
        )
        #expect(seen2 == ["delta:a", "delta:b", "done"])
    }
}

/// Minimal tool seam: echoes the query so tool rounds can complete.
struct EchoTool: ToolExecuting, Sendable {
    var available: Bool { true }
    var promptSection: String { "" }
    var toolDefs: JSONValue { .array([]) }
    func execute(name: String, args: [String: JSONValue]) async -> String {
        "results for \(jsStringCoerce(args["query"]))"
    }
}
