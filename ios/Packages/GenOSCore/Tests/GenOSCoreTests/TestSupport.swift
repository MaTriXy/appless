import Foundation
import Testing
@testable import GenOSCore

// MARK: - Manual clock

@MainActor
final class ManualClock: GenOSClock {
    private(set) var nowMs: Double = 0
    private var nextToken = 0
    private var scheduled: [(id: Int, at: Double, work: @MainActor () -> Void)] = []

    var now: Double { nowMs }

    final class Token: GenOSCancellable {
        let id: Int
        weak var clock: ManualClock?
        init(id: Int, clock: ManualClock) {
            self.id = id
            self.clock = clock
        }
        func cancel() { clock?.cancelToken(id) }
    }

    @discardableResult
    func schedule(afterMs: Double, _ work: @escaping @MainActor () -> Void) -> GenOSCancellable {
        nextToken += 1
        let id = nextToken
        scheduled.append((id: id, at: nowMs + afterMs, work: work))
        return Token(id: id, clock: self)
    }

    func cancelToken(_ id: Int) {
        scheduled.removeAll { $0.id == id }
    }

    /// Advance time, firing due callbacks in schedule order.
    func advance(by ms: Double) {
        let target = nowMs + ms
        while true {
            guard let next = scheduled.filter({ $0.at <= target }).min(by: { $0.at < $1.at }) else { break }
            scheduled.removeAll { $0.id == next.id }
            nowMs = max(nowMs, next.at)
            next.work()
        }
        nowMs = target
    }

    var pendingCount: Int { scheduled.count }
}

// MARK: - In-memory secure store with gated reads

actor GatedStorage {
    var values: [String: String] = [:]
    var readWaiters: [CheckedContinuation<Void, Never>] = []
    var gated = false
    var writeWaiters: [CheckedContinuation<Void, Never>] = []
    var writesGated = false
    var writeObservers: [@Sendable (String) -> Void] = []

    func setGated(_ g: Bool) { gated = g }
    func setWritesGated(_ g: Bool) { writesGated = g }
    func addWriteObserver(_ observe: @escaping @Sendable (String) -> Void) {
        writeObservers.append(observe)
    }
    func set(_ key: String, _ value: String?) {
        if let value { values[key] = value } else { values.removeValue(forKey: key) }
    }
    /// A write-path set: commits the value, then notifies write observers.
    func commitWrite(_ key: String, _ value: String?) {
        set(key, value)
        for observe in writeObservers { observe(key) }
    }
    func get(_ key: String) -> String? { values[key] }

    func waitIfGated() async {
        guard gated else { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }

    func releaseReads() {
        gated = false
        let waiters = readWaiters
        readWaiters = []
        for w in waiters { w.resume() }
    }

    func waitIfWritesGated() async {
        guard writesGated else { return }
        await withCheckedContinuation { writeWaiters.append($0) }
    }

    func releaseWrites() {
        writesGated = false
        let waiters = writeWaiters
        writeWaiters = []
        for w in waiters { w.resume() }
    }
}

/// SecureStore test double. `gate()` blocks reads until `releaseReads()` so
/// tests can interleave user input with hydration; `gateWrites()` blocks
/// writes until `releaseWrites()` to simulate a hung keychain write.
struct MemorySecureStore: SecureStore {
    let storage = GatedStorage()

    func seed(_ key: String, _ value: String) async {
        await storage.set(key, value)
    }

    func gate() async { await storage.setGated(true) }
    func releaseReads() async { await storage.releaseReads() }
    func gateWrites() async { await storage.setWritesGated(true) }
    func releaseWrites() async { await storage.releaseWrites() }

    /// Write-observation seam: an AsyncStream that yields the key of each
    /// COMMITTED write. The stream buffers, so a fire-and-forget write that
    /// lands before the test's first `next()` is never lost - awaiting it is
    /// a deterministic replacement for polling on detached persists.
    func committedWrites() async -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        await storage.addWriteObserver { continuation.yield($0) }
        return stream
    }

    func read(_ key: String) async throws -> String? {
        await storage.waitIfGated()
        return await storage.get(key)
    }

    func write(_ key: String, value: String?) async throws {
        await storage.waitIfWritesGated()
        await storage.commitWrite(key, value)
    }

    func stored(_ key: String) async -> String? {
        await storage.get(key)
    }
}

// MARK: - Scripted HTTP streaming

/// One scripted streaming response: a status plus SSE body byte chunks
/// delivered exactly as scripted (chunk boundaries preserved).
struct ScriptedResponse: Sendable {
    var status: Int = 200
    var chunks: [Data] = []
    /// Error thrown from the byte stream after the chunks (network failure).
    var streamErrorMessage: String? = nil
    /// Non-stream body for error statuses (res.text()).
    var errorBody: String = ""

