import Foundation
import Testing
@testable import GenOSCore

// src/genos/stream.ts tool-calling loop.
@MainActor
@Suite struct ToolLoopTests {
    @Test func wholeCallStyleRoundTripsThroughToolLoop() async throws {
        let http = ScriptedHTTP()
        // Round 0: the model asks for one whole tool call per chunk (Cerebras style).
        await http.enqueue(.sse([
            sseWholeToolCall(index: 0, id: "call_1", name: "web_search", arguments: "{\"query\":\"goa weather\"}"),
            sseFinish("tool_calls"),
            sseDone,
        ]))
        // Round 1: the screen itself.
        await http.enqueue(.sse([sseContent("root = Card()"), sseFinish("stop"), sseDone]))

        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http, tools: FakeTool())
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "weather in goa")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )

        #expect(recorder.toolRounds == [[ToolRoundCall(name: "web_search", args: ["query": .string("goa weather")])]])
        #expect(recorder.content == "root = Card()")
        #expect(recorder.doneInfos.count == 1)

        // Second request replays the assistant tool_calls message + tool output.
        let bodies = await http.requestBodies()
        try #require(bodies.count == 2)
        let msgs = bodies[1]["messages"]?.arrayValue ?? []
        let assistant = msgs.first { $0["role"]?.stringValue == "assistant" }
        // No content streamed before the tool round → content null.
        #expect(assistant?["content"] == .some(.null))
        #expect(assistant?["tool_calls"]?[0]?["id"]?.stringValue == "call_1")
        #expect(assistant?["tool_calls"]?[0]?["function"]?["name"]?.stringValue == "web_search")
        let toolMsg = msgs.first { $0["role"]?.stringValue == "tool" }
        #expect(toolMsg?["tool_call_id"]?.stringValue == "call_1")
        #expect(toolMsg?["content"]?.stringValue == "TOOL(web_search):goa weather")

        // Byte-pin the replayed message ORDER, which a re-parse cannot see.
        // RN (stream.ts) pushes { role, content, tool_calls } for the assistant
        // and { role, tool_call_id, content } for the tool result; the wire
        // bytes must match that, not a single canonical order.
        let secondBody = try #require((await http.requests())[1].body)
        let raw = try #require(String(data: secondBody, encoding: .utf8))
        #expect(raw.contains(#"{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","#))
        #expect(raw.contains(#"{"role":"tool","tool_call_id":"call_1","content":"TOOL(web_search):goa weather"}"#))
    }

    @Test func splitArgumentsFragmentsAccumulateByIndex() async {
        let http = ScriptedHTTP()
        // OpenAI style: id+name first, then argument fragments.
        await http.enqueue(.sse([
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_a\",\"function\":{\"name\":\"web_search\"}}]}}]}\n",
            sseArgsFragment(index: 0, fragment: "{\"que"),
            sseArgsFragment(index: 0, fragment: "ry\":\"split"),
            sseArgsFragment(index: 0, fragment: " args\"}"),
            sseFinish("tool_calls"),
            sseDone,
        ]))
        await http.enqueue(.sse([sseContent("done"), sseDone]))

        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http, tools: FakeTool())
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "q")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.toolRounds == [[ToolRoundCall(name: "web_search", args: ["query": .string("split args")])]])
    }

    @Test func multipleCallsSortedByIndexEachGetToolMessages() async throws {
        let http = ScriptedHTTP()
        // Index 1 arrives before index 0; results must come back sorted.
        await http.enqueue(.sse([
            sseWholeToolCall(index: 1, id: "call_b", name: "web_search", arguments: "{\"query\":\"second\"}"),
            sseWholeToolCall(index: 0, id: "call_a", name: "web_search", arguments: "{\"query\":\"first\"}"),
            sseFinish("tool_calls"),
            sseDone,
        ]))
        await http.enqueue(.sse([sseContent("done"), sseDone]))

        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http, tools: FakeTool())
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "q")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.toolRounds == [[
            ToolRoundCall(name: "web_search", args: ["query": .string("first")]),
            ToolRoundCall(name: "web_search", args: ["query": .string("second")]),
        ]])

        let bodies = await http.requestBodies()
        try #require(bodies.count == 2)
        let msgs = bodies[1]["messages"]?.arrayValue ?? []
        let toolMsgs = msgs.filter { $0["role"]?.stringValue == "tool" }
        #expect(toolMsgs.map { $0["tool_call_id"]?.stringValue } == ["call_a", "call_b"])
        #expect(toolMsgs.map { $0["content"]?.stringValue } == ["TOOL(web_search):first", "TOOL(web_search):second"])
    }

    @Test func malformedArgumentsBecomeEmptyObject() async {
        let http = ScriptedHTTP()
        await http.enqueue(.sse([
            sseWholeToolCall(index: 0, id: "call_1", name: "web_search", arguments: "{oops"),
            sseFinish("tool_calls"),
            sseDone,
        ]))
        await http.enqueue(.sse([sseContent("done"), sseDone]))

        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http, tools: FakeTool())
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "q")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.toolRounds == [[ToolRoundCall(name: "web_search", args: [:])]])
    }

    @Test func abortDecisionThrowsNeedsLiveData() async {
        let http = ScriptedHTTP()
        await http.enqueue(.sse([
            sseWholeToolCall(index: 0, id: "call_1", name: "web_search", arguments: "{\"query\":\"x\"}"),
            sseFinish("tool_calls"),
            sseDone,
        ]))
        let recorder = StreamRecorder()
        recorder.toolDecision = .abort
        let client = makeStreamClient(http: http, tools: FakeTool())
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "q")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.errors == [GenOSConstants.needsLiveData])
        #expect(recorder.errors == ["needs live data"])
        #expect(recorder.doneInfos.isEmpty)
        // The refused round never executed - only one HTTP request went out.
        #expect((await http.requests()).count == 1)
    }

    @Test func maxToolRoundsWithholdsToolsToForceAScreen() async throws {
        let http = ScriptedHTTP()
        // Rounds 0,1,2 all finish in tool_calls; round 3 must be sent WITHOUT
        // tools and streams the screen.
        for i in 0..<3 {
            await http.enqueue(.sse([
                sseWholeToolCall(index: 0, id: "call_\(i)", name: "web_search", arguments: "{\"query\":\"r\(i)\"}"),
                sseFinish("tool_calls"),
                sseDone,
            ]))
        }
        await http.enqueue(.sse([sseContent("forced screen"), sseDone]))

        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http, tools: FakeTool())
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "q")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )

        #expect(recorder.toolRounds.count == 3)
        #expect(recorder.content == "forced screen")
        let bodies = await http.requestBodies()
        try #require(bodies.count == 4)
        #expect(bodies[0]["tools"] != nil)
        #expect(bodies[1]["tools"] != nil)
        #expect(bodies[2]["tools"] != nil)
        // Past the round budget: no tools key at all.
        #expect(bodies[3]["tools"] == nil)
    }

    @Test func toolsUnavailableNeverOffersTools() async {
        let http = ScriptedHTTP()
        await http.enqueue(.sse([sseContent("x"), sseDone]))
        let recorder = StreamRecorder()
        var tool = FakeTool()
        tool.availableFlag = false
        let client = makeStreamClient(http: http, tools: tool)
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "q")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        let body = (await http.requestBodies()).first
        #expect(body?["tools"] == nil)
    }

    @Test func contentBeforeToolCallsIsForwardedAndReplayedAsAssistantContent() async throws {
        let http = ScriptedHTTP()
        await http.enqueue(.sse([
            sseContent("thinking"),
            sseWholeToolCall(index: 0, id: "call_1", name: "web_search", arguments: "{\"query\":\"x\"}"),
            sseFinish("tool_calls"),
            sseDone,
        ]))
        await http.enqueue(.sse([sseContent(" answer"), sseDone]))

        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http, tools: FakeTool())
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "q")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        #expect(recorder.deltas.first == "thinking")
        let bodies = await http.requestBodies()
        try #require(bodies.count == 2)
        let msgs = bodies[1]["messages"]?.arrayValue ?? []
        let assistant = msgs.first { $0["role"]?.stringValue == "assistant" }
        #expect(assistant?["content"]?.stringValue == "thinking")
    }

    @Test func toolCallsFinishReasonWithZeroCallsIsContentFinish() async {
        let http = ScriptedHTTP()
        await http.enqueue(.sse([sseContent("screen"), sseFinish("tool_calls"), sseDone]))
        let recorder = StreamRecorder()
        let client = makeStreamClient(http: http, tools: FakeTool())
        await client.streamScreen(
            messages: [ChatMessage(role: .user, content: "q")],
            handlers: recorder.handlers(),
            token: StreamCancelToken()
        )
        // finish_reason tool_calls but no accumulated calls → treated as content.
        #expect(recorder.toolRounds.isEmpty)
        #expect(recorder.doneInfos.count == 1)
    }

    @Test func systemPromptIncludesToolsSectionOnlyWhenAvailable() {
        let withTools = makeStreamClient(http: ScriptedHTTP(), tools: FakeTool(), systemPrompt: "BASE", today: "Monday, July 27, 2026")
        #expect(withTools.systemPrompt() == "BASE\n\n## Tools available\n\nToday is Monday, July 27, 2026.")

        var off = FakeTool()
        off.availableFlag = false
        let withoutTools = makeStreamClient(http: ScriptedHTTP(), tools: off, systemPrompt: "BASE", today: "Monday, July 27, 2026")
        #expect(withoutTools.systemPrompt() == "BASE\n\nToday is Monday, July 27, 2026.")
    }
}
