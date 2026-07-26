import Foundation
import Testing
@testable import GenOSCore

// src/genos/stream.ts streamRound/streamScreen - SSE mechanics.
@MainActor
@Suite struct StreamSSETests {
    @Test func contentDeltasForwardedAndDoneCleanly() async {
        let http = ScriptedHTTP()
        await http.enqueue(.sse([
            sseContent("root = "),
            sseContent("Card()"),
            sseFinish("stop"),
            sseDone,
        ]))
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.deltas == ["root = ", "Card()"])
        #expect(recorder.doneInfos == [StreamEndInfo(truncated: false, dropped: false)])
        #expect(recorder.errors.isEmpty)
    }

    /// `tool_calls[].index` is PROVIDER-CONTROLLED, and Swift's
    /// `Int(_: Double)` initializer TRAPS - it does not clamp - for magnitudes
    /// >= 2^63 and for +/-Infinity:
    ///
    ///     $ swift -e 'print(Int(1e300))'
    ///     Fatal error: Double value cannot be converted to Int because the
    ///     result would be greater than Int.max
    ///
    /// so a single hostile SSE chunk used to abort the whole process. Note
    /// `1e999` is not a typo: `JSON.parse` yields `Infinity` for it, which
    /// traps on the same path.
    ///
    /// RN keys a JS `Map` by the raw Number and simply carries on, so the
    /// stream must survive. Every other tool-call test in this file uses the
    /// literal index `0`, which is why this went unnoticed.
    @Test func hostileToolCallIndicesDoNotTrapTheProcess() async {
        for index in ["1e300", "1e999", "-1e300", "3.7", "-0"] {
            let http = ScriptedHTTP()
            await http.enqueue(.sse([
                "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":\(index),"
                    + "\"id\":\"call_1\",\"function\":{\"name\":\"web_search\","
                    + "\"arguments\":\"{}\"}}]}}]}\n",
                sseFinish("tool_calls"),
                sseDone,
            ]))
            await http.enqueue(.sse([sseContent("second round"), sseFinish("stop"), sseDone]))

            let recorder = StreamRecorder()
            let client = makeStreamClient(http: http)
            await client.streamScreen(
                messages: [ChatMessage(role: .user, content: "q")],
                handlers: recorder.handlers(),
                token: StreamCancelToken()
            )
            // The point is that we REACH this line for every index.
            #expect(recorder.errors.isEmpty, "index \(index) surfaced an error")
            #expect(recorder.deltas == ["second round"], "index \(index)")
        }
    }

    @Test func requestBodyCarriesParityConstants() async throws {
        let http = ScriptedHTTP()
        await http.enqueue(.sse([sseContent("x"), sseDone]))
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http, systemPrompt: "SYS", today: "Friday, July 25, 2026")
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )

        let requests = await http.requests()
        try #require(requests.count == 1)
        #expect(requests[0].url == "https://api.cerebras.ai/v1/chat/completions")
        #expect(requests[0].method == "POST")
        #expect(requests[0].headers["Authorization"] == "Bearer test-key")
        #expect(requests[0].headers["Content-Type"] == "application/json")

        let body = (await http.requestBodies()).first
        #expect(body?["model"]?.stringValue == "gemma-4-31b")
        #expect(body?["temperature"]?.numberValue == 0.8)
        #expect(body?["max_completion_tokens"]?.numberValue == 3072)
        #expect(body?["stream"]?.boolValue == true)
        // No tools configured → no tools key at all.
        #expect(body?["tools"] == nil)
        // System prompt first, then the conversation.
        #expect(body?["messages"]?[0]?["role"]?.stringValue == "system")
        #expect(body?["messages"]?[0]?["content"]?.stringValue == "SYS\n\nToday is Friday, July 25, 2026.")
        #expect(body?["messages"]?[1]?["role"]?.stringValue == "user")
        #expect(body?["messages"]?[1]?["content"]?.stringValue == "hi")

        // Byte-pin the ACTUAL wire bytes, not the re-parsed body: object key
        // order and number formatting are otherwise protected only by
        // coincidence, since a re-parse discards both. RN's JSON.stringify
        // emits keys in INSERTION order (modulo canonical array indices), which
        // is what `JSONObject` reproduces at every depth; this assertion is
        // what would catch a divergence.
        let raw = try #require(requests[0].body)
        #expect(
            raw == Data(#"{"model":"gemma-4-31b","messages":[{"role":"system","content":"SYS\n\nToday is Friday, July 25, 2026."},{"role":"user","content":"hi"}],"stream":true,"temperature":0.8,"max_completion_tokens":3072}"#.utf8)
        )
    }

    /// FINDING 7: the tool-defs subtree used to serialize correctly only
    /// because those names happened to sort the way RN inserts them - the one
    /// flat `keyOrder` hint sorted every key it did not name, so ADDING a key
    /// anywhere would have silently reordered the wire bytes. Per-object
    /// ordering removes the coincidence; this byte-pins it, including a
    /// deliberately reverse-alphabetical extra key inside `function`.
    @Test func toolDefsSubtreeKeepsLiteralOrderIncludingAddedKeys() async throws {
        struct ExtraKeyTool: ToolExecuting, Sendable {
            var available: Bool { true }
            var promptSection: String { "" }
            // "a_added" sorts FIRST and "zzz_added" LAST, so a sorted fallback
            // anywhere in this subtree is visible in the bytes.
            var toolDefs: JSONValue {
                .array([.object([
                    "type": .string("function"),
                    "zzz_added": .string("tail"),
                    "function": .object([
                        "name": .string("web_search"),
                        "a_added": .string("head"),
                        "description": .string("d"),
                    ]),
                ])])
            }
            func execute(name: String, args: [String: JSONValue]) async -> String { "" }
        }

        let http = ScriptedHTTP()
        await http.enqueue(.sse([sseContent("x"), sseDone]))
        let client = makeStreamClient(http: http, tools: ExtraKeyTool(), systemPrompt: "S")
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: StreamRecorder().handlers(),
            token: StreamCancelToken()
        )
        let bodyData = try #require((await http.requests())[0].body)
        let raw = try #require(String(data: bodyData, encoding: .utf8))
        #expect(raw.contains(
            #""tools":[{"type":"function","zzz_added":"tail","function":{"name":"web_search","a_added":"head","description":"d"}}]"#
        ))
        // `tools` is spread in after `messages` and before `stream`, exactly
        // where RN's object literal puts it.
        #expect(raw.contains(#"}],"tools":[{"#))
        #expect(raw.hasSuffix(#"}}],"stream":true,"temperature":0.8,"max_completion_tokens":3072}"#))
    }

    @Test func dataLinesSplitAcrossChunkBoundaries() async {
        let http = ScriptedHTTP()
        let full = sseContent("hello world") + sseFinish("stop") + sseDone
        // Slice the raw SSE text into awkward 7-byte chunks (ASCII-safe here).
        let bytes = Array(full.utf8)
        var chunks: [Data] = []
        var i = 0
        while i < bytes.count {
            let end = min(i + 7, bytes.count)
            chunks.append(Data(bytes[i..<end]))
            i = end
        }
        await http.enqueue(ScriptedResponse(chunks: chunks))
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.content == "hello world")
        #expect(recorder.doneInfos == [StreamEndInfo(truncated: false, dropped: false)])
    }

    @Test func multiByteUtf8SplitAcrossChunks() async {
        let http = ScriptedHTTP()
        let line = sseContent("weather ⛅🌧 done") + sseDone
        let bytes = Array(line.utf8)
        // Split two bytes INTO the 4-byte 🌧 scalar (leading byte 0xF0), so
        // the second chunk starts mid-scalar.
        let emojiStart = bytes.firstIndex(of: 0xF0)!
        let splitAt = emojiStart + 2
        let chunks = [
            Data(bytes[0..<splitAt]),
            Data(bytes[splitAt..<(splitAt + 1)]),
            Data(bytes[(splitAt + 1)...]),
        ]
        await http.enqueue(ScriptedResponse(chunks: chunks))
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.content == "weather ⛅🌧 done")
        #expect(recorder.errors.isEmpty)
    }

    @Test func nonDataLinesAndMalformedPayloadsIgnored() async {
        let http = ScriptedHTTP()
        await http.enqueue(.sse([
            ": comment line\n",
            "event: message\n",
            "data:\n",              // empty payload skipped
            "data: {not json}\n",   // malformed JSON skipped
            sseContent("ok"),
            sseDone,
        ]))
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.content == "ok")
        #expect(recorder.errors.isEmpty)
        #expect(recorder.doneInfos.count == 1)
    }

    @Test func finishReasonLengthSetsTruncated() async {
        let http = ScriptedHTTP()
        await http.enqueue(.sse([sseContent("partial screen"), sseFinish("length"), sseDone]))
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.doneInfos == [StreamEndInfo(truncated: true, dropped: false)])
    }

    @Test func endWithoutDoneOrFinishReasonIsDropped() async {
        let http = ScriptedHTTP()
        await http.enqueue(.sse([sseContent("partial")]))
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.doneInfos == [StreamEndInfo(truncated: false, dropped: true)])
        #expect(recorder.errors.isEmpty)
    }

    @Test func finishReasonWithoutDoneSentinelIsNotDropped() async {
        let http = ScriptedHTTP()
        await http.enqueue(.sse([sseContent("full"), sseFinish("stop")]))
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.doneInfos == [StreamEndInfo(truncated: false, dropped: false)])
    }

    @Test func dropWithNothingArrivedIsAnError() async {
        let http = ScriptedHTTP()
        await http.enqueue(.sse([": nothing\n"]))
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.doneInfos.isEmpty)
        #expect(recorder.errors == ["stream dropped before any content arrived"])
    }

    @Test func inStreamErrorObjectSurfacesAsError() async {
        let http = ScriptedHTTP()
        await http.enqueue(.sse([
            "data: {\"error\":{\"message\":\"model overloaded\"}}\n",
        ]))
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.errors == ["model overloaded"])
        #expect(recorder.doneInfos.isEmpty)
    }

    @Test func falsyErrorChunksAreSkippedLikeRN() async {
        // RN: `if (chunk.error)` is a truthy guard - "", 0, false and null
        // error values are skipped, and the stream continues normally.
        let http = ScriptedHTTP()
        await http.enqueue(.sse([
            "data: {\"error\":\"\"}\n",
            "data: {\"error\":0}\n",
            "data: {\"error\":false}\n",
            "data: {\"error\":null}\n",
            sseContent("ok"),
            sseFinish("stop"),
            sseDone,
        ]))
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.errors.isEmpty)
        #expect(recorder.content == "ok")
        #expect(recorder.doneInfos == [StreamEndInfo(truncated: false, dropped: false)])
    }

    @Test func truthyErrorWithoutMessageFallsBackToStreamError() async {
        // {} is truthy in JS even though it has no message.
        let http = ScriptedHTTP()
        await http.enqueue(.sse(["data: {\"error\":{}}\n"]))
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.errors == ["stream error"])
        #expect(recorder.doneInfos.isEmpty)
    }

    @Test func inStreamErrorStringSurfacesAsError() async {
        let http = ScriptedHTTP()
        await http.enqueue(.sse([
            "data: {\"error\":\"quota exceeded\"}\n",
        ]))
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.errors == ["quota exceeded"])
    }

    @Test func unauthorizedMarksKeyRejected() async {
        let http = ScriptedHTTP()
        await http.enqueue(ScriptedResponse(status: 401, errorBody: "unauthorized"))
        let keyStore = makeKeyStore(envKey: "bad-key")
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http, keyStore: keyStore)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(keyStore.status == .rejected)
        #expect(keyStore.get() == nil)
        #expect(recorder.errors == ["Cerebras rejected the API key - enter a valid key"])
    }

    @Test func forbiddenAlsoMarksKeyRejected() async {
        let http = ScriptedHTTP()
        await http.enqueue(ScriptedResponse(status: 403, errorBody: "forbidden"))
        let keyStore = makeKeyStore(envKey: "bad-key")
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http, keyStore: keyStore)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(keyStore.status == .rejected)
        #expect(recorder.errors.count == 1)
    }

    @Test func httpErrorSurfacesBodyDetail() async {
        let http = ScriptedHTTP()
        await http.enqueue(ScriptedResponse(status: 500, errorBody: "backend exploded"))
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.errors == ["backend exploded"])
    }

    @Test func missingApiKeyErrorsWithoutRequesting() async {
        let http = ScriptedHTTP()
        let store = MemorySecureStore()
        let keyStore = KeyStore(envKey: nil, store: store)
        await keyStore.hydrate()
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http, keyStore: keyStore)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.errors == ["No Cerebras API key set"])
        #expect(await http.requests().isEmpty)
    }

    @Test func whitespaceOnlyKeyErrorsLocallyWithoutRequesting() async {
        // set('  ') stores '' with status present (RN parity), but the falsy
        // key check must throw locally - no request with a blank bearer.
        let http = ScriptedHTTP()
        let keyStore = KeyStore(envKey: nil, store: MemorySecureStore())
        await keyStore.hydrate()
        keyStore.set("   ")
        #expect(keyStore.status == .present)
        #expect(keyStore.get() == "")

        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http, keyStore: keyStore)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.errors == ["No Cerebras API key set"])
        #expect(await http.requests().isEmpty)
    }

    @Test func cancelledTokenSuppressesCallbacks() async {
        let http = ScriptedHTTP()
        await http.enqueue(ScriptedResponse(status: 500, errorBody: "boom"))
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http)
        let token = StreamCancelToken()
        token.cancel()
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: token
        )
        #expect(recorder.errors.isEmpty)
        #expect(recorder.doneInfos.isEmpty)
    }
}

