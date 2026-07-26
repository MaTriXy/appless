# genos-core (Kotlin/JVM)

Kotlin port of the React Native GenOS core layer (`src/genos/`): SSE streaming +
the tool-calling loop, the screen store, the navigation/prefetch controller,
the BYOK key gate, the JS-primitive helpers, the Exa/Unsplash tools and
telemetry.

- RN reference: `src/genos/store.ts`, `src/genos/stream.ts`, `src/genos/tools/`
- Swift sibling (same structure, same quirks): `ios/Packages/GenOSCore`

Run the suite:

```sh
cd android && ./gradlew :genos-core:test --console=plain
```

Deliberately a PURE Kotlin/JVM library (no Android dependency), so the whole
behavioral suite runs headlessly on any JDK 21.

## KNOWN-DEVIATIONS

Divergences from the RN reference that are deliberate and permanent. A JVM
`String` is a UTF-16 code-unit sequence exactly like a JS string, and
`LinkedHashMap` is insertion-ordered exactly like a JS object, so this port has
far fewer of them than the Swift sibling. Everything not listed here is
intended to be behaviorally identical to RN and is pinned by the suite.

1. **`Screen.genMs` is a clamped `Int`, not an unbounded JS Number**
   (`Controller.kt`, `jsRoundToInt`). RN stores `Math.round(...)` as a JS
   Number, which is unbounded and admits NaN. Both ports store an `Int` and
   CLAMP identically: NaN maps to 0, out-of-range magnitudes to
   `Int.MIN_VALUE`/`Int.MAX_VALUE`. `roundToInt()` is deliberately NOT used —
   it throws `IllegalArgumentException` on NaN and saturates silently, which is
   how the two ports drifted apart in the first place. Only reachable when the
   clock runs backwards or jumps by more than ~2^31 ms.

2. **Tool execution is sequential, not `Promise.all`.** RN executes a round's
   tool calls concurrently. Outputs are collected in call order either way and
   tool messages are appended by index, so ordering and content are identical;
   only wall-clock overlap differs.

3. **`String()` coercion of a non-string tool argument**
   (`JsRegex.kt`, `jsStringCoerce`). Arrays and objects serialize to JSON text
   where RN's `String()` would give `"1,2"` / `"[object Object]"`. The only
   call site is `args.query`, where a non-string never survives the non-empty
   check.

4. **`jsEncodeURIComponent` on an unpaired surrogate.** JS throws `URIError`;
   `String.toByteArray(UTF_8)` substitutes `?`. Unreachable at the call sites —
   the only caller feeds it a string already sanitized to `[a-zA-Z0-9, -]`.

## JVM-vs-JS notes (not deviations, but load-bearing)

- **Lone surrogates are preserved end-to-end.** `JSON.parse` accepts an
  unpaired `\uXXXX` escape and this port keeps the unpaired unit verbatim,
  exactly like RN. The Swift sibling cannot (a Swift `String` cannot hold one)
  and substitutes U+FFFD at parse time; see its README's KNOWN-DEVIATIONS #1.
  This is a permanent, documented asymmetry in the INTERMEDIATE value.

  One consequence to be aware of when comparing the two ports: the JVM's UTF-8
  encoder substitutes `?` for an unpaired surrogate, whereas node/WHATWG
  substitutes U+FFFD. Neither port currently UTF-8-encodes a delta carrying an
  unpaired surrogate before the model sees it (deltas are accumulated as
  `String`), so this is not observable today — but a future path that does
  encode one would diverge from RN here, not at parse time.

- **Object key order is free.** `JsonValue.Obj` wraps a `LinkedHashMap` and
  `stringified()` applies `OrdinaryOwnPropertyKeys` (canonical array-index keys
  first in ascending numeric order, then insertion order) at every depth. The
  Swift port needed a purpose-built `JSONObject` to reach the same place; there
  is no `keyOrder` hint in either port any more.
