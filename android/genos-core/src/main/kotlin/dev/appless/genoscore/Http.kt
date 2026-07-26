package dev.appless.genoscore

import kotlinx.coroutines.flow.Flow

/** One outbound request. Bodies are always UTF-8 JSON in this package. */
public class HttpRequest(
    public val url: String,
    public val method: String = "POST",
    public val headers: Map<String, String> = emptyMap(),
    public val body: ByteArray? = null,
) {
    /** The body decoded as UTF-8 (empty when absent) — what tests assert on. */
    public val bodyText: String
        get() = body?.toString(Charsets.UTF_8) ?: ""

    override fun toString(): String = "$method $url ${headers.keys.sorted()} $bodyText"
}

public data class HttpResponseHead(
    val status: Int,
    val headers: Map<String, String> = emptyMap(),
) {
    public val ok: Boolean
        get() = status in 200..299
}

/**
 * Streaming networking seam: request → response head + raw byte chunks.
 * Tests inject scripted SSE byte streams; the app wires OkHttp.
 *
 * Cancellation contract: the returned [Flow] is collected inside the stream
 * loop's coroutine, which `StreamCancelToken.cancel()` cancels. Flow collection
 * is cooperative by construction, so a cancelled consumer stops pulling
 * immediately — implementations only need to avoid blocking calls that ignore
 * interruption.
 */
public interface HttpStreaming {
    public suspend fun stream(request: HttpRequest): Pair<HttpResponseHead, Flow<ByteArray>>
}

/** Non-streaming fetch seam (Exa search, Unsplash, telemetry). */
public interface HttpFetching {
    public suspend fun fetch(request: HttpRequest): Pair<HttpResponseHead, ByteArray>
}

/** Key persistence seam; tests inject an in-memory implementation. */
public interface SecureStore {
    /** Read the stored value for [key], null when absent. */
    public suspend fun read(key: String): String?

    /** Write [value] for [key]; null deletes. */
    public suspend fun write(key: String, value: String?)
}