    init(status: Int = 200, chunks: [Data] = [], streamErrorMessage: String? = nil, errorBody: String = "") {
        self.status = status
        self.chunks = chunks
        self.streamErrorMessage = streamErrorMessage
        self.errorBody = errorBody
    }

    static func sse(_ lines: [String], status: Int = 200) -> ScriptedResponse {
        ScriptedResponse(status: status, chunks: lines.map { Data(($0).utf8) })
    }
}

actor ScriptedHTTPState {
    var responses: [ScriptedResponse] = []
    var requests: [HTTPRequest] = []
    var chunksPulled = 0

    func push(_ r: ScriptedResponse) { responses.append(r) }
    func next(_ request: HTTPRequest) -> ScriptedResponse? {
        requests.append(request)
        guard !responses.isEmpty else { return nil }
        return responses.removeFirst()
    }
    func allRequests() -> [HTTPRequest] { requests }
    func recordPull() { chunksPulled += 1 }
    func pulled() -> Int { chunksPulled }
}

/// Pull-based chunk source: one chunk is handed out per consumer demand, and
/// Task cancellation is honored between chunks (the HTTPStreaming contract),
/// so tests can assert a cancelled stream loop stops pulling.
actor ScriptedChunkQueue {
    private var remaining: [Data]
    private let trailingErrorMessage: String?
    private let state: ScriptedHTTPState

    init(chunks: [Data], trailingErrorMessage: String?, state: ScriptedHTTPState) {
        remaining = chunks
        self.trailingErrorMessage = trailingErrorMessage
        self.state = state
    }

    func next() async throws -> Data? {
        try Task.checkCancellation()
        guard !remaining.isEmpty else {
            if let trailingErrorMessage { throw StreamError(trailingErrorMessage) }
            return nil
        }
        await state.recordPull()
        return remaining.removeFirst()
    }
}

struct ScriptedHTTP: HTTPStreaming, HTTPFetching {
    let state = ScriptedHTTPState()

    func enqueue(_ r: ScriptedResponse) async { await state.push(r) }

    func requests() async -> [HTTPRequest] { await state.allRequests() }

    /// Total SSE body chunks the consumer has pulled across all streams.
    func chunksPulled() async -> Int { await state.pulled() }

    /// Parsed JSON bodies of every request seen, oldest first.
    func requestBodies() async -> [JSONValue] {
        await state.allRequests().compactMap { req in
            req.body.flatMap { JSONValue.parse($0) }
        }
    }

    func stream(_ request: HTTPRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<Data, Error>) {
        guard let scripted = await state.next(request) else {
            throw StreamError("no scripted response")
        }
        let head = HTTPResponseHead(status: scripted.status)
        // For error statuses the RN reference reads the response body via
        // res.text(); surface errorBody through the byte stream so the
        // client's drain-and-decode path sees it.
        var chunks = scripted.chunks
        if !head.ok, chunks.isEmpty, !scripted.errorBody.isEmpty {
            chunks = [Data(scripted.errorBody.utf8)]
        }
        let queue = ScriptedChunkQueue(
            chunks: chunks,
            trailingErrorMessage: scripted.streamErrorMessage,
            state: state
        )
        let stream = AsyncThrowingStream<Data, Error>(unfolding: { try await queue.next() })
        return (head, stream)
    }

    func fetch(_ request: HTTPRequest) async throws -> (HTTPResponseHead, Data) {
        guard let scripted = await state.next(request) else {
            throw StreamError("no scripted response")
        }
        var body = Data()
        for c in scripted.chunks { body.append(c) }
        if body.isEmpty { body = Data(scripted.errorBody.utf8) }
        return (HTTPResponseHead(status: scripted.status), body)
    }
}

// MARK: - Fake screen streamer (controller tests)

/// Records every stream start; the test drives the handlers manually.
@MainActor
final class FakeStreamer: ScreenStreaming {
    struct Started {
        let messages: [ChatMessage]
        let handlers: StreamHandlers
        let token: StreamCancelToken
    }

    private(set) var started: [Started] = []

    func stream(messages: [ChatMessage], handlers: StreamHandlers, token: StreamCancelToken) {
        started.append(Started(messages: messages, handlers: handlers, token: token))
    }

    var last: Started? { started.last }
    var count: Int { started.count }
}

/// A ScreenStreaming impl that fires its handlers SYNCHRONOUSLY inside
/// stream() - regression double for the RN inflight-before-stream ordering
/// (a synchronous delta must not be dropped as stale).
@MainActor
final class SyncFiringStreamer: ScreenStreaming {
    var deltas: [String] = ["sync delta"]
    var finish = true

