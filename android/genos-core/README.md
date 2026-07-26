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
far fewer of them than the Swift sibling.

**What is and is not claimed.** This list is intended to be exhaustive for the
behavior the suite exercises, and the suite is the evidence — not this
paragraph. It is NOT a claim that everything unlisted is identical to RN: the
previous wording ("Everything not listed here is intended to be behaviorally
identical to RN and is pinned by the suite") was falsified five different ways
in one review — the `tool_calls[].index` narrowing, non-string `error.message`
coercion, non-string `delta.content` coercion, the cancel/completion race, and
`String()` of a non-string tool argument were all divergent and none were
listed. Four of those are now fixed and the fifth is item 3 below. Where a
claim below is byte-level, it names the `node` command that produced the bytes.

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

3. **`String()` of an object carrying a non-callable `toString`**
   (`JsRegex.kt`, `jsStringCoerce`). `String(JSON.parse('{"toString":1}'))`
   THROWS `TypeError: Cannot convert object to primitive value` in JS, because
   ToPrimitive finds a non-callable `toString` and then a non-callable
   `valueOf`. Both ports return `"[object Object]"` instead. Reachable only
   through a model-supplied `args.query` whose value is an object with exactly
   that key; RN would surface the TypeError through `onError`.

4. **`jsEncodeURIComponent` on an unpaired surrogate.** JS throws `URIError`;
   `String.toByteArray(UTF_8)` substitutes `?`. Unreachable at the call sites —
   the only caller feeds it a string already sanitized to `[a-zA-Z0-9, -]`.

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
   `DONE`. Pinned both ways (cancelled and not) by
   `WellFormedStringifyTest.cancel suppresses later handlers unlike RN's success path`.

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

8. **The single-threaded contract is a RUNTIME check here, a COMPILE-TIME one
   in Swift.** See [Concurrency](#concurrency).

### Resolved — no longer deviations

- **`tool_calls[].index` narrowed to `Int`, merging distinct calls.** RN keys a
  JS `Map` by the raw Number, so `3.2` and `3.7` are two calls; `toInt()`
  TRUNCATED them onto one key and concatenated both `arguments` blobs into
  `{"query":"x"}{"query":"y"}`, which fails `JSON.parse` and degrades to
  `args={}` — one tool round instead of two, and a round-2 body that differed
  from RN's bytes. The accumulator is now keyed by the raw `Double`, with
  `-0.0` normalized to `+0.0`: a JS `Map` key uses SameValueZero, under which
  `-0` and `0` are the SAME key, while boxed `java.lang.Double.equals`
  separates them. Both ports fixed identically.

- **Unpaired surrogates went on the wire as `?`.** ES2019 well-formed
  `JSON.stringify` ESCAPES a lone surrogate rather than encoding it:

  ```sh
  $ node -e 'console.log(Buffer.from(JSON.stringify("pre\ud83dpost")).toString("hex"))'
  227072655c7564383364706f737422        # "pre\ud83dpost"
  ```

  `encodeJsonString` emitted the raw unit, so `toByteArray(UTF_8)` substituted
  `?` (0x3F) and a round-2 body diverged from RN's. This section used to say
  "Neither port currently UTF-8-encodes a delta carrying an unpaired surrogate
  before the model sees it, so this is not observable today" — false:
  `StreamClient` UTF-8-encodes the accumulated content as the assistant replay
  message on EVERY tool round. `encodeJsonString` now implements well-formed
  stringify, so this port reproduces RN's bytes exactly; the Swift sibling
  cannot and documents the residual.

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
  table in `JsParityTest`.

## Concurrency

`GenOSClock`'s KDoc has always said implementations are "single-threaded by
contract", and `ScreenStore`, `KeyStore` and `GenOSController` all depend on it
— bare `LinkedHashMap`s, an unsynchronized flush timer, unguarded `key` and
`inflight` mutation. None of them asserted anything, so handing the library a
multi-threaded dispatcher produced silent data races.

Each of the three now holds a per-instance `ConfinementCheck` (`Confinement.kt`)
that records the first thread to touch it and throws `IllegalStateException` on
any other. It is active whenever JVM assertions are (`GenOSDebug
.threadChecksEnabled` defaults to `-ea`, which Gradle's `Test` task sets), so
the entire behavioral suite runs under it; `GenOSDebug.threadChecksEnabled` is
settable for a host that needs it off.

Two limits, deliberate and permanent:

- It is a RUNTIME check. The Swift sibling marks the same types `@MainActor`,
  so there the confinement is a COMPILE error. This asymmetry cannot be closed
  on the JVM.
- `StreamClient` is NOT checked: it invokes handlers on whatever
  `CoroutineScope` the caller hands it, by design (the scope IS the seam). The
  caller is responsible for confining that scope to the same dispatcher as the
  store it ultimately drives.

## JVM-vs-JS notes (not deviations, but load-bearing)

- **Lone surrogates are preserved end-to-end, INCLUDING on the wire.**
  `JSON.parse` accepts an unpaired `\uXXXX` escape and this port keeps the
  unpaired unit verbatim, exactly like RN — and `encodeJsonString` now
  implements ES2019 well-formed `JSON.stringify`, emitting `\udXXX` for an
  unpaired unit and passing a valid pair through as its astral character. So a
  request body carrying a lone surrogate is byte-identical to RN's.

  The JVM's UTF-8 encoder would substitute `?` for an unpaired surrogate, which
  is exactly what used to reach the wire; escaping before encoding is what
  removes that. The Swift sibling cannot hold the unit at all and substitutes
  U+FFFD at parse time, so it emits `ef bf bd` where RN and this port emit
  `\ud83d`; see its README's KNOWN-DEVIATIONS #1. That is now a Swift-only
  divergence.

- **Object key order is free.** `JsonValue.Obj` wraps a `LinkedHashMap` and
  `stringified()` applies `OrdinaryOwnPropertyKeys` (canonical array-index keys
  first in ascending numeric order, then insertion order) at every depth. The
  Swift port needed a purpose-built `JSONObject` to reach the same place; there
  is no `keyOrder` hint in either port any more.
