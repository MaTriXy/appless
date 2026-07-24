# AppLess Capability Map — Verified

**Status:** Layer-0 spec (plan §6, "kept live"). Every row below was verified against
the actual RN source on 2026-07-24; deviations from the plan text are called out in
§Corrections. File references are the normative source of truth for each row.

## Constants (parity-critical — assert these in native unit tests)

| Constant | Value | Source |
|---|---|---|
| `STREAM_FLUSH_MS` | **50** ms (subscriber-notify throttle during streaming; `patch()` status changes flush immediately; content is buffered synchronously) | `src/genos/store.ts` |
| `MAX_PREFETCH` | **6** speculative children per visible done screen | `src/genos/store.ts` |
| `CONTEXT_DEPTH` | **2** ancestor screens replayed as context | `src/genos/store.ts` |
| `STALE_MS` | **30 000** ms — a cached screen still pending/streaming this long is stuck → regenerate on reuse | `src/genos/store.ts` |
| `MAX_TOOL_ROUNDS` | **3** — rounds ≥ 3 are sent **without** the `tools` array, forcing a screen | `src/genos/stream.ts` |
| `temperature` | **0.8** | `src/genos/stream.ts` |
| `max_completion_tokens` | **3072** | `src/genos/stream.ts` |
| `stream` | `true` (SSE) | `src/genos/stream.ts` |
| Default model | `gemma-4-31b` (`EXPO_PUBLIC_GENOS_MODEL` override) | `src/config.ts` |
| Base URL | `https://api.cerebras.ai/v1` (`EXPO_PUBLIC_CEREBRAS_BASE_URL` override) | `src/config.ts` |
| Exa results | `numResults: 5`, `contents.text.maxCharacters: 400` | `src/genos/tools/search.ts` |
| Toast duration | 2800 ms; OS-command dedupe per screen id | `src/genos/GenOS.tsx` |
| `NEEDS_LIVE_DATA` sentinel | error message `"needs live data"` | `src/genos/stream.ts` |

## Capability table