// SSE line splitting must match RN's UTF-16-level buffer.split("\n") +
// line.trim(): CRLF-terminated streams (legal per the SSE spec, produced by
// some proxies) and pathological Unicode at line boundaries.
@MainActor
@Suite struct StreamSSELineEndingTests {
    /// Re-terminate a "...\n" SSE line with "\r\n".
    private func crlf(_ line: String) -> String {
        line.hasSuffix("\n") ? String(line.dropLast()) + "\r\n" : line + "\r\n"
    }

    private func run(_ response: ScriptedResponse) async -> StreamRecorder {
        let http = ScriptedHTTP()
        await http.enqueue(response)
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        return recorder
    }

    @Test func crlfTerminatedStreamDeliversAllDeltasAndCleanDone() async {
        // Regression: Character-level components(separatedBy: "\n") never
        // splits "\r\n" (one grapheme) - the whole stream buffered forever
        // and errored "stream dropped". node: "a\r\nb".split("\n") ===
        // ["a\r","b"]; the scalar split matches, and jsTrim strips the \r.
        let recorder = await run(.sse([
            crlf(sseContent("root = ")),
            crlf(sseContent("Card()")),
            crlf(sseFinish("stop")),
            crlf(sseDone),
        ]))
        #expect(recorder.deltas == ["root = ", "Card()"])
        #expect(recorder.doneInfos == [StreamEndInfo(truncated: false, dropped: false)])
        #expect(recorder.errors.isEmpty)
    }

