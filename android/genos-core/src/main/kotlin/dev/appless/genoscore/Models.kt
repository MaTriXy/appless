package dev.appless.genoscore

// Chat protocol models (src/genos/stream.ts)

public data class ToolCall(
    val id: String = "",
    /** Always "function" in the OpenAI-compatible schema. */
    val type: String = "function",
    val name: String = "",
    val arguments: String = "",
)

public enum class ChatRole(public val wire: String) {
    USER("user"),
    ASSISTANT("assistant"),
    SYSTEM("system"),
    TOOL("tool"),
}

public data class ChatMessage(
    val role: ChatRole,
    val content: String?,
    val toolCalls: List<ToolCall>? = null,
    val toolCallId: String? = null,
)

public data class StreamEndInfo(
    /** Provider reported `finish_reason: "length"` — the screen was cut short. */
    val truncated: Boolean = false,
    /** Stream ended without `[DONE]` or a finish_reason — likely dropped mid-flight. */
    val dropped: Boolean = false,
)

// Screen model (src/genos/store.ts)

public enum class ScreenStatus { PENDING, STREAMING, DONE, ERROR }

public enum class OSCommandKind(public val wire: String) {
    BACK("back"),
    HOME("home"),
    SWITCHER("switcher"),
    OPEN("open");

    public companion object {
        public fun from(wire: String): OSCommandKind? = entries.firstOrNull { it.wire == wire }
    }
}

public data class OSCommand(val cmd: OSCommandKind, val arg: String? = null)

public data class Screen(
    val id: String,
    val appId: String,
    val appName: String,
    /** The user-intent message that produced this screen. */
    val request: String,
    val parentId: String? = null,
    /** Accumulating openui-lang source. */
    val content: String = "",
    val status: ScreenStatus = ScreenStatus.PENDING,
    val error: String? = null,
    /** True while the screen exists only as a speculative prefetch. */
    val speculative: Boolean = false,
    /** Clock milliseconds when generation started — staleness + latency tracking. */
    val startedAt: Double = 0.0,
    /** Wall-clock generation time once done. */
    val genMs: Int? = null,
    /** The screen was already fully generated when the user tapped into it. */
    val prefetched: Boolean? = null,
    /** Provider cut the generation short (`finish_reason: "length"`). */
    val truncated: Boolean? = null,
    /** The model answered with an `@OS(...)` command instead of a screen. */
    val osCommand: OSCommand? = null,
    /** The model is running tools (web_search) before composing the screen. */
    val searching: Boolean? = null,
)
