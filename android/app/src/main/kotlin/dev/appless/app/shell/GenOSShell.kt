package dev.appless.app.shell

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.PredictiveBackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.scaleIn
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.appless.app.AppLessApplication
import dev.appless.app.render.ActionDispatcher
import dev.appless.app.render.FormStore
import dev.appless.app.render.ScreenView
import dev.appless.app.render.toControllerFormState
import dev.appless.app.theme.LocalShellTheme
import dev.appless.app.theme.toColor
import dev.appless.genoscore.AppDef
import dev.appless.genoscore.Apps
import dev.appless.genoscore.GenOSConstants
import dev.appless.genoscore.KeyStatus
import dev.appless.genoscore.Lang
import dev.appless.genoscore.OSCommandKind
import dev.appless.genoscore.Screen
import dev.appless.genoscore.ScreenStatus
import dev.appless.openuilang.LibrarySchema
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The OS shell — `src/genos/GenOS.tsx`.
 *
 * Everything below is navigation and chrome. Screen generation, caching,
 * prefetch and the `@OS(...)` / `genos://` PARSING all live in `genos-core`;
 * the decision tables live in [ShellState], [ActionRouter] and [CommandRouter],
 * where they are unit-tested. What is left here is the wiring and the pixels.
 */
@Composable
internal fun GenOSShell(app: AppLessApplication, schema: LibrarySchema) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val shellTheme = LocalShellTheme.current

    var state by remember { mutableStateOf(ShellState()) }
    var minimizing by remember { mutableStateOf(false) }
    var toast by remember { mutableStateOf<ShellToastState?>(null) }
    var toastSeq by remember { mutableIntStateOf(0) }
    var showHint by remember { mutableStateOf(false) }
    val hintArmed = remember { mutableStateOf(false) }
    val minimizeProgress = remember { Animatable(0f) }

    // `useSyncExternalStore(screenStore.subscribe, screenStore.getVersion)` —
    // tick, then RE-READ. The 50 ms coalescing in ScreenStore is what makes
    // this cheap during a stream.
    val storeVersion by app.screenStore.versionFlow.collectAsStateWithLifecycle()
    val keyStatus by app.keyStore.statusFlow.collectAsStateWithLifecycle()

    val topId = state.topId
    val top: Screen? = remember(storeVersion, topId) { topId?.let { app.screenStore.get(it) } }
    val generating = top?.status == ScreenStatus.PENDING || top?.status == ScreenStatus.STREAMING

    val insets = WindowInsets.safeDrawing.asPaddingValues()
    val topInset = insets.calculateTopPadding()
    val bottomInset = insets.calculateBottomPadding()

    // ------------------------------------------------------------- side effects

    // The controller prefetches ONLY for the visible screen, so it has to be
    // told which one that is — including when its status flips to done.
    LaunchedEffect(topId, top?.status) { app.controller.setActiveScreen(topId) }

    // One-time gesture hint on the first app open — `GenOS.tsx` L215-231.
    LaunchedEffect(state.activeApp) {
        if (state.activeApp == null || hintArmed.value) return@LaunchedEffect
        hintArmed.value = true
        showHint = true
        try {
            delay(6000)
        } finally {
            // Also hidden on cleanup: leaving the first app within 6 s would
            // otherwise cancel the timer and strand the hint on screen forever.
            showHint = false
        }
    }

    LaunchedEffect(toast?.seq) {
        if (toast == null) return@LaunchedEffect
        delay(GenOSConstants.TOAST_MS.toLong())
        toast = null
    }

    fun showToast(text: String) {
        toastSeq += 1
        toast = ShellToastState(text, toastSeq)
    }

    // Summoned apps adopt the title the model gave their FIRST screen. The gate
    // (summon- prefix, stack depth exactly 1) is `genos-core`'s.
    LaunchedEffect(state.activeApp, top?.content, state.stack.size) {
        val appId = state.activeApp ?: return@LaunchedEffect
        val title = Lang.summonedAppTitle(appId, state.stack.size, top?.content.orEmpty())
            ?: return@LaunchedEffect
        state = state.renameApp(appId, title)
    }

    // ------------------------------------------------------------- navigation

    fun launch(appDef: AppDef) {
        var next = state
            .withNavAnim(NavDir.LAUNCH)
            .rememberMeta(appDef.id, AppMeta.of(appDef))
        // openApp touches the screen store (which notifies subscribers), so it
        // must run HERE in the event handler — never inside a state updater.
        if (next.sessions[appDef.id].isNullOrEmpty()) {
            next = next.startSession(appDef.id, app.controller.openApp(appDef))
        }
        state = next.activate(appDef.id)
    }

    fun goHome() {
        state = state.setSwitcher(false)
        val appId = state.activeApp ?: return
        if (minimizing) return
        minimizing = true
        scope.launch {
            try {
                // The screen shrinks toward the home icon grid, then the app
                // joins the minimized set — `goHome`, GenOS.tsx L318-343.
                minimizeProgress.animateTo(1f, tween(360, easing = EASE))
                state = state.commitMinimize(appId)
            } finally {
                minimizing = false
                minimizeProgress.snapTo(0f)
            }
        }
    }

    fun goBack() {
        if (state.activeApp == null || minimizing) return
        state = state.goBack()
    }

    fun deepLink(rawAppId: String, request: String) {
        val id = app.controller.openDeepLink(rawAppId, request)
        val lower = rawAppId.lowercase()
        val known = Apps.find(lower)
        val meta = AppMeta(
            name = known?.name ?: ShellState.capitalize(rawAppId),
            emoji = known?.emoji ?: "✨",
            tileStart = known?.tileStart ?: Apps.DEFAULT_TILE_START,
            tileEnd = known?.tileEnd ?: Apps.DEFAULT_TILE_END,
        )
        state = state.rememberMeta(lower, meta).pushScreen(lower, id).activate(lower)
    }

    fun resolve(message: String, formState: List<Pair<String, dev.appless.genoscore.JsonValue>>?) {
        val parent = topId ?: return
        val appId = state.activeApp ?: return
        state = state.pushScreen(appId, app.controller.resolveAction(parent, message, formState))
    }

    // ------------------------------------------------------------ @OS commands

    val executedOsCommands = remember { mutableSetOf<String>() }
    LaunchedEffect(top?.osCommand, topId, state.activeApp) {
        val command = top?.osCommand ?: return@LaunchedEffect
        val screenId = topId ?: return@LaunchedEffect
        if (state.activeApp == null) return@LaunchedEffect
        if (!executedOsCommands.add(screenId)) return@LaunchedEffect

        // The screen that CARRIED the command is dropped first, then the
        // navigation applies.
        state = state.applyOsCommand(screenId, command)
        when (command.cmd) {
            OSCommandKind.HOME -> goHome()
            OSCommandKind.SWITCHER -> state = state.setSwitcher(true)
            OSCommandKind.OPEN -> command.arg?.let { launch(CommandRouter.resolveOsOpen(it)) }
            OSCommandKind.BACK -> Unit // already applied by applyOsCommand
        }
    }

    // --------------------------------------------------------------- dispatch

    val formStore = remember(topId) { FormStore() }
    val dispatcher = remember(topId, state.activeApp, generating) {
        ActionDispatcher(formStore) { event ->
            when (val route = ActionRouter.route(event, topId != null && state.activeApp != null, generating)) {
                is ActionRoute.Toast -> showToast(route.text)
                is ActionRoute.DeepLink -> deepLink(route.appId, route.request)
                ActionRoute.Back -> goBack()
                ActionRoute.Home -> goHome()
                is ActionRoute.OpenExternalUrl -> runCatching {
                    context.startActivity(
                        Intent(Intent.ACTION_VIEW, Uri.parse(route.url))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                }
                is ActionRoute.StillGenerating -> showToast(route.toast)
                is ActionRoute.Resolve -> resolve(
                    route.message,
                    route.formState.toControllerFormState().ifEmpty { null },
                )
                ActionRoute.Ignore -> Unit
            }
        }
    }

    fun routeCommand(text: String) {
        when (val command = CommandRouter.route(text, state.activeApp, topId != null)) {
            ShellCommand.Back -> goBack()
            ShellCommand.Home -> goHome()
            ShellCommand.CloseApp -> state.activeApp?.let { state = state.closeSession(it) }
            ShellCommand.OpenSwitcher -> state = state.setSwitcher(true)
            is ShellCommand.Launch -> launch(command.app)
            is ShellCommand.Continue -> resolve(command.text, null)
            is ShellCommand.Summon -> launch(command.app)
            ShellCommand.Ignore -> Unit
        }
    }

    // ------------------------------------------------------- predictive back

    val backAction = ShellBack.action(state, minimizing)
    PredictiveBackHandler(enabled = backAction != BackAction.NOT_HANDLED) { progress ->
        try {
            // Android 14+ feeds gesture progress here; consuming it is what
            // makes the system draw the predictive-back preview instead of
            // treating the gesture as unhandled.
            progress.collect { }
            when (backAction) {
                BackAction.CLOSE_SWITCHER -> state = state.setSwitcher(false)
                BackAction.BACK -> goBack()
                BackAction.HOME -> goHome()
                // CONSUME: swallowed so the minimize animation is not raced.
                BackAction.CONSUME, BackAction.NOT_HANDLED -> Unit
            }
        } catch (_: CancellationException) {
            // The user let go mid-gesture: nothing to undo, the state never moved.
        }
    }

    // ------------------------------------------------------------------- UI

    Box(
        Modifier
            .fillMaxSize()
            .background(shellTheme.bg.toColor())
            .imePadding(),
    ) {
        HomeScreen(
            topInset = topInset,
            covered = state.activeApp != null,
            onCommand = ::routeCommand,
            runningApps = state.homeApps,
            onResume = { state = state.activate(it) },
            onClose = { state = state.closeSession(it) },
        )

        if (top != null) {
            Box(
                Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        val p = minimizeProgress.value
                        // Aim the shrinking screen at the icon grid, clamped so
                        // short/landscape windows never animate downward.
                        val target = (size.height / 2f) -
                            (topInset.toPx() + ChromeMetrics.minimizeTargetOffset.toPx())
                        translationY = -p * maxOf(0f, target)
                        scaleX = 1f - p * 0.92f
                        scaleY = 1f - p * 0.92f
                        alpha = 1f - p
                    },
            ) {
                ScreenFrame(
                    key = topId.orEmpty(),
                    navAnim = state.navAnim,
                    dark = shellTheme.dark,
                    background = shellTheme.bg.toColor(),
                ) {
                    if (top.status == ScreenStatus.ERROR) {
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            ErrorRetry(top.error.orEmpty()) {
                                topId?.let { app.controller.retryScreen(it) }
                            }
                        }
                    } else {
                        Column(
                            Modifier
                                .fillMaxSize()
                                .verticalScroll(rememberScrollState())
                                .padding(
                                    top = topInset + ChromeMetrics.contentTopPadding,
                                    start = ChromeMetrics.contentHorizontalPadding,
                                    end = ChromeMetrics.contentHorizontalPadding,
                                    bottom = bottomInset + ChromeMetrics.contentBottomPadding,
                                ),
                        ) {
                            if (top.content.isNotEmpty()) {
                                ScreenView(
                                    content = top.content,
                                    isStreaming = generating,
                                    schema = schema,
                                    formStore = formStore,
                                    dispatcher = dispatcher,
                                )
                            } else {
                                Skeleton()
                            }
                        }
                    }
                }
            }
        }

        // ----------------------------------------------------------- chrome

        val chromeVisible = state.activeApp != null && !state.switcherOpen
        if (chromeVisible) {
            BackOrHomePill(
                isBack = state.stack.size > 1,
                onClick = { if (state.stack.size > 1) goBack() else goHome() },
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .padding(top = topInset + ChromeMetrics.pillTopInset, start = 12.dp),
            )
            SwitcherPill(
                onClick = { state = state.setSwitcher(true) },
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(top = topInset + ChromeMetrics.pillTopInset, end = 12.dp),
            )
        }

        if (chromeVisible && showHint) {
            GestureHint(
                onDismiss = { showHint = false },
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = bottomInset + 46.dp),
            )
        }

        if (state.activeApp != null && generating) {
            GeneratingPill(
                searching = top?.searching == true,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = bottomInset + 34.dp),
            )
        }

        toast?.let {
            ShellToast(
                text = it.text,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = topInset + 12.dp),
            )
        }

        if (state.switcherOpen) {
            Switcher(
                apps = state.runningApps,
                screenFor = { appId ->
                    @Suppress("UNUSED_EXPRESSION") storeVersion
                    state.sessions[appId]?.lastOrNull()?.let { app.screenStore.get(it) }
                },
                schema = schema,
                onResume = { state = state.activate(it) },
                onClose = { state = state.closeSession(it) },
                onDismiss = { state = state.setSwitcher(false) },
            )
        }

        if (keyStatus == KeyStatus.MISSING || keyStatus == KeyStatus.REJECTED) {
            KeyGate(
                status = keyStatus,
                onSubmit = { app.keyStore.set(it) },
                onGetKey = {
                    runCatching {
                        context.startActivity(
                            Intent(Intent.ACTION_VIEW, Uri.parse("https://cloud.cerebras.ai"))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                    }
                },
            )
        }
    }
}

