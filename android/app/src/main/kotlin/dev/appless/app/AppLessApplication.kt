package dev.appless.app

import android.app.Application
import android.content.Context
import dev.appless.app.platform.OkHttpFetching
import dev.appless.app.platform.OkHttpStreaming
import dev.appless.app.platform.ResilientSecureStore
import dev.appless.app.render.material.MaterialRenderers
import dev.appless.genoscore.Apps
import dev.appless.genoscore.CoroutineClock
import dev.appless.genoscore.ExaSearchTool
import dev.appless.genoscore.GenOSController
import dev.appless.genoscore.KeyStore
import dev.appless.genoscore.ScreenStore
import dev.appless.genoscore.StreamClient
import dev.appless.genoscore.StreamConfig
import dev.appless.genoscore.Telemetry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.IOException
import java.util.UUID

/**
 * The object graph.
 *
 * Everything stateful in `genos-core` is SINGLE-THREADED BY CONTRACT — the
 * store, controller and key store must all be confined to one dispatcher. That
 * dispatcher is [Dispatchers.Main.immediate] here, which is also the dispatcher
 * Compose recomposes on, so a `StateFlow` collected in the UI and a store
 * mutation from a tap are never racing.
 *
 * Blocking work (sockets, Keystore, disk) hops to `Dispatchers.IO` INSIDE the
 * seam implementations, so nothing on this scope ever blocks a frame.
 */
public class AppLessApplication : Application() {

    /** Confined to Main: see the class comment. */
    public val scope: CoroutineScope by lazy {
        CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    }

    public val clock: CoroutineClock by lazy { CoroutineClock(scope) }
    public val secureStore: ResilientSecureStore by lazy { ResilientSecureStore(this) }
    public val screenStore: ScreenStore by lazy { ScreenStore(clock) }

    public val keyStore: KeyStore by lazy {
        // BYOK: there is no build-time key, so the gate always starts from the
        // persisted one (env override kept for parity with the RN config).
        KeyStore(envKey = BuildConfig.CEREBRAS_KEY.ifEmpty { null }, store = secureStore, scope = scope)
    }

    private val streaming by lazy { OkHttpStreaming() }
    private val fetching by lazy { OkHttpFetching() }

    /** `web_search`, available only when an Exa key was configured. */
    public val searchTool: ExaSearchTool by lazy {
        ExaSearchTool(apiKey = BuildConfig.EXA_KEY.ifEmpty { null }, http = fetching)
    }

    public val streamClient: StreamClient by lazy {
        StreamClient(
            http = streaming,
            keyStore = keyStore,
            config = StreamConfig(systemPrompt = loadSystemPrompt(this)),
            tools = searchTool,
            scope = scope,
        )
    }

    public val controller: GenOSController by lazy {
        GenOSController(
            store = screenStore,
            streamer = streamClient,
            clock = clock,
            apps = Apps.all,
        )
    }

    override fun onCreate() {
        super.onCreate()

        // Publish the Material renderer set BEFORE the first composition, so
        // `RenderElement` can resolve every component on the very first frame
        // of a stream.
        MaterialRenderers.register()

        scope.launch { keyStore.hydrate() }
        scope.launch {
            Telemetry.initTelemetry(
                env = System.getenv() ?: emptyMap(),
                platform = "android",
                store = secureStore,
                http = fetching,
                scope = scope,
                newId = { UUID.randomUUID().toString() },
            )
        }
    }

    public companion object {

        /**
         * The system prompt, staged into assets from
         * `spec/prompt/system-prompt.generated.txt` by the `stageSystemPrompt`
         * Gradle task (the spec-gates workflow proves that file is
         * byte-identical to the RN `SYSTEM_PROMPT`).
         *
         * An empty string on failure is deliberate: the app still runs and the
         * error surfaces as bad generations rather than a crash on launch.
         */
        public fun loadSystemPrompt(context: Context): String = try {
            context.assets.open(SYSTEM_PROMPT_ASSET).use { it.readBytes().toString(Charsets.UTF_8) }
        } catch (_: IOException) {
            ""
        }

        public const val SYSTEM_PROMPT_ASSET: String = "system-prompt.txt"
    }
}

/** The running application, for composables that need the graph. */
public val Context.appless: AppLessApplication
    get() = applicationContext as AppLessApplication