| Capability | Verified current behavior | iOS port | Android port |
|---|---|---|---|
| **BYOK key gate** | Key resolution order: `EXPO_PUBLIC_CEREBRAS_API_KEY` env (build-time) → persisted key (SecureStore key `genos.cerebras-key`; localStorage on web). `KeyStatus`: `loading / missing / present / rejected`. A key entered while hydration is in flight wins over the hydrated value. HTTP **401/403** → `markRejected(key)` — no-op if the key was already replaced; clears persisted key and re-shows the gate with `rejected` state. *(config.ts, stream.ts)* | Keychain (Security.framework); build-setting override | Keystore/EncryptedSharedPreferences; BuildConfig override |
| **SSE + tool loop** | POST `{base}/chat/completions`, OpenAI schema. Messages: `[system] + context (§Context) + user`. `data:` line protocol; `[DONE]` sentinel; per-chunk JSON with `choices[0].delta`. Tool-call deltas accumulated **by `index`** (id/name assigned, `arguments` string-concatenated), then sorted by index. `finish_reason "length"` → `truncated`; stream end with no `[DONE]` **and** no finish_reason → `dropped` → retryable error `"The connection dropped mid-screen - retry"` (unless nothing at all arrived, which throws immediately). In-chunk `error` object → thrown with its message. Tool loop: while a round finishes `tool_calls` (and produced ≥1 call), append assistant msg (`content \|\| null`, `tool_calls`), execute all calls in parallel, append one `tool` message per call (`tool_call_id`), loop. `onToolRound` may return `"abort"` → throw `NEEDS_LIVE_DATA`. Malformed tool-call arguments JSON → `{}`. *(stream.ts)* | `URLSession.bytes` + line splitter | OkHttp SSE / Ktor |
| **UTF-8 across chunks** | `TextDecoder(stream:true)` when available; manual fallback holds back trailing incomplete multi-byte sequences between chunks. | `AsyncBytes` native | OkHttp native |
| **System prompt** | `SYSTEM_PROMPT` (build-time embed) + `TOOLS_PROMPT_SECTION` **only when the Exa key is present** + `"\n\nToday is <Weekday, Month D, YYYY>"` (en-US long format), rebuilt per request. *(stream.ts, tools/search.ts)* | generate from `spec/` at build | same |
| **Context building** | Walk parents up to `CONTEXT_DEPTH = 2` ancestors; replay each ancestor as `user: request` + (if content) `assistant: cleanLang(content)`; final turn is the new screen's `request`. Text-only; images not re-sent. *(store.ts `buildMessages`)* | identical | identical |
| **web_search tool (Exa)** | Offered only when `EXPO_PUBLIC_EXA_API_KEY` set (`toolsAvailable()`); single tool def `web_search {query: string}`. POST `https://api.exa.ai/search` header `x-api-key`; body `{query, numResults: 5, contents: {text: {maxCharacters: 400}}}`. Results mapped to `{title (fallback: domain), url, snippet (whitespace-collapsed), published?}`. Formatting: `Web results for "q":` + numbered `title - domain (YYYY-MM-DD)\n   snippet`; empty → honest "none found" instruction. All failures return an `ERROR: …` **string** as the tool message (never throw): unknown tool, empty query, HTTP/network errors (detail truncated to 200 chars). *(tools/search.ts)* | port 1:1 | port 1:1 |
| **Semantic images** | Model emits `/api/img?q&seed&w&h`. `parseImgUrl` sanitization/clamps and LoremFlickr/Unsplash resolution incl. seed-indexed candidate pick and `&w&h&fit=crop&q=80` suffix — normative algorithm in `spec/openui-lang.md` §11.5. Per-query in-memory cache + in-flight dedupe; placeholder while searching; failed search → LoremFlickr. Non-`/api/img` srcs pass through untouched. *(tools/images.ts)* | URL rewriter + AsyncImage | rewriter + Coil |
| **Speculative prefetch** | Only for the **visible** (`setActiveScreen`) screen with status `done`, on becoming visible or finishing while visible. `extractActions(cleanLang(content))` → first **6** messages; skip pairs already in `actionIndex`; launch children `speculative: true`. On a speculative stream, `onToolRound` returns `"abort"` → stream errors with `NEEDS_LIVE_DATA` → the cache entry shows as error; tapping it retries **non-speculative** (tools allowed). `resolveAction` on cache hit flips `speculative: false` and sets `prefetched` when it was a completed prefetch. *(store.ts)* | identical | identical |
| **Action resolve & cache** | `actionIndex` key = `"${parentId} ${message}"`. Reuse unless errored or stuck (`STALE_MS` while pending/streaming) — stuck/errored cached screens are retried **in place** (same id). **Form submissions bypass the cache both ways** (never read, never written) and append `"\n\nSubmitted form values: " + JSON.stringify(formState)` to the request. Child screens inherit parent's `appId`/`appName` (fallback `"unknown"`/`"App"`). *(store.ts `resolveAction`)* | identical | identical |
| **App home & deep-link cache** | `appHomeIndex`: appId → home screen id (grid reopen is instant). `deepLinkIndex`: key `"${appId.toLowerCase()} ${request}"` → screen id; unknown appIds get capitalized fallback name. Both apply the same reusable/retry logic. *(store.ts)* | identical | identical |
| **Deep links** | From action URLs only (no OS-level scheme registration in RN today): `genos://open?app=ID&request=TEXT` (both params required), `genos://toast?text=…` (default `"Done ✓"`), `genos://back`, `genos://home`. `genos://switcher` is **not** routed. Other cmds ignored. Non-genos URLs open externally. URL grammar: `spec/openui-lang.md` §11.4. *(GenOS.tsx)* | identical; scheme also registrable OS-wide | identical |
| **`@OS(...)` commands** | Whole-response only; regex + cleanLang exactly per `spec/openui-lang.md` §11.3. Executed once per screen id (dedupe set). The command screen is removed from the app's stack; `back` additionally pops one screen only if >1 remains; `home` → minimize animation; `switcher` → open switcher; `open` → known app by id **or name** (lower-cased) else `summonApp(arg)`. `osCommand` screens never trigger prefetch. *(store.ts `parseOsCommand`+`onDone`, GenOS.tsx effect)* | identical | identical |
| **Command routing (ask bar / chips)** | Input trimmed; lower-cased with trailing `[.!?,]+` stripped for matching. Order: (1) `^(go \|navigate \|take me )?back$` or `previous screen` → back; (2) `^(go \|take me \|go to )?home( screen)?$` → home; (3) `^close( this\| the)? app$` → end session (≠ home/minimize); (4) `^(open \|show )?(the )?(app )?(switcher\|recent apps)$` → switcher; (5) `^(?:open\|launch\|switch to\|go to)\s+(.+)$` → known app whose lower-cased name is **contained** in the remainder — also fires without the verb when no app is active and the whole utterance contains an app name; (6) app active → `resolveAction(topId, originalText)` push; (7) else summon: name = text (ellipsized at 24 chars + `…`), request = `Open the perfect app screen for this request: "<text>". Invent a polished, realistic screen that fulfils it.` *(GenOS.tsx `routeCommand`)* | identical | identical |
| **Action-event guards** | While the top screen is generating, taps toast `"Still materializing - try again in a second"` (never silently dropped). Navigation-shaped model messages are intercepted: home-ish regex `genos\s*home\|all (your \|the )?apps\|app (list\|grid\|drawer\|launcher)\|main menu` and back regex `^(go \|return \|navigate )?back( to( the)? previous( screen)?)?$`. *(GenOS.tsx `handleAction`)* | identical | identical |
| **Summoned apps** | Any free-text request → `summonApp`: id `summon-<slug>` (lower-case, non-alphanumeric runs → `-`), emoji `✨`, tile `#5e5ce6→#bf5af2`, request template above. Renamed once from the first screen's first `CardHeader("…")` (regex `CardHeader\(\s*"((?:\\.|[^"\\])*)"` on cleaned content) — only while the stack depth is exactly 1. *(apps.ts, GenOS.tsx)* | identical | identical |
| **Form submission** | Renderer form state: values wrapped `{value, componentType}`, nested under the Form's `name`; Button inside a Form dispatches with that `formName` → `formState = {[formName]: {...}}`; standalone taps (ListItem etc.) carry the whole store snapshot. Non-empty formState → fresh generation (no cache) with the JSON appendix. Seed values (`value` prop / Slider `defaultValue`) fill empty fields only after streaming ends. *(react-lang useOpenUIState, ui/shared/forms.ts, store.ts)* | identical | identical |
| **Sessions / back semantics** | Per-app screen stacks (`sessions[appId]`), duplicate-top push guard; `launch` reuses existing session else `openApp`; switching apps auto-minimizes the previous one; Home minimizes (360 ms shrink-to-icon, re-entrancy-guarded) and only apps sent home show on the grid; Switcher lists `recentOrder ∩ live sessions`; close ends the session (drops stack, recent, minimized). Android hardware back: switcher-open → close switcher; stack>1 → back; else → home. One-time gesture hint (6 s) on first app open. *(GenOS.tsx)* | swipe-back + chrome | predictive back + chrome |
| **Screen lifecycle / status** | `Screen` fields & statuses per plan §4 (verified exact). `append()` flips status to `streaming` and clears `searching`; `onToolRound` (non-speculative) resets `content:""`, `status:"pending"`, `searching:true` → shell pill shows `"searching the web…"` vs `"materializing…"`. Done: `genMs` = rounded wall-clock, `truncated`, `osCommand`, then prefetch (unless osCommand). Retry resets content/error/flags, `speculative:false`. Superseded streams (retry replaced the AbortController) are ignored via a staleness closure. *(store.ts)* | identical | identical |
| **Telemetry** | Exactly one best-effort POST on startup: `{POSTHOG_HOST}/i/v0/e/` = `https://us.i.posthog.com`, event `appless_app_launched`, `properties: {$lib: "appless-native", platform}`, write-only key `phc_3OLW…` (committed). Opt-out: `EXPO_PUBLIC_POSTHOG_DISABLED=1` or `DO_NOT_TRACK=1` (also accepts `true`, case-insensitive). Stable anonymous `distinct_id` in SecureStore/localStorage key `appless.analytics-id`; UUID fallback `anon-<ts>-<rand>`. Failures swallowed. *(telemetry.ts)* | port 1:1 | port 1:1 |
| **Renderer host contract** | `Renderer(response: cleanLang(content), library, isStreaming, onAction)`; skeleton until content non-empty; error state → message + Retry (`retryScreen`); gradient background; status pill bottom-center while generating. *(GenOS.tsx)* | SwiftUI host | Compose host |

