package dev.appless.app.platform

import dev.appless.genoscore.HttpFetching
import dev.appless.genoscore.HttpRequest
import dev.appless.genoscore.HttpResponseHead
import dev.appless.genoscore.HttpStreaming
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.coroutineContext

/**
 * The Android half of `genos-core`'s networking seams — the RN app's `fetch`
 * with a `ReadableStream` body.
 *
 * ONE [OkHttpClient] is shared by both seams so the connection pool, DNS cache
 * and TLS sessions are reused across the SSE stream and the Exa/Unsplash/
 * telemetry fetches. Read timeout is disabled for streaming: a slow model can
 * legitimately go tens of seconds between tokens, and OkHttp's default 10 s
 * read timeout would kill the generation mid-screen.
 */
public object AppLessHttp {

    public val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .writeTimeout(20, TimeUnit.SECONDS)
        // Per-call: the streaming seam overrides this to "no timeout".
        .readTimeout(30, TimeUnit.SECONDS)
        .callTimeout(0, TimeUnit.MILLISECONDS)
        .retryOnConnectionFailure(true)
        .build()

    internal fun toOkHttp(request: HttpRequest): Request {
        val builder = Request.Builder().url(request.url)
        for ((name, value) in request.headers) builder.header(name, value)
        val method = request.method.uppercase()
        val body = when {
            request.body != null -> {
                val type = request.headers.entries
                    .firstOrNull { it.key.equals("content-type", ignoreCase = true) }
                    ?.value ?: "application/json"
                request.body!!.toRequestBody(type.toMediaType())
            }
            // OkHttp requires a (possibly empty) body for POST/PUT/PATCH.
            method in setOf("POST", "PUT", "PATCH") -> ByteArray(0).toRequestBody(null)
            else -> null
        }
        return builder.method(method, body).build()
    }

    internal fun head(response: Response): HttpResponseHead = HttpResponseHead(
        status = response.code,
        // Multi-valued headers are joined the way `fetch`'s Headers.get does.
        headers = response.headers.names().associateWith { name ->
            response.headers.values(name).joinToString(", ")
        },
    )
}

/**
 * Streaming seam: response head first, then raw byte chunks as they arrive.
 *
 * `genos-core` owns the SSE line protocol AND the incremental UTF-8 decode
 * (its `Utf8StreamDecoder` is a port of the WHATWG decoder `TextDecoder` runs),
 * so this must hand over BYTES, never text — decoding here would move the
 * chunk-boundary behavior off the tested path.
 *
 * Cancellation: the flow is collected inside the stream loop's coroutine, and
 * cancelling it closes the response body, which unblocks (and aborts) the
 * in-flight read.
 */
public class OkHttpStreaming(
    private val client: OkHttpClient = AppLessHttp.client,
) : HttpStreaming {

    override suspend fun stream(request: HttpRequest): Pair<HttpResponseHead, Flow<ByteArray>> {
        val call = client.newBuilder()
            // A generation can idle between tokens; a read timeout would abort it.
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()
            .newCall(AppLessHttp.toOkHttp(request))

        val response = call.await()
        val head = AppLessHttp.head(response)

        val body = response.body
        if (body == null) {
            response.close()
            return head to flow { }
        }

        val chunks = flow {
            // `use` guarantees the socket is released on completion, error AND
            // cancellation — the latter is what token.cancel() relies on.
            body.use { rb ->
                val source = rb.source()
                val buffer = ByteArray(DEFAULT_CHUNK)
                while (true) {
                    // Cooperative: a cancelled collector stops here instead of
                    // draining the rest of the generation.
                    coroutineContext.ensureActive()
                    val read = try {
                        source.inputStream().read(buffer)
                    } catch (_: IOException) {
                        // A closed socket mid-stream is a DROPPED stream, which
                        // genos-core detects from the missing `[DONE]` sentinel
                        // and surfaces as retryable. Ending the flow is right.
                        break
                    }
                    if (read <= 0) break
                    emit(buffer.copyOf(read))
                }
            }
        }.flowOn(Dispatchers.IO)

        return head to chunks
    }

    private companion object {
        const val DEFAULT_CHUNK = 8 * 1024
    }
}

/** Non-streaming seam: Exa search, Unsplash, PostHog telemetry. */
public class OkHttpFetching(
    private val client: OkHttpClient = AppLessHttp.client,
) : HttpFetching {

    override suspend fun fetch(request: HttpRequest): Pair<HttpResponseHead, ByteArray> =
        withContext(Dispatchers.IO) {
            client.newCall(AppLessHttp.toOkHttp(request)).await().use { response ->
                AppLessHttp.head(response) to (response.body?.bytes() ?: ByteArray(0))
            }
        }
}

/**
 * `Call.enqueue` as a suspend function, cancelling the call when the coroutine
 * is cancelled.
 *
 * `suspendCoroutine` + an explicit `invokeOnCancellation` equivalent is spelled
 * out rather than pulled from `okhttp-coroutines` (an alpha artifact) so the
 * dependency surface stays at the stable OkHttp core.
 */
private suspend fun Call.await(): Response {
    val call = this
    return kotlinx.coroutines.suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : okhttp3.Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (!continuation.isCancelled) continuation.resumeWith(Result.failure(e))
            }

            override fun onResponse(call: Call, response: Response) {
                continuation.resumeWith(Result.success(response))
            }
        })
    }
}
