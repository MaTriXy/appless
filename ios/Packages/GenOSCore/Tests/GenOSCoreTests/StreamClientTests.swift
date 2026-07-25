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