    func stream(messages: [ChatMessage], handlers: StreamHandlers, token: StreamCancelToken) {
        for d in deltas { handlers.onDelta(d) }
        if finish { handlers.onDone(StreamEndInfo(truncated: false, dropped: false)) }
    }
}

// MARK: - SSE payload builders

func sseContent(_ text: String) -> String {
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "data: {\"choices\":[{\"delta\":{\"content\":\"\(escaped)\"}}]}\n"
}

func sseFinish(_ reason: String) -> String {
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"\(reason)\"}]}\n"
}

let sseDone = "data: [DONE]\n"

/// Whole-call style tool call chunk (Cerebras): id+name+full arguments at once.
func sseWholeToolCall(index: Int, id: String, name: String, arguments: String) -> String {
    let escapedArgs = arguments
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":\(index),\"id\":\"\(id)\",\"function\":{\"name\":\"\(name)\",\"arguments\":\"\(escapedArgs)\"}}]}}]}\n"
}

/// Split-arguments style fragment (OpenAI): only an arguments fragment.
func sseArgsFragment(index: Int, fragment: String) -> String {
    let escaped = fragment
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":\(index),\"function\":{\"arguments\":\"\(escaped)\"}}]}}]}\n"
}

// MARK: - Stream test harness

/// Collected callback activity from one streamScreen run.
@MainActor
final class StreamRecorder {
    var deltas: [String] = []
    var doneInfos: [StreamEndInfo] = []
    var errors: [String] = []
    var toolRounds: [[ToolRoundCall]] = []
    var toolDecision: ToolRoundDecision = .proceed

    func handlers() -> StreamHandlers {
        StreamHandlers(
            onDelta: { [weak self] d in self?.deltas.append(d) },
            onDone: { [weak self] i in self?.doneInfos.append(i) },
            onError: { [weak self] e in
                self?.errors.append((e as? StreamError)?.message ?? String(describing: e))
            },
            onToolRound: { [weak self] calls in
                guard let self else { return .abort }
                self.toolRounds.append(calls)
                return self.toolDecision
            }
        )
    }

    var content: String { deltas.joined() }
}

/// A always-available fake tool executor with scripted outputs.
struct FakeTool: ToolExecuting, Sendable {
    var availableFlag: Bool = true
    var output: @Sendable (String, [String: JSONValue]) -> String = { name, args in
        "TOOL(\(name)):\(args["query"]?.stringValue ?? "")"
    }

    var available: Bool { availableFlag }
    var promptSection: String { "\n\n## Tools available" }
    var toolDefs: JSONValue {
        .array([.object([
            "type": .string("function"),
            "function": .object([
                "name": .string("web_search"),
                "description": .string("Search the live web."),
                "parameters": .object([
                    "type": .string("object"),
                    "properties": .object(["query": .object(["type": .string("string")])]),
                    "required": .array([.string("query")]),
                ]),
            ]),
        ])])
    }

    func execute(name: String, args: [String: JSONValue]) async -> String {
        output(name, args)
    }
}

@MainActor
func makeKeyStore(envKey: String? = "test-key", store: MemorySecureStore = MemorySecureStore()) -> KeyStore {
    KeyStore(envKey: envKey, store: store)
}

@MainActor
func makeStreamClient(
    http: ScriptedHTTP,
    keyStore: KeyStore? = nil,
    tools: ToolExecuting? = nil,
    systemPrompt: String = "SYSTEM",
    today: String = "Friday, July 25, 2026"
) -> StreamClient {
    StreamClient(
        http: http,
        keyStore: keyStore ?? makeKeyStore(),
        config: StreamConfig(systemPrompt: systemPrompt, todayString: { today }),
        tools: tools
    )
}

// MARK: - Controller harness

@MainActor
struct ControllerHarness {
    let clock = ManualClock()
    let streamer = FakeStreamer()
    let store: ScreenStore
    let controller: GenOSController

    init(apps: [AppDef] = []) {
        store = ScreenStore(clock: clock)
        controller = GenOSController(store: store, streamer: streamer, clock: clock, apps: apps)
    }

    /// Finish the most recent stream with plain content.
    func finishLast(content: String, truncated: Bool = false) {
        guard let s = streamer.last else { return }
        s.handlers.onDelta(content)
        s.handlers.onDone(StreamEndInfo(truncated: truncated, dropped: false))
    }
}

let sampleApp = AppDef(
    id: "weather",
    name: "Weather",
    emoji: "⛅",
    tileStart: "#5ac8fa",
    tileEnd: "#007aff",
    request: "Open the \"Weather\" app home screen."
)
