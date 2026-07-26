package dev.appless.genoscore

/** Parity-critical constants (spec/capabilities.md "Constants" table). */
public object GenOSConstants {
    /** Subscriber-notify throttle during streaming; `patch` flushes immediately. */
    public const val STREAM_FLUSH_MS: Double = 50.0

    /** Speculative children launched per visible done screen. */
    public const val MAX_PREFETCH: Int = 6

    /** Ancestor screens replayed as conversation context. */
    public const val CONTEXT_DEPTH: Int = 2

    /** A cached screen still pending/streaming this long is stuck. */
    public const val STALE_MS: Double = 30_000.0

    /** Rounds that may end in tool calls before tools are withheld. */
    public const val MAX_TOOL_ROUNDS: Int = 3

    public const val TEMPERATURE: Double = 0.8
    public const val MAX_COMPLETION_TOKENS: Int = 3072

    /** Sentinel error message thrown when a tool round is refused (prefetch quota). */
    public const val NEEDS_LIVE_DATA: String = "needs live data"

    /** Toast display duration in the shell. */
    public const val TOAST_MS: Double = 2800.0

    public const val DEFAULT_BASE_URL: String = "https://api.cerebras.ai/v1"
    public const val DEFAULT_MODEL: String = "gemma-4-31b"

    /** Exa search request shape. */
    public const val EXA_NUM_RESULTS: Int = 5
    public const val EXA_MAX_CHARACTERS: Int = 400
}