    @Test func crlfSplitAcrossChunkBoundaryStillParses() async {
        // The \r arrives at the end of one chunk, the \n at the start of the
        // next - the tail-buffer must carry the \r over and still split.
        let line = crlf(sseContent("hello"))
        let bytes = Array(line.utf8)
        let crIndex = bytes.firstIndex(of: 0x0D)!
        let chunks = [
            Data(bytes[0...crIndex]),
            Data(bytes[(crIndex + 1)...]),
            Data(crlf(sseDone).utf8),
        ]
        let recorder = await run(ScriptedResponse(chunks: chunks))
        #expect(recorder.content == "hello")
        #expect(recorder.doneInfos == [StreamEndInfo(truncated: false, dropped: false)])
    }

    @Test func mixedLfAndCrlfLinesAllSplit() async {
        let recorder = await run(.sse([
            sseContent("one"),
            crlf(sseContent("two")),
            sseContent("three"),
            crlf(sseDone),
        ]))
        #expect(recorder.deltas == ["one", "two", "three"])
        #expect(recorder.doneInfos == [StreamEndInfo(truncated: false, dropped: false)])
        #expect(recorder.errors.isEmpty)
    }

    @Test func bomBeforeDataPrefixIsTrimmedLikeJs() async {
        // RN's line.trim() strips U+FEFF before "data:" (JS \s includes it).
        let recorder = await run(.sse([
            "\u{FEFF}" + sseContent("ok"),
            "\u{FEFF}" + sseDone,
        ]))
        #expect(recorder.content == "ok")
        #expect(recorder.doneInfos == [StreamEndInfo(truncated: false, dropped: false)])
    }

