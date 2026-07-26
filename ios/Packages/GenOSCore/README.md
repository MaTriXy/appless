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
the condition under which it becomes observable. Everything not listed here is
intended to be behaviorally identical to RN, and is pinned by the suite —
several entries below are byte-pinned against `node` output.

1. **Lone surrogates become U+FFFD at parse time**
   (`JSONValue.swift`, `JSONParser.parseString`; `JSRegex.swift`, `jsSlice`,
   `jsDecodeURIComponent`). `JSON.parse` ACCEPTS an unpaired `\uXXXX`
   surrogate escape and the JS string carries the lone UTF-16 unit, which
   degrades to U+FFFD only when the string is later UTF-8-encoded. A Swift
   `String` cannot hold a lone surrogate at all, so the port substitutes
   U+FFFD immediately. The NET observable result matches RN wherever the
   string is UTF-8-encoded before use (HTTP body, JSON re-stringify), which is
   every path in this package.

   *Changed 2026-07: this used to REJECT the whole document instead.* That was
   strictly worse than the divergence it avoided — `StreamClient` skips any
   chunk it cannot parse, so one bad scalar silently dropped an ENTIRE content
   delta while RN kept the delta and lost only that character. Pinned by
   `JSParityTests.loneSurrogateEscapesBecomeReplacementNotChunkLoss` and
   `StreamClientTests.loneSurrogateDeltaIsDeliveredNotDropped`.

   The Kotlin sibling has no divergence here (a JVM `String` holds the unpaired
   unit), so this is a permanent, documented three-way asymmetry in the
   INTERMEDIATE value — not in what reaches the wire.

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

4. **`String()` coercion of a non-string tool argument**
   (`JSRegex.swift`, `jsStringCoerce`). Arrays and objects serialize to JSON
   text where RN's `String()` would give `"1,2"` / `"[object Object]"`. The
   only call site is `args.query`, where a non-string never survives the
   non-empty check.

### Resolved — no longer deviations

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