## Corrections & clarifications vs the plan document

1. **The parser does not live in `@openuidev/react-lang` itself** (plan §1 wording):
   tokenizer/parser/materializer/evaluator live in its dependency
   **`@openuidev/lang-core` (0.1.2 installed, `^0.1.1` declared)**. `react-lang`
   contributes the React Renderer, hooks, and library/prompt builders. Consequently
   the repo **patch does not alter parsing at all** — it only hardens the React error
   boundary for RN streaming and removes DOM-only wrappers (see
   `spec/openui-lang.md` §14). Fixture generation may import lang-core directly.
2. **`genos://switcher` is not a supported deep link** — only `open`, `toast`,
   `back`, `home` are routed; the switcher is reachable via `@OS(switcher)` and
   typed/spoken commands only.
3. **Buttons without an Action are live** (they send their label as a
   `continue_conversation`), but **ListItems without an action are inert** — the
   plan's UI table should not assume symmetric behavior.
4. **`$binding` two-way binding is nominal**: the contract never marks props
   `reactive()`, so `$var` in a `value` slot resolves to the declared state default
   (seed) and real editing state flows through the form-state store
   (`{value, componentType}` wrappers). Port the seed behavior, not a live binding.
5. **Prefetch quota abort surfaces as an errored cache entry** whose retry-on-tap is
   what "regenerates with tools" — there is no special `NEEDS_LIVE_DATA` UI state,
   just the generic error screen (message `"needs live data"`).
6. **Truncation (`finish_reason: "length"`)** sets `Screen.truncated` but the RN
   shell currently renders no special UI for it — parity ports need only carry the
   flag.
7. Plan §4 lists `KeyStatus` under config.ts — verified, incl. the hydration race
   rule (late-arriving persisted key never overwrites a freshly entered one).
8. The **50 ms flush** batches only subscriber notifications; `screenStore.get()`
   always sees the latest content synchronously (onDone/parseOsCommand read fresh
   content). Native stores must preserve this read-your-writes property.