    @Test func combiningMarkAtLineStartDoesNotGlueToPreviousNewline() async {
        // "\n" followed by U+0301 is ONE grapheme - a Character-level split
        // would merge the two lines and lose the first delta. JS (and the
        // scalar split) keep them separate. Everything arrives in a SINGLE
        // chunk so the glue hazard actually sits inside one buffer.
        let body = sseContent("one")
            + "\u{301}: stray-mark comment line\n"
            + sseContent("two")
            + sseDone
        let recorder = await run(ScriptedResponse(chunks: [Data(body.utf8)]))
        #expect(recorder.deltas == ["one", "two"])
        #expect(recorder.errors.isEmpty)
    }

    @Test func jsonParseStrictChunksSkippedAndStreamContinues() async {
        // Chunks JSON.parse would throw on (leading-zero number, raw control
        // char in string) are skipped like RN's try/catch-continue, not
        // processed and not fatal.
        //
        // A lone-surrogate escape is NOT in that set: node's JSON.parse
        // ACCEPTS it, so RN forwards the delta and only that scalar degrades
        // to U+FFFD at UTF-8 encoding time. We match that - the chunk is
        // delivered as "\u{FFFD}", not dropped. Dropping it would lose a whole
        // content delta over one bad character.
        let recorder = await run(.sse([
            "data: {\"choices\":[{\"delta\":{\"content\":01}}]}\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"a\tb\"}}]}\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"\\ud800\"}}]}\n",
            sseContent("ok"),
            sseFinish("stop"),
            sseDone,
        ]))
        #expect(recorder.content == "\u{FFFD}ok")
        #expect(recorder.errors.isEmpty)
        #expect(recorder.doneInfos == [StreamEndInfo(truncated: false, dropped: false)])
    }

