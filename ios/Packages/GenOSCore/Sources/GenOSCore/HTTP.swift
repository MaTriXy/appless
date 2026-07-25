import Foundation

public struct HTTPRequest: Sendable, Equatable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(url: String, method: String = "POST", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponseHead: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]

    public init(status: Int, headers: [String: String] = [:]) {
        self.status = status
        self.headers = headers
    }

    public var ok: Bool { (200..<300).contains(status) }
}

/// Streaming networking seam: request → response head + raw byte chunks.
/// Tests inject scripted SSE byte streams; Phase 3 wires URLSession.bytes.
///
/// Cancellation contract: the stream loop consumes the byte stream inside a
/// Task that StreamCancelToken.cancel() cancels. Implementations must honor
/// Task cancellation - URLSession.bytes does natively; scripted test
/// implementations should call `Task.checkCancellation()` between chunks so
/// a cancelled consumer stops pulling immediately.
public protocol HTTPStreaming: Sendable {
    func stream(_ request: HTTPRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<Data, Error>)
}

/// Non-streaming fetch seam (Exa search, Unsplash, telemetry).
public protocol HTTPFetching: Sendable {
    func fetch(_ request: HTTPRequest) async throws -> (HTTPResponseHead, Data)
}
