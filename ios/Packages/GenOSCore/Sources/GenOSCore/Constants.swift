import Foundation

/// Parity-critical constants (spec/capabilities.md "Constants" table).
public enum GenOSConstants {
    /// Subscriber-notify throttle during streaming; `patch` flushes immediately.
    public static let streamFlushMs: Double = 50
    /// Speculative children launched per visible done screen.
    public static let maxPrefetch = 6
    /// Ancestor screens replayed as conversation context.
    public static let contextDepth = 2
    /// A cached screen still pending/streaming this long is stuck.
    public static let staleMs: Double = 30_000
    /// Rounds that may end in tool calls before tools are withheld.
    public static let maxToolRounds = 3
    public static let temperature = 0.8
    public static let maxCompletionTokens = 3072
    /// Sentinel error message thrown when a tool round is refused (prefetch quota).
    public static let needsLiveData = "needs live data"
    /// Toast display duration in the shell.
    public static let toastMs: Double = 2800
    public static let defaultBaseURL = "https://api.cerebras.ai/v1"
    public static let defaultModel = "gemma-4-31b"
    /// Exa search request shape.
    public static let exaNumResults = 5
    public static let exaMaxCharacters = 400
}