    /// FINDING 2, the exact audit repro: a lone-surrogate escape inside a
    /// delta used to make `JSONValue.parse` reject the document, so the SSE
    /// layer skipped the ENTIRE chunk and the whole delta vanished - RN
    /// delivered `["a\ud800b", "after"]` where Swift delivered `["after"]`.
    /// Now the delta arrives with only that scalar degraded, which is exactly
    /// what RN's string produces once it is UTF-8-encoded.
    @Test func loneSurrogateDeltaIsDeliveredNotDropped() async {
        let recorder = await run(.sse([
            "data: {\"choices\":[{\"delta\":{\"content\":\"a\\ud800b\"}}]}\n",
            sseContent("after"),
            sseDone,
        ]))
        // node: Buffer.from("a\ud800b").toString() === "a�b"
        #expect(recorder.deltas == ["a\u{FFFD}b", "after"])
        #expect(recorder.errors.isEmpty)

        // The path the fix must NOT break: a SURROGATE PAIR still decodes to
        // the astral scalar, and a genuinely malformed chunk is still skipped.
        let pairs = await run(.sse([
            "data: {\"choices\":[{\"delta\":{\"content\":\"x\\ud83d\\ude00y\"}}]}\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"unterminated}}]}\n",
            sseContent("tail"),
            sseDone,
        ]))
        #expect(pairs.deltas == ["x😀y", "tail"])
        #expect(pairs.errors.isEmpty)
    }

    @Test func httpErrorDetailTruncatedAtUtf16Units() async {
        // RN: detail.slice(0, 500) counts UTF-16 units; slicing through 😀
        // leaves a lone surrogate that UTF-8-encodes to U+FFFD.
        let body = String(repeating: "a", count: 499) + "😀 rest of the error"
        let recorder = await run(ScriptedResponse(status: 500, errorBody: body))
        #expect(recorder.errors == [String(repeating: "a", count: 499) + "\u{FFFD}"])
    }
}

