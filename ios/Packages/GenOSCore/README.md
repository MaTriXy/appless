# GenOSCore (Swift)

Swift port of the React Native GenOS core layer (`src/genos/`): SSE streaming +
the tool-calling loop, the screen store, the navigation/prefetch controller,
the BYOK key gate, the JS-primitive helpers, the Exa/Unsplash tools and
telemetry.

- RN reference: `src/genos/store.ts`, `src/genos/stream.ts`, `src/genos/tools/`
- Kotlin sibling (same structure, same quirks): `android/genos-core`

Run the suite:

```sh
export PATH=/opt/swift/usr/bin:$PATH
cd ios/Packages/GenOSCore && swift test
```

## KNOWN-DEVIATIONS

Divergences from the RN reference that are deliberate and permanent, each with
the condition under which it becomes observable.

**What is and is not claimed.** This list is intended to be exhaustive for the
behavior the suite exercises, and the suite is the evidence — not this
paragraph. It is NOT a claim that everything unlisted is identical to RN: the
previous wording ("Everything not listed here is intended to be behaviorally
identical to RN, and is pinned by the suite") was falsified five different ways
in one review — the `tool_calls[].index` narrowing, non-string `error.message`
coercion, non-string `delta.content` coercion, the cancel/completion race, and
`String()` of a non-string tool argument were all divergent and none were
listed. Four of those are now fixed and the fifth is item 4 below. Where a
claim below is byte-level, it names the `node` command that produced the bytes.

1. **Lone surrogates become U+FFFD at parse time, and go on the wire as U+FFFD
   rather than as RN's escape** (`JSONValue.swift`, `JSONParser.parseString`;
   `JSRegex.swift`, `jsSlice`, `jsDecodeURIComponent`). `JSON.parse` ACCEPTS an
   unpaired `\uXXXX` surrogate escape and the JS string carries the lone UTF-16
   unit. A Swift `String` cannot hold a lone surrogate at all, so the port
   substitutes U+FFFD immediately.

   This IS observable, contrary to what this entry used to claim ("the NET
   observable result matches RN wherever the string is UTF-8-encoded before
   use, which is every path in this package"). ES2019 well-formed
   `JSON.stringify` **escapes** a lone surrogate instead of encoding it, so RN
   never UTF-8-encodes one at all:

   ```sh
   $ node -e 'console.log(Buffer.from(JSON.stringify("pre\ud83dpost")).toString("hex"))'
   227072655c7564383364706f737422        # "pre\ud83dpost"
   ```

   `StreamClient` UTF-8-encodes the accumulated content as the assistant replay
   message on every tool round, so a round-2 body carries `ef bf bd` where RN
   sends the six ASCII bytes `\ud83d`. There is no fix available inside a Swift
   `String`; the actual bytes are pinned by
   `DocumentedDivergenceTests.loneSurrogateWireBytesDivergeFromRNAndAreDocumented`
   so the divergence stays visible.

   *Changed 2026-07: this used to REJECT the whole document instead.* That was
   strictly worse than the divergence it avoided — `StreamClient` skips any
   chunk it cannot parse, so one bad scalar silently dropped an ENTIRE content
   delta while RN kept the delta and lost only that character. Pinned by
   `JSParityTests.loneSurrogateEscapesBecomeReplacementNotChunkLoss` and
   `StreamClientTests.loneSurrogateDeltaIsDeliveredNotDropped`.

   The Kotlin sibling has NO divergence here any more: a JVM `String` holds the
   unpaired unit, and its encoder now implements well-formed `JSON.stringify`,
   so it reproduces RN's bytes exactly. This is therefore a Swift-only
   divergence, in the intermediate value AND on the wire.

2. **`Screen.genMs` is a clamped `Int`, not an unbounded JS Number**
   (`Controller.swift`, `jsRoundToInt`). RN stores `Math.round(...)` as a JS
   Number, which is unbounded and admits NaN. Both ports store an `Int` and
   CLAMP identically: NaN maps to 0, out-of-range magnitudes to
   `Int.min`/`Int.max`. The rounding itself is exact JS `Math.round`
   (ties toward +INFINITY, so -0.5 → -0 and -2.5 → -2). Only reachable when
   the clock runs backwards or jumps by more than ~2^63 ms.

3. **Tool execution is sequential, not `Promise.all`.** RN executes a round's
   tool calls concurrently. Outputs are collected in call order either way and
   tool messages are appended by index, so ordering and content are identical;
   only wall-clock overlap differs.

4. **`String()` of an object carrying a non-callable `toString`**
   (`JSRegex.swift`, `jsStringCoerce`). `String(JSON.parse('{"toString":1}'))`
   THROWS `TypeError: Cannot convert object to primitive value` in JS, because
   ToPrimitive finds a non-callable `toString` and then a non-callable
   `valueOf`. Both ports return `"[object Object]"` instead. Reachable only
   through a model-supplied `args.query` whose value is an object with exactly
   that key; RN would surface the TypeError through `onError`.

5. **Cancellation suppresses `onDelta`/`onDone`; RN's success path does not.**
   RN calls `onDone` unconditionally on the success path and only checks
   `signal.aborted` in the `catch`. Both ports also gate `onDelta` and `onDone`
   on `token.isCancelled`. Aborting during a delta with a transport that
   ignores the signal:

   | | sequence |
   |---|---|
   | RN | `delta:a`, `delta:b`, `done{truncated:false,dropped:false}` |
   | both ports | `delta:a` |

   Not fixed, deliberately: in production `cancel()` always races a real
   transport that aborts the request, so RN takes the silent `catch` path
   anyway, and the controller's `stale()` check — which both runtimes have — is
   the guard that actually matters. Removing the port guard would trade a
   narrow, benign divergence for the risk of patching a cancelled screen to
   `.done`. Pinned both ways (cancelled and not) by
   `DocumentedDivergenceTests.cancelSuppressesLaterHandlersUnlikeRNSuccessPath`.

6. **Non-string `tool_calls[].id` and `function.name` are dropped.** RN assigns
   the RAW JSON value (`if (tc.id) cur.id = tc.id`), so `{"id":42,"function":
   {"name":7}}` reaches the wire as `"id":42,"function":{"name":7}` — numbers,
   not strings. Both ports type these fields as `String` and ignore a
   non-string, leaving `""`. `arguments` is NOT affected: RN concatenates it
   onto a string, so it coerces, and both ports now reproduce that
   (`"arguments":9` → `"9"`).

7. **A non-number `tool_calls[].index` keys to 0.** RN keys its accumulator
   `Map` by the raw value, so the STRING `"0"` and the NUMBER `0` are two
   distinct calls; both ports read the numeric value only and fall back to 0,
   merging them. Verified against the RN oracle:

   | `index` pair | RN | both ports |
   |---|---|---|
   | `"0"` / `0` | 2 calls | 1 merged call |
   | `true` / `0` | 2 calls | 1 merged call |
   | `null` / `0` | 1 call | 1 call |

   Every NUMERIC index — fractional, negative, `-0`, `1e999` → `Infinity` — is
   now exact (deviation removed; see below).

### Resolved — no longer deviations

- **`replacingFirst` corrupted strings with a combining mark after a
  delimiter.** `NSString.replacingCharacters(in:with:)` rounds an `NSRange` to
  GRAPHEME-CLUSTER boundaries on swift-corelibs-foundation, so any regex match
  ENDING inside a grapheme under-deleted. `cleanLang("```" + U+0301 + "\nx")`
  returned `` "`" + U+0301 + "\nx" `` — one backtick of the opening fence
  survived — where RN and Kotlin return `U+0301 + "\nx"`; and
  `replace(/b/, "X")` on `"ab" + U+0301 + "c"` INSERTED the template while
  deleting nothing. `cleanLang` runs on every model-generated screen. Now
  spliced on UTF-16 code units, the same technique `jsSlice`/`jsUTF16Index`
  already used. `replacingAll` (`stringByReplacingMatches`) was audited and is
  NOT affected — it splices at the UTF-16 level itself. Covered on both sides
  of both fences plus two properties over the class in `JSRegexSpliceTests`.

- **`tool_calls[].index` narrowed to `Int`, merging distinct calls.** RN keys a
  JS `Map` by the raw Number, so `3.2` and `3.7` are two calls; narrowing
  merged pairs into one and concatenated both `arguments` blobs into
  `{"query":"x"}{"query":"y"}`, which fails `JSON.parse` and degrades to
  `args={}` — one tool round instead of two, and a round-2 body that differed
  from RN's bytes. The accumulator is now keyed by the raw `Double`, with `-0`
  normalized to `+0` to match `Map`'s SameValueZero. Both ports fixed
  identically.

- **Non-string `chunk.error.message` and `delta.content` were dropped.** RN's
  guards are truthy and its consumers coerce (`new Error(msg)`, `content +=`),
  so `{"message":42}` surfaces `"42"` and `"content":5` forwards `"5"`. Both
  ports read only a string, collapsing every such error to the generic
  `"stream error"` and silently shortening the assistant replay message.

- **A truthy non-string `finish_reason` was treated as a dropped stream.** RN's
  `dropped` tests the RAW value for truthiness, so `"finish_reason":42` means
  NOT dropped; the ports stored only strings, so with no content they threw
  `"stream dropped before any content arrived"` where RN called `onDone`.

- **`String()` coercion of a non-string tool argument.** `jsStringCoerce`
  returned JSON text for arrays and objects — `[1,2]` as `"[1,2]"` where JS
  gives `"1,2"` — and this list used to excuse it with "the only call site is
  `args.query`, where a non-string never survives the non-empty check". That
  was false: `"1,2"` is non-empty, so a model-supplied array `query` reached
  the Exa request body with different bytes in each runtime. Now a real
  ECMAScript ToString (`Array.prototype.join(",")`, `"[object Object]"`,
  `Infinity`/`NaN` for non-finite numbers), pinned against a 30-row `node`
  table in `JSToStringTests`.

- **`openDeepLink` fallback name.** The port used to capitalize the first
  GRAPHEME (`prefix(1).uppercased()`), which uppercases an astral first
  character; RN's `appId.charAt(0).toUpperCase()` takes one UTF-16 CODE UNIT,
  so a lone high surrogate has no case mapping and the id is unchanged
  (`"𐐨eseret"` stays `"𐐨eseret"`). Now ported as `jsCapitalizeFirst`, which
  runs the UTF-16 spelling without ever materializing a lone surrogate as a
  Swift `String`. Matches RN and Kotlin.

- **Object key order.** `JSONValue.stringified` used to take a single flat
  `keyOrder` hint and sort every key the hint did not name, so nested objects
  (form state is three levels deep) were alphabetized and adding one key
  anywhere could silently reorder the wire bytes. Replaced by `JSONObject`, an
  insertion-ordered object applying `OrdinaryOwnPropertyKeys` at every depth
  (canonical array-index keys first, ascending numerically; then insertion
  order).

- **`decodeURIComponent`.** `removingPercentEncoding` swallowed a decoded
  LEADING BOM (`"%EF%BB%BF"` → `""`) while keeping a mid-string one. Replaced
  by a hand-rolled port of the spec's `Decode`, shared line-for-line with the
  Kotlin sibling.

- **Non-`StreamError` degradation text.** `String(describing:)` leaked the
  Swift type-and-case spelling into `Screen.error` and into the tool `ERROR:`
  string the MODEL reads. `jsErrorMessage` now extracts a bare message, using
  the same rule as the Kotlin port: the package error's message, else any
  message the error carries, else the error type's SIMPLE name.

## Concurrency

Every mutable type in this package — `ScreenStore`, `GenOSController`,
`KeyStore`, `StreamClient`, `StreamCancelToken` — is `@MainActor`, so the
single-threaded contract the RN reference relies on is enforced by the COMPILER
here. The Kotlin sibling cannot do that; it now carries a per-instance runtime
`ConfinementCheck` on `ScreenStore`, `KeyStore` and `GenOSController` (active
under `-ea`, so throughout its suite) and documents the residual gap that its
`StreamClient` invokes handlers on whatever `CoroutineScope` it is handed.
That asymmetry — compile-time here, runtime there — is permanent.
