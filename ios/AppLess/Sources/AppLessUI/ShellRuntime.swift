//
//  ShellRuntime.swift
//  AppLessUI
//
//  The platform seams `GenOSCore` deliberately left open, filled in for Apple
//  platforms: a monotonic clock, Keychain persistence for the BYOK key, and
//  URLSession for streaming + fetching. Plus the small factory that assembles
//  a live ``GenOSShellModel`` out of them.
//
//  None of this decides shell BEHAVIOR - it only supplies the four objects
//  (`ScreenStore`, `StreamClient`, `KeyStore`, `GenOSController`) whose logic
//  is already verified in `GenOSCore`.
//

#if canImport(SwiftUI)

import AppLessCore
import Foundation
import GenOSCore
import OpenUILang
import SwiftUI

#if canImport(Security)
    import Security
#endif

// MARK: - Clock

@MainActor
final class TaskCancellable: GenOSCancellable {
    private let task: Task<Void, Never>
    init(_ task: Task<Void, Never>) { self.task = task }
    func cancel() { task.cancel() }
}

/// `GenOSClock` over the monotonic system uptime (the `performance.now()`
/// analog) and structured-concurrency sleeps.
@MainActor
public final class SystemClock: GenOSClock {
    public init() {}

    public var now: Double { ProcessInfo.processInfo.systemUptime * 1000 }

    @discardableResult
    public func schedule(afterMs: Double, _ work: @escaping @MainActor () -> Void)
        -> GenOSCancellable
    {
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, afterMs) * 1_000_000))
            if Task.isCancelled { return }
            work()
        }
        return TaskCancellable(task)
    }
}

// MARK: - Networking

/// Moves a value into a `Task` without demanding a `Sendable` conformance the
/// SDK may not declare. Safe here because the value is used by exactly one
/// task and never touched again by the sender.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// `HTTPStreaming` + `HTTPFetching` over `URLSession`.
///
/// The streaming half yields one `Data` chunk per line, which is exactly the
/// granularity `StreamClient`'s SSE reader consumes, and it inherits
/// `URLSession.bytes`' native cancellation.
public struct URLSessionHTTP: HTTPStreaming, HTTPFetching {
    public init() {}