// StreamCancelToken tears down the in-flight work (AbortController parity):
// the SSE drain stops pulling chunks and tool execution cannot trigger the
// next round's request.
@MainActor
@Suite struct StreamCancellationTests {
    /// Records callbacks and cancels its token on the first delta.
    @MainActor
    final class CancelOnFirstDelta {
        var token: StreamCancelToken?
        var deltas: [String] = []
        var doneCount = 0
        var errorCount = 0

        func handlers() -> StreamHandlers {
            StreamHandlers(
                onDelta: { [weak self] d in
                    self?.deltas.append(d)
                    self?.token?.cancel()
                },
                onDone: { [weak self] _ in self?.doneCount += 1 },
                onError: { [weak self] _ in self?.errorCount += 1 }
            )
        }
    }

    @Test func cancelMidStreamStopsConsumingChunks() async {
        let http = ScriptedHTTP()
        await http.enqueue(.sse([
            sseContent("one"),
            sseContent("two"),
            sseContent("three"),
            sseDone,
        ]))
        let client = makeStreamClient(http: http)
        let recorder = CancelOnFirstDelta()
        let token = client.stream(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers()
        )
        recorder.token = token
        await token.join()

        #expect(recorder.deltas == ["one"])
        // Only the first chunk was ever pulled from the byte stream - the
        // drain stopped, it did not run to completion with muted callbacks.
        #expect(await http.chunksPulled() == 1)
        #expect(recorder.doneCount == 0)
        #expect(recorder.errorCount == 0)
        #expect(token.isCancelled)
    }

    /// Tool that records whether the surrounding Task was already cancelled.
    actor ExecLog {
        var sawCancelled: [Bool] = []
        func record(_ cancelled: Bool) { sawCancelled.append(cancelled) }
        func all() -> [Bool] { sawCancelled }
    }

    struct CancelAwareTool: ToolExecuting {
        let log: ExecLog
        var available: Bool { true }
        var promptSection: String { "\n\n## Tools available" }
        var toolDefs: JSONValue { FakeTool().toolDefs }
        func execute(name: String, args: [String: JSONValue]) async -> String {
            await log.record(Task.isCancelled)
            return "output"
        }
    }

    /// Cancels its token inside onToolRound, then proceeds.
    @MainActor
    final class CancelOnToolRound {
        var token: StreamCancelToken?
        var doneCount = 0
        var errorCount = 0
        var toolRounds = 0

        func handlers() -> StreamHandlers {
            StreamHandlers(
                onDelta: { _ in },
                onDone: { [weak self] _ in self?.doneCount += 1 },
                onError: { [weak self] _ in self?.errorCount += 1 },
                onToolRound: { [weak self] _ in
                    self?.toolRounds += 1
                    self?.token?.cancel()
                    return .proceed
                }
            )
        }
    }

    @Test func cancelDuringToolExecutionPreventsNextRoundRequest() async {
        let http = ScriptedHTTP()
        await http.enqueue(.sse([
            sseWholeToolCall(index: 0, id: "call_1", name: "web_search", arguments: "{\"query\":\"x\"}"),
            sseFinish("tool_calls"),
            sseDone,
        ]))
        // A second scripted response exists; it must never be requested.
        await http.enqueue(.sse([sseContent("should never stream"), sseDone]))

        let log = ExecLog()
        let client = makeStreamClient(http: http, tools: CancelAwareTool(log: log))
        let recorder = CancelOnToolRound()
        let token = client.stream(
            messages: [ChatMessage(role: .user, content: "q")],
            handlers: recorder.handlers()
        )
        recorder.token = token
        await token.join()

        #expect(recorder.toolRounds == 1)
        // The tool ran inside the already-cancelled Task (cooperative impls
        // can bail early), and its output was discarded.
        #expect(await log.all() == [true])
        // No second-round HTTP request went out, and no callbacks fired.
        #expect((await http.requests()).count == 1)
        #expect(recorder.doneCount == 0)
        #expect(recorder.errorCount == 0)
    }