/** Toast payload — the `key` forces a fresh animation for a repeated message. */
private data class ShellToastState(val text: String, val seq: Int)

/**
 * `ScreenTransition` — `GenOS.tsx` L82-126.
 *
 * Direction-aware: launch zooms up from below, push slides in from the right,
 * pop settles back in from the left.
 */
@Composable
private fun ScreenFrame(
    key: String,
    navAnim: NavDir,
    dark: Boolean,
    background: Color,
    content: @Composable () -> Unit,
) {
    AnimatedContent(
        targetState = key,
        transitionSpec = {
            val duration = when (navAnim) {
                NavDir.LAUNCH -> 380
                NavDir.PUSH -> 300
                NavDir.POP -> 260
            }
            val enter = when (navAnim) {
                NavDir.LAUNCH -> fadeIn(tween(duration, easing = EASE)) +
                    scaleIn(initialScale = 0.88f, animationSpec = tween(duration, easing = EASE))
                NavDir.PUSH -> fadeIn(tween(duration, easing = EASE)) +
                    slideInHorizontally(tween(duration, easing = EASE)) { (it * 0.15f).toInt() }
                NavDir.POP -> fadeIn(tween(duration, easing = EASE)) +
                    slideInHorizontally(tween(duration, easing = EASE)) { -(it * 0.12f).toInt() }
            }
            enter togetherWith fadeOut(tween(duration / 2)) + slideOutHorizontally { 0 }
        },
        label = "screen-transition",
    ) { _ ->
        Box(
            Modifier
                .fillMaxSize()
                .background(
                    // `["#ffffff", t.bg]` with locations [0, 0.35] in light
                    // mode, a flat fill in dark — GenOS.tsx L598-601.
                    if (dark) {
                        Brush.verticalGradient(listOf(background, background))
                    } else {
                        Brush.verticalGradient(
                            0f to Color.White,
                            0.35f to background,
                            1f to background,
                        )
                    }
                ),
        ) {
            Box(Modifier.fillMaxWidth().alpha(1f)) { content() }
        }
    }
}