    public func stream(_ request: HTTPRequest) async throws -> (
        HTTPResponseHead, AsyncThrowingStream<Data, Error>
    ) {
        let (bytes, response) = try await URLSession.shared.bytes(for: Self.urlRequest(request))
        let head = Self.head(from: response)
        // `URLSession.AsyncBytes` carries the underlying task, so it is moved
        // into the draining Task through an explicit box rather than relying
        // on its Sendable conformance.
        let source = UncheckedBox(bytes)
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var buffer = Data()
                    for try await byte in source.value {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        if byte == UInt8(ascii: "\n") {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (head, stream)
    }

    public func fetch(_ request: HTTPRequest) async throws -> (HTTPResponseHead, Data) {
        let (data, response) = try await URLSession.shared.data(for: Self.urlRequest(request))
        return (Self.head(from: response), data)
    }

    private static func urlRequest(_ request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: URL(string: request.url) ?? URL(fileURLWithPath: "/"))
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    private static func head(from response: URLResponse) -> HTTPResponseHead {
        guard let http = response as? HTTPURLResponse else {
            return HTTPResponseHead(status: 0)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let name = key as? String, let text = value as? String { headers[name] = text }
        }
        return HTTPResponseHead(status: http.statusCode, headers: headers)
    }
}

// MARK: - Key persistence

#if canImport(Security)

    /// `SecureStore` backed by the Keychain (the `expo-secure-store` analog).
    public struct KeychainSecureStore: SecureStore {
        public let service: String

        public init(service: String = "com.appless.genos") {
            self.service = service
        }

        private func query(_ key: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
        }

        public func read(_ key: String) async throws -> String? {
            var lookup = query(key)
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(lookup as CFDictionary, &item)
            guard status == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        public func write(_ key: String, value: String?) async throws {
            SecItemDelete(query(key) as CFDictionary)
            guard let value, let data = value.data(using: .utf8) else { return }
            var insert = query(key)
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

#endif

/// In-memory fallback for platforms without Security (and for previews): the
/// key lives for the process only.
public final class EphemeralSecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    public func read(_ key: String) async throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func write(_ key: String, value: String?) async throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }
}

// MARK: - Configuration

/// Everything the runtime needs that is not compiled in: the component
/// contract, the generated system prompt, and the optional BYOK/tool keys.
///
/// The contract and the prompt are deliberately NOT copied into this package -
/// a copy goes stale silently. The host app bundles `spec/contract/genos.schema.json`
/// and `spec/prompt/system-prompt.generated.txt` as resources (or supplies
/// them here directly).
public struct AppLessConfiguration {
    public var schema: LibrarySchema
    public var systemPrompt: String
    /// Build-time key override; nil sends the user to the key gate.
    public var cerebrasKey: String?
    /// Enables the `web_search` tool when present.
    public var exaKey: String?
    public var baseURL: String
    public var model: String

    public init(
        schema: LibrarySchema,
        systemPrompt: String = "",
        cerebrasKey: String? = nil,
        exaKey: String? = nil,
        baseURL: String = GenOSConstants.defaultBaseURL,
        model: String = GenOSConstants.defaultModel
    ) {
        self.schema = schema
        self.systemPrompt = systemPrompt
        self.cerebrasKey = cerebrasKey
        self.exaKey = exaKey
        self.baseURL = baseURL
        self.model = model
    }

    public enum LoadError: Error, CustomStringConvertible {
        case missingContract

        public var description: String {
            switch self {
            case .missingContract:
                return """
                    genos.schema.json is not in the app bundle.

                    Add spec/contract/genos.schema.json (and, for generation, \
                    spec/prompt/system-prompt.generated.txt) to the host app \
                    target's resources.
                    """
            }
        }
    }

    /// Resource names the host app bundles.
    public static let schemaResource = "genos.schema"
    public static let promptResource = "system-prompt.generated"

    /// Read the configuration out of `Bundle.main` + the environment.
    public static func load(bundle: Bundle = .main) throws -> AppLessConfiguration {
        guard let url = bundle.url(forResource: schemaResource, withExtension: "json") else {
            throw LoadError.missingContract
        }
        let schema = try LibrarySchema.load(from: url)
        var prompt = ""
        if let promptURL = bundle.url(forResource: promptResource, withExtension: "txt"),
            let text = try? String(contentsOf: promptURL, encoding: .utf8)
        {
            prompt = text
        }
        return AppLessConfiguration(
            schema: schema,
            systemPrompt: prompt,
            cerebrasKey: setting("AppLessCerebrasAPIKey", "EXPO_PUBLIC_CEREBRAS_API_KEY", bundle),
            exaKey: setting("AppLessExaAPIKey", "EXPO_PUBLIC_EXA_API_KEY", bundle),
            baseURL: setting("AppLessBaseURL", "EXPO_PUBLIC_CEREBRAS_BASE_URL", bundle)
                ?? GenOSConstants.defaultBaseURL,
            model: setting("AppLessModel", "EXPO_PUBLIC_GENOS_MODEL", bundle)
                ?? GenOSConstants.defaultModel)
    }

    /// Info.plist first, then the process environment; blank values count as
    /// absent (RN `?.trim() || null`).
    private static func setting(_ plistKey: String, _ environmentKey: String, _ bundle: Bundle)
        -> String?
    {
        let candidates = [
            bundle.object(forInfoDictionaryKey: plistKey) as? String,
            ProcessInfo.processInfo.environment[environmentKey],
        ]
        for candidate in candidates {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            {
                return value
            }
        }
        return nil
    }
}

// MARK: - Factory

public enum AppLessRuntime {

    /// Assemble a live shell: screen store, streaming client, key store and
    /// controller, wired exactly as `src/genos/store.ts` wires its module
    /// singletons.
    @MainActor
    public static func makeModel(
        configuration: AppLessConfiguration,
        apps: [AppDef] = Apps.all
    ) -> GenOSShellModel {
        let clock = SystemClock()
        let store = ScreenStore(clock: clock)
        let http = URLSessionHTTP()
        let keyStore = KeyStore(envKey: configuration.cerebrasKey, store: makeSecureStore())
        let streamer = StreamClient(
            http: http,
            keyStore: keyStore,
            config: StreamConfig(
                baseURL: configuration.baseURL,
                model: configuration.model,
                systemPrompt: configuration.systemPrompt),
            tools: ExaSearchTool(apiKey: configuration.exaKey, http: http))
        let controller = GenOSController(
            store: store, streamer: streamer, clock: clock, apps: apps)
        return GenOSShellModel(
            controller: controller,
            keyStore: keyStore,
            schema: configuration.schema,
            apps: apps)
    }

    static func makeSecureStore() -> SecureStore {
        #if canImport(Security)
            return KeychainSecureStore()
        #else
            return EphemeralSecureStore()
        #endif
    }
}

#endif