    @Test func cancelBeforeAttachCancelsTheTaskImmediately() async {
        let http = ScriptedHTTP()
        await http.enqueue(.sse([sseContent("never"), sseDone]))
        let client = makeStreamClient(http: http)
        let recorder = CancelOnFirstDelta()
        let token = StreamCancelToken()
        token.cancel()
        client.stream(
            messages: [ChatMessage(role: .user, content: "hi")],
            handlers: recorder.handlers(),
            token: token
        )
        await token.join()
        #expect(recorder.deltas.isEmpty)
        #expect(recorder.doneCount == 0)
        #expect(recorder.errorCount == 0)
        // The pre-cancelled task never pulled a single chunk.
        #expect(await http.chunksPulled() == 0)
    }
}

// src/genos/stream.ts systemPrompt() - "Today is ..." date construction.
@Suite struct StreamConfigDefaultsTests {
    @Test func defaultTodayStringMatchesRnEnUsLongDateShape() {
        // stream.ts builds the date with new Date().toLocaleDateString(
        // "en-US", { weekday: "long", year: "numeric", month: "long",
        // day: "numeric" }) - e.g. "Friday, July 25, 2026". The DEFAULT
        // closure (host forgot to inject) must produce that same shape so
        // the prompt never degrades to "Today is ." - asserted structurally,
        // not against a pinned date. The day alternation (1-31, no leading
        // zero) pins toLocaleDateString's day:"numeric" shape - "July 5",
        // never "July 05".
        let today = StreamConfig().todayString()
        let pattern = "\\A(Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday), "
            + "(January|February|March|April|May|June|July|August|September|October|November|December) "
            + "(?:[1-9]|[12][0-9]|3[01]), [0-9]{4}\\z"
        #expect(JSRegex.test(pattern, today), "unexpected default today string: \(today)")
        // The named default closure is the same shape (no midnight-race
        // equality pin between two separate now() reads).
        #expect(JSRegex.test(pattern, StreamConfig.defaultTodayString()))
    }
}

// FULL WHATWG parity, fuzz-verified. UTF8StreamDecoder ports the Encoding
// Standard's utf-8 decoder state machine verbatim - the algorithm
// TextDecoder("utf-8", {stream:true}) runs - so emission timing AND totals
// match for every input by construction, not per patched case. This suite
// pins: (a) invalid-lead timing, (b) valid incomplete tails, (c) the
// out-of-range CONTINUATION counterexamples that defeated the previous
// tail-scan decoder (it held them back, and could swallow a trailing valid
// byte at stream end), and (d) a 220-case seeded fuzz differential whose
// expectations come from real node TextDecoder
// (spec/fixtures/generator/probes/gen-utf8-fuzz.mjs; re-running it must
// reproduce Resources/utf8-fuzz-corpus.json byte-identically).
@Suite struct UTF8StreamDecoderTests {
    private func emissions(_ chunks: [[UInt8]]) -> [String] {
        var decoder = UTF8StreamDecoder()
        return chunks.map { decoder.decode(Data($0)) }
    }

    @Test func invalidLeadsEmitReplacementImmediatelyLikeTextDecoder() {
        // Invalid lead 0xF5 mid-chunk.
        #expect(emissions([[0x61, 0x62, 0xF5, 0x63, 0x64]]) == ["ab\u{FFFD}cd"])
        // Invalid lead 0xF5 at chunk end - previously misclassified as a
        // 4-byte lead and held back until the next chunk.
        #expect(emissions([[0x61, 0x62, 0xF5], [0x63, 0x64]]) == ["ab\u{FFFD}", "cd"])
        // 0xFF alone in a chunk.
        #expect(emissions([[0xFF], [0x78]]) == ["\u{FFFD}", "x"])
        // Overlong lead 0xC0 at chunk end.
        #expect(emissions([[0x61, 0xC0], [0x62]]) == ["a\u{FFFD}", "b"])
        // Stray continuation byte at chunk end.
        #expect(emissions([[0x61, 0x80], [0x62]]) == ["a\u{FFFD}", "b"])
        // Invalid lead then continuations split across chunks: one U+FFFD
        // per bogus byte, each emitted in the chunk it arrived in.
        #expect(emissions([[0x61, 0xF5, 0x8F], [0xBF, 0xBF, 0x62]])
            == ["a\u{FFFD}\u{FFFD}", "\u{FFFD}\u{FFFD}b"])
    }

    @Test func validIncompleteTailsStillHeldBack() {
        // € (E2 82 AC) split mid-scalar: held, then completed.
        #expect(emissions([[0x61, 0xE2, 0x82], [0xAC]]) == ["a", "\u{20AC}"])
        // 0xF4 is the MAX valid 4-byte lead - still held to completion.
        #expect(emissions([[0xF4, 0x8F], [0xBF, 0xBF]]) == ["", "\u{10FFFF}"])
    }

    /// Out-of-range CONTINUATION bytes: a valid lead whose second byte falls
    /// outside the spec's boundary window (E0 needs A0-BF, ED needs 80-9F,
    /// F0 needs 90-BF, F4 needs 80-8F). The spec emits U+FFFD for the aborted
    /// sequence and RE-PROCESSES the offending byte as a fresh lead, so both
    /// land in the arriving chunk. The previous tail-scan decoder validated
    /// only the lead and held the pair back - and for F4 90 / F0 80 it also
    /// swallowed the following valid byte, losing it entirely at stream end.
    @Test func outOfRangeContinuationsEmitInArrivingChunk() {
        #expect(emissions([[0x61, 0xE0, 0x80], [0x62]]) == ["a\u{FFFD}\u{FFFD}", "b"])
        #expect(emissions([[0x61, 0xED, 0xA0], [0x62]]) == ["a\u{FFFD}\u{FFFD}", "b"])
        #expect(emissions([[0x61, 0xF4, 0x90], [0x62]]) == ["a\u{FFFD}\u{FFFD}", "b"])
        #expect(emissions([[0x61, 0xF0, 0x80], [0x62]]) == ["a\u{FFFD}\u{FFFD}", "b"])
        // Nothing is dropped when the stream ends right after the bad pair.
        #expect(emissions([[0x61, 0xF4, 0x90, 0x62]]) == ["a\u{FFFD}\u{FFFD}b"])
    }

    // MARK: - Seeded fuzz differential vs node TextDecoder

    private struct FuzzCorpus: Decodable {
        struct Case: Decodable {
            let chunks: [[UInt8]]
            let perChunk: [String]
        }
        let seed: Int
        let cases: [Case]
    }

    @Test func fuzzCorpusMatchesTextDecoderPerChunk() throws {
        let url = try #require(
            Bundle.module.url(forResource: "utf8-fuzz-corpus", withExtension: "json"),
            "utf8-fuzz-corpus.json missing - regenerate with probes/gen-utf8-fuzz.mjs"
        )
        let corpus = try JSONDecoder().decode(FuzzCorpus.self, from: Data(contentsOf: url))
        #expect(corpus.cases.count >= 200)

        // Compare SCALAR-exactly, not with String ==: Swift string equality
        // applies canonical equivalence and could in principle absorb a
        // scalar-level divergence (e.g. a U+FFFD emitted where a combining
        // mark belongs) that TextDecoder would have distinguished.
        func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }
        var mismatches: [String] = []
        for (index, testCase) in corpus.cases.enumerated() {
            let actual = emissions(testCase.chunks)
            if actual.map(scalars) != testCase.perChunk.map(scalars) {
                mismatches.append(
                    "case \(index): chunks=\(testCase.chunks) expected=\(testCase.perChunk.map(scalars)) actual=\(actual.map(scalars))"
                )
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) fuzz divergences:\n\(mismatches.prefix(5).joined(separator: "\n"))")
    }
}
