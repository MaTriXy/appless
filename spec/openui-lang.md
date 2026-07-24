# openui-lang — Normative Language & Runtime Specification

**Status:** Layer-0 normative spec for the AppLess native migration (plan §3.1).
**Audience:** implementers of the Swift (`ios/Packages/OpenUILang`) and Kotlin
(`android/openui-lang`) clean-room parsers/runtimes.

This document describes the **actual behavior** of the reference implementation, not the
idealized rules in the model-facing system prompt. The reference implementation is:

- Parser & runtime: **`@openuidev/lang-core` 0.1.2** (`dist/parser/*`, `dist/runtime/*`),
  installed as the dependency of **`@openuidev/react-lang` 0.1.5**.
- React adapter: `@openuidev/react-lang` 0.1.5 **plus the repo patch**
  `patches/@openuidev+react-lang+0.1.5.patch` (the patch touches only
  `dist/Renderer.js` — the React error boundary and DOM wrappers — it does **not**
  change the parser; see §14).
- App-side helpers: `src/genos/store.ts` (`cleanLang`, `extractActions`,
  `parseOsCommand`), `src/genos/GenOS.tsx` (`parseGenosUrl`, action routing),
  `src/genos/tools/images.ts` (`parseImgUrl`).

Every claim that comes from parser/runtime source or empirical execution (rather than
the system prompt) carries a `Source:` footnote. Behaviors marked **[verified]** were
executed against the real parser with the real GenOS component schema
(`ui/contract.tsx` replicated 1:1) during authoring of this spec.

Terminology: **MUST**-level statements describe behavior both native parsers must
reproduce byte-for-byte at the level of the resolved tree; notes marked *hazard* are
reference-implementation quirks that must be reproduced (they are observable).

---

## 1. Processing pipeline

A model response travels through these stages, in order:

```
raw model text
  → (app)   parseOsCommand()          — whole-response @OS(...) detection (§12)
  → (app)   cleanLang()               — markdown-fence strip (§11.1)
  → (parser) streaming parse:
        preprocess: stripFences → stripComments → trim        (§4)
        autoClose (pending tail only)                          (§10.2)
        tokenize → split into statements → parse expressions   (§5–§7)
        materialize from entry statement (schema-aware)        (§8)
  → (runtime) evaluateElementProps    — resolve runtime AST in props (§9)
  → (renderer) per-component views; taps → triggerAction → ActionEvent (§9.4)
```

The app feeds `cleanLang(screen.content)` to the Renderer on **every** store flush
(≤ once per 50 ms during streaming) with `isStreaming = (status is pending|streaming)`.
The Renderer keeps one incremental stream parser per library instance and calls
`sp.set(fullText)` — full text, not deltas (§10.4).
*Source: GenOS.tsx render; react-lang `hooks/useOpenUIState.js`.*

## 2. Program structure

A program is a sequence of **statements**, one per line:

```
identifier = Expression
```

- `root` is the conventional entry point; entry selection when `root` is absent is
  defined in §8.1.
- Statements are separated by **newlines at bracket-depth 0** (newlines inside
  `()`, `[]`, `{}` — and inside an open ternary — do not split; §6).
- Lines that do not match `identifier = …` (no identifier token, or no `=` after it)
  are **silently skipped** — the token scanner discards tokens up to the next
  newline. There is no error for this. **[verified]**
  *Source: lang-core `parser/statements.js` `split()`.*
- The statement identifier may be a lowercase identifier (`Ident`), a PascalCase
  name (`Type` — `Header = CardHeader("x")` is legal and referenceable **[verified]**),
  or a state variable (`$name`, including the `$` in the statement id).
  *Source: `statements.js` (accepts T.Ident, T.Type, T.StateVar).*
- Blank lines are skipped. `\r` is treated as horizontal whitespace, so CRLF input
  parses identically to LF input. **[verified]**
  *Source: `lexer.js` whitespace loop.*

### 2.1 Statement classification

Each parsed statement is classified at parse time:
*Source: `parser/parser.js` `classifyStatement()`.*

| Form | Kind | Notes |
|---|---|---|
| `x = Query(...)` | query | Reserved call — **unused by AppLess**; do not implement runtime tool queries for parity, but the parser must classify it (an *inline* `Query(...)`/`Mutation(...)` used as a value is an `inline-reserved` error and materializes to null). |
| `x = Mutation(...)` | mutation | Same as above. |
| `$x = Expr` | state declaration | Default value materialized immediately (§9.5). Checked **after** Query/Mutation. |
| anything else | value declaration | The normal case. |

## 3. Lexical grammar

Tokenizer: single pass, no backtracking. Horizontal whitespace (space, tab, `\r`)
separates tokens; `\n` is a significant `Newline` token.
*Source: lang-core `parser/lexer.js` (whole section).*

### 3.1 Tokens

| Token | Text |
|---|---|
| punctuation | `(` `)` `[` `]` `{` `}` `,` `:` |
| operators | `=` `==` `!` `!=` `>` `>=` `<` `<=` `&&` `\|\|` `.` `?` `+` `-` `*` `/` `%` |
| literals | string, number, `true`, `false`, `null` |
| identifiers | `Ident` (first char `a-z` or `_`), `Type` (first char `A-Z`), rest `[A-Za-z0-9_]*` |
| state var | `$` + identifier (token value **includes** the `$`) |
| builtin call | `@` + identifier (token value **excludes** the `@`) |

Hazards that MUST be reproduced:

- A single `&` lexes as `&&`; a single `|` lexes as `||`.
  *Source: `lexer.js` And/Or branches.*
- Any character not matched by the above (`#` outside a comment context that
  survived comment-stripping, emoji, `;`, backticks, stray `"`-less text…) is
  **silently skipped**. *Source: `lexer.js` final `i++`.*
- A word beginning `A-Z` is a `Type`; beginning `a-z` or `_` is an `Ident`.
  `true`/`false`/`null` are keywords only in exact lowercase.

### 3.2 Double-quoted strings

`"..."` — scan to the closing quote; a backslash skips the next character during the
scan (so `\"` does not terminate). The raw slice **including quotes** is then handed to
a JSON string parser:

- If the string was closed: parse as a JSON string. The escape set is therefore
  exactly JSON's: `\"` `\\` `\/` `\b` `\f` `\n` `\r` `\t` `\uXXXX`.
- If the string was **unclosed** (streaming): append `"` and parse what is there.
- If JSON parsing **fails** (any non-JSON escape such as `\x`, `\'`, or a malformed
  `\u` sequence): fall back to the raw text with the leading/trailing quote characters
  stripped (regex `/^"|"$/g`) and **no unescaping at all** — one invalid escape means
  *every* escape in that string stays literal. **[verified]**:
  `"a\"b\\c\nd\te\u0041 \x!"` yields the literal text `a\"b\\c\nd\te\u0041 \x!`.

Note the literal newline character cannot appear inside a JSON string, but the raw
scan does not stop at `\n` — a string containing a real newline fails JSON parsing and
takes the raw-fallback path (with the newline preserved).
*Source: `lexer.js` double-quote branch.*

### 3.3 Single-quoted strings

`'...'` is also accepted (LLM tolerance). Escapes handled: `\'`, `\\`, `\n`, `\t`;
any other `\c` passes `c` through. Unclosed single-quoted strings at EOF just end the
token (no error). **[verified]** `'single \'quoted\' text'` → `single 'quoted' text`.
*Source: `lexer.js` single-quote branch.*

The system prompt only ever teaches double quotes; single quotes exist purely for
robustness. `parseOsCommand` and `extractActions` (app side) do **not** accept single
quotes (§11–§12).

### 3.4 Numbers

Grammar: `-? [0-9]+ ( "." [0-9]+ )? ( [eE] [+-]? [0-9]+ )?`

- The decimal point is consumed **only if a digit follows it** (`1.` is number `1`
  followed by a `.` token).
- Leading `-` is a negative-number prefix only when the **previous token** is not a
  value (value tokens: Num, Str, Ident, Type, RParen, RBrack, True, False, Null,
  StateVar, BuiltinCall) **and** a digit follows. Otherwise `-` is the minus operator.
- Conversion is JavaScript `+slice` semantics — `12.5e1` → `125`. **[verified]**
*Source: `lexer.js` minus/number branches.*

### 3.5 Comments

`//` and `#` line comments are stripped **before tokenizing**, line by line, outside of
string context (both `"` and `'` delimiters tracked, escape-aware). Everything from the
marker to end of line is removed, then the line is right-trimmed. **[verified]** —
trailing `// …` after a statement and whole-line `# …` comments both vanish.
*Source: lang-core `parser/parser.js` `stripComments()`.*
Streaming caveat: §10.3.

## 4. Preprocessing (`preprocess = trim ∘ stripComments ∘ stripFences ∘ trim`)

Applies to batch parses and to the *pending tail* in streaming mode (§10).
*Source: `parser/parser.js` `preprocess()`, `stripFences()`.*

`stripFences(input)` (the **parser's** fence handling — distinct from the app-level
`cleanLang`, §11.1):

1. Find each ` ``` ` opener; skip its language tag up to the newline.
2. Scan for the closing ` ``` ` **string-context-aware**: a ` ``` ` inside a
   double-quoted string does not close the fence.
3. Unclosed fence (streaming): take everything after the opener line.
4. Multiple fenced blocks: extracted and joined with `\n`.
5. No fences at all: input returned as-is.
6. Fallback: input starts with ` ``` ` but no block matched — strip the first line and
   any trailing ` ``` `.

In AppLess the app has usually already removed fences via `cleanLang`, so this is a
second, mostly-idle layer; native ports MUST still implement it because `cleanLang`
and `stripFences` differ on multi-fence inputs.

## 5. Expression grammar

Pratt parser with these binding powers (higher binds tighter):
*Source: lang-core `parser/expressions.js`.*

| Level | Operators |
|---|---|
| 9 member | `.` `[expr]` (postfix index) |
| 8 unary | `!` `-` (prefix) |
| 7 mul | `*` `/` `%` |
| 6 add | `+` `-` |
| 5 cmp | `>` `<` `>=` `<=` |
| 4 eq | `==` `!=` |
| 3 and | `&&` |
| 2 or | `\|\|` |
| 1 ternary | `?:` (right-associative) |

AST node kinds: `Str`, `Num`, `Bool`, `Null`, `Arr`, `Obj`, `Comp`, `Ref`, `StateRef`,
`RuntimeRef`, `BinOp`, `UnaryOp`, `Ternary`, `Member`, `Index`, `Assign`, `Ph`
(placeholder for unresolved refs in expression context).
*Source: `parser/ast.js`.*

Atoms and forms:

- **Component call** `TypeName(a, b, …)`: a `Type` token immediately followed by `(`.
  Args are comma-separated expressions; a missing comma is tolerated (args are read
  until `)` or EOF). Builtins named without `@` do **not** parse as calls — with the
  single exception of `Action` (`Action(...)` works without `@`). Other builtin names
  used bare (`Count(x)`) parse as `Ref("Count")` followed by junk.
- **Builtin call** `@Name(...)`: `BuiltinCall` token + `(`. `@Name` without `(`
  parses as `Ref("Name")`.
- **Reference**: bare `Ident` or `Type` (no `(`) → `Ref(name)`.
- **State ref / assignment**: `$name` → `StateRef`; `$name = expr` *in expression
  position* → `Assign` node (evaluates to a ReactiveAssign marker at runtime — not
  used by the AppLess contract).
- **Array** `[e1, e2, …]`, **Object** `{key: value, …}`. Object keys may be `Ident`,
  `Type`, string, or number tokens (numbers stringified); `$key` has its `$` stripped;
  anything else becomes key `"?"`. Duplicate keys: last wins (plain object build).
- **Grouping** `( expr )`.
- **Error recovery**: any unexpected token in prefix position is consumed and yields
  `Null`. This is why `Card([t = TextContent("24")])` produces children
  `[Ref(t) (dropped, unresolved), null, TextContent(...)]` — i.e. the component still
  renders, preceded by a stray literal `null` entry in the array, and `t` is recorded
  in `meta.unresolved`. **[verified]**

### 5.1 Named-argument corruption (colon syntax)

`ListBlock([a], header: "TODAY")` parses as args
`[Arr, Ref(header), Null(from ':'), Str("TODAY")]`. After positional mapping the
`header` prop receives the unresolved `Ref(header)` → `null`, the extra args are
ignored, and `header` lands in `meta.unresolved`. **No error is reported**; the value
is silently lost. **[verified]** `header="TODAY"` (equals form) behaves the same.
The prompt's claim "colon syntax silently breaks" is accurate in the sense that the
*named value is dropped* — the component itself still renders.

### 5.2 Multi-line ternaries

Both the statement splitter and the streaming scanner track `?`/`:` depth at bracket
level 0 and look ahead past newlines: a newline followed by `?` (or by `:` while a
ternary is open) does **not** end the statement.
*Source: `statements.js` `split()`, `parser.js` `scanNewCompleted()`.*

## 6. Statement splitting

Token stream → statements: skip newlines; expect `Ident|Type|StateVar` then `=`
(otherwise skip the line, §2); collect expression tokens until a newline at bracket
depth ≤ 0 and ternary depth ≤ 0 (with the ternary lookahead of §5.2) or EOF.
A statement with an empty expression is dropped.
*Source: `statements.js`.*

## 7. Auto-closing (streaming tolerance)

`autoClose(text)` scans the text tracking string state (both quote kinds,
escape-aware) and a bracket stack. If anything is open at the end:

- an open string is closed with its matching quote (a trailing lone `\` first gets a
  second `\` so the escape stays valid);
- open brackets are closed in reverse order (`(`→`)`, `[`→`]`, `{`→`}`);
- `wasIncomplete = true` is reported (surfaces as `meta.incomplete`, and stamps
  `partial: true` on every element materialized in that pass — §10.5).

Stray closers that do not match the top of the stack are ignored (not popped).
*Source: `statements.js` `autoClose()`.*

## 8. Reference resolution & materialization

After splitting, every statement's expression is parsed and stored in a symbol table
keyed by statement id (a `Map`). In a **batch** parse, a duplicate id overwrites —
**last definition wins** **[verified]**. (Streaming duplicates: §10.6.)

### 8.1 Entry selection

The entry statement is picked in this order **[verified]**:
*Source: `parser/parser.js` `pickEntryId()`.*

1. a statement literally named `root`;
2. a statement named exactly like the library root (`Card` for GenOS);
3. the first *component* statement whose call name equals the library root
   (i.e. any `x = Card(...)`);
4. the first component statement of any type — e.g. a program of only
   `header = CardHeader("Hi")` renders that CardHeader as the root **[verified]**;
5. the first statement id (whatever it is).

If the entry materializes to something that is not an element (e.g. `root = "hello"`),
the parse result's `root` is `null` and the host renders nothing. **[verified]**
"Component statement" excludes builtins and `Query`/`Mutation`.

### 8.2 Materialization (`materializeValue`)

Recursive lowering from the entry expression; this is where hoisting, dropping and
schema mapping happen. *Source: lang-core `parser/materialize.js`.*

- **Ref resolution**: look up the symbol table. Order of definition is irrelevant —
  forward and backward references behave identically because resolution happens after
  the full (available) input is parsed. **[verified]**
  - Unknown name → record in `meta.unresolved`, produce `null`.
  - **Cycle**: a per-path `visited` set breaks recursion; the offending inner
    reference resolves to `null`/is dropped and the name is recorded unresolved
    (outer occurrences still render — a two-statement cycle renders the chain once
    and stops **[verified]**).
  - Refs to `Query`/`Mutation` declarations become `RuntimeRef` nodes.
  - A resolved element is tagged with `statementId` = the statement that defined it.
- **Literals** → plain values. `Ph` → `null`.
- **Arrays**: elements materialized in order, with dropping rules:
  - `Ph` placeholders are dropped;
  - elements that materialized to `null` **and** originated from a `Comp` or `Ref`
    node are dropped (unresolved refs, dropped components);
  - a literal `null` element **stays** in the array. **[verified]**
- **Objects**: all entries materialized; nothing dropped.
- **Component call (catalog)**: positional args are mapped to named props using the
  library schema's **property order** (`params[i].name ← args[i]`).
  - Extra args beyond the parameter list are **ignored silently**. **[verified]**
  - Missing required props: if the schema has a default, apply it; otherwise emit a
    `missing-required` (or `null-required` if explicitly `null`) validation error and
    materialize the whole component to **null** (→ dropped from parent arrays).
    **[verified]** — this is why a half-streamed `CardHeader(` does not render until
    its `title` has at least one character (§10.7).
  - Result: `ElementNode { type:"element", typeName, props, partial, hasDynamicProps,
    statementId? }`. `hasDynamicProps` = any prop subtree contains an AST node.
- **Component call (builtin, incl. `Action`/`@ToAssistant`/`@OpenUrl`)**: preserved as
  an AST `Comp` node (args normalized); evaluated later at runtime (§9). In the raw
  parse result an action prop is therefore still an AST tree. **[verified]**
- **Unknown component**: `unknown-component` validation error; materializes to null →
  dropped from arrays. **[verified]**
- **Runtime expressions** (`BinOp`, `Ternary`, `Member`, `Index`, `StateRef`,
  `UnaryOp`, `Assign`): preserved as AST inside props (refs inside them resolved /
  inlined; catalog `Comp` nodes inside expressions get `mappedProps` for later
  evaluation).

**Unreferenced statements are silently dropped**: materialization starts at the entry
and touches only what is reachable, so any statement not (transitively) referenced by
the entry simply never appears in the tree. No diagnostic. **[verified]**

### 8.3 Required/optional props of the GenOS contract

Positional order and requiredness come from `ui/contract.tsx` zod schemas via JSON
Schema (`required` array). `.optional()` ⇒ optional. Notably **required**: `Card.children`;
`CardHeader.title`; `TextContent.text`; `TextCallout.variant`+`title`; `ListItem.title`;
`Toggle.title`+`on`; `ListBlock.items`; `KVList.rows`; `HeroStat.value`;
`StatTiles.items`; `ImageBlock.src`; `PhotoGrid.images`; `Bubbles.messages`;
`Chips.labels`; `TabItem.label`+`children`; `Tabs.items`; `MapView.placeName`;
`Series.category`+`values`; charts: `labels`+`series` (PieChart: `labels`+`values`);
`Form.name`+`buttons` (a `Form` with `null` buttons is dropped with `null-required`);
`FormControl.label`+`input`; `Input/TextArea/DatePicker/Select/Slider.name`
(+`Slider.variant`,`min`,`max`); `Buttons.buttons`; `Button.label`.
The full machine-readable contract belongs in `spec/contract/genos.schema.json`
(plan §3.3, not this file).

## 9. Runtime evaluation

`evaluateElementProps(root, ctx)` runs on every render pass over the materialized
tree, resolving remaining AST nodes in props. Per-prop exceptions are caught: the raw
value is kept and a `runtime-error` is collected.
*Source: lang-core `runtime/evaluate-tree.js`, `runtime/evaluator.js`,
`runtime/evaluate-prop.js`.*

### 9.1 Operator semantics

`toNumber`: number → itself; numeric string → number, non-numeric string → 0;
boolean → 1/0; anything else → 0.

- `+`: if either side is a string → string concatenation with `null`/`undefined`
  treated as `""`; else numeric addition (via `toNumber`).
- `-` `*`: numeric. `/` and `%`: **division by zero yields 0** (not Infinity/NaN).
- `==` `!=`: JavaScript **loose** equality (`5 == "5"` is true).
- `<` `>` `<=` `>=`: numeric after `toNumber` on both sides.
- `&&` `||`: short-circuit, return the deciding operand (JS truthiness).
- unary `!`: JS truthiness negation; unary `-`: numeric negation.
- Ternary: JS-truthy condition.
- **Member `a.b`**: null-safe (`null` → `null`). On an **array**, `.length` returns
  the count and any other field **plucks** — maps each element to `el.b ?? null`.
  This is the mechanism behind the prompt's `PieChart(data.categories, data.values)`
  idiom. **[verified]**
- **Index `a[i]`**: null-safe; arrays indexed via `toNumber(i)`, objects via
  `String(i)`.

### 9.2 Builtins

Registry (callable only with `@` prefix, except `Action`):
`Count(arr)`, `First(arr)`, `Last(arr)`, `Sum(arr)`, `Avg(arr)`, `Min(arr)`,
`Max(arr)`, `Sort(arr, field, dir?)`, `Filter(arr, field, op, value)`,
`Round(n, decimals?)`, `Abs(n)`, `Floor(n)`, `Ceil(n)`; lazy: `@Each(arr, var,
template)` (template evaluated per element with the loop variable substituted as a
literal — Action steps inside the template capture concrete values). **[verified]**
The AppLess system prompt never teaches these, but the model could emit them and they
work; native ports MUST implement at least `Each` + the arithmetic set for parity.
*Source: `parser/builtins.js`, `runtime/evaluator.js` `evaluateLazyBuiltin`.*

Non-array/degenerate inputs: `Count`→0, `First/Last`→null, `Sum/Avg/Min/Max`→0,
`Sort`→input unchanged, `Filter`→`[]`. `Sort`/`Filter` support dot-paths in `field`
and numeric-aware comparison.

### 9.3 Actions — parse & evaluation

Action expression names: `Action` (container) and steps `Run`, `ToAssistant`,
`OpenUrl`, `Set`, `Reset` (steps written with `@` prefix inside the array). Runtime
step type strings: *Source: `parser/builtins.js` `ACTION_STEPS`.*

| Step | Evaluates to |
|---|---|
| `Action([s1, s2, …])` | `ActionPlan { steps: [...] }` — the arg is evaluated; non-object / null entries and entries without a `type` field are filtered out |
| `@ToAssistant(msg, ctx?)` | `{ type: "continue_conversation", message: String(msg ?? ""), context?: String }` |
| `@OpenUrl(url)` | `{ type: "open_url", url: String(url ?? "") }` |
| `@Set($var, valueExpr)` | `{ type: "set", target, valueAST }` — value evaluated at click time |
| `@Reset($a, $b, …)` | `{ type: "reset", targets }` |
| `@Run(ref)` | `{ type: "run", statementId, refType }` — Query/Mutation only; unused in AppLess |

An action may be assigned to a variable and referenced (`onGo = Action([...])`;
`Button("Go", onGo)`) — the ref inlines to the same AST. **[verified]**

`ActionPlan`/`ActionStep` objects (`{steps: [...]}` or `{type, valueAST}`) are
**preserved as-is** by prop evaluation (deferred click-time execution).
*Source: `runtime/evaluate-prop.js`.*

### 9.4 triggerAction and the ActionEvent

`triggerAction(userMessage, formName?, action?)` (react-lang context):
*Source: react-lang `hooks/useOpenUIState.js`.*

1. Build `formPayload`: with a `formName` and existing form data →
   `{ [formName]: { field: { value, componentType }, … } }`; otherwise the **entire
   state-store snapshot** (all forms and `$bindings`).
2. If `action` is an ActionPlan, execute steps **in order**:
   - `continue_conversation` → dispatch
     `onAction({ type: "continue_conversation", params: (context ? {context} : {}),
     humanFriendlyMessage: step.message, formState: formPayload, formName })`
   - `open_url` → dispatch `onAction({ type: "open_url", params: { url },
     humanFriendlyMessage: "", formState: formPayload, formName })`
   - `set` → evaluate `valueAST` and write to the state store.
   - `reset` → restore declared defaults (or null).
   - `run` mutation → fire tool mutation, **halt the plan on failure**; `run` query →
     invalidate. (Unused in AppLess.)
3. No action / not a plan → default:
   `onAction({ type: "continue_conversation", params: {}, humanFriendlyMessage:
   userMessage, formState: formPayload, formName })`. This is what makes an
   action-less `Button` "send its label" (the AppLess Button renderer always calls
   `triggerAction(label, formName, action)`, so this default fires; an action-less
   `ListItem` is **inert** — `useTap` returns undefined when there is no action).
   *Source: `ui/shared/actions.ts`, `ui/cupertino/forms.tsx` Button,
   `ui/cupertino/components.tsx` ListItem.*

The AppLess shell consumes only this subset (`GenActionEvent`):

```ts
{ params?: Record<string, unknown>;      // { url } for open_url, { context? } otherwise
  humanFriendlyMessage?: string;          // the @ToAssistant message / button label
  formState?: Record<string, unknown> }   // formPayload as above
```
*Source: GenOS.tsx `GenActionEvent`.*

Shell routing of an ActionEvent (`handleAction`), in order:
*Source: GenOS.tsx `handleAction`.*

1. `params.url` starts with `genos://` → `parseGenosUrl` (§11.4):
   `toast` → toast `params.text || "Done ✓"`; `open` (needs both `app` and
   `request`) → deep link; `back` → shell back; `home` → shell home; anything else
   (including `genos://switcher`) is ignored. Return.
2. Other non-empty `params.url` → open externally (Linking). Return.
3. `humanFriendlyMessage` trimmed; empty → ignore.
4. If the top screen is still generating → toast
   `"Still materializing - try again in a second"`; the tap is dropped.
5. Navigation guard — regex on the message:
   `/genos\s*home|all (your |the )?apps|app (list|grid|drawer|launcher)|main menu/i`
   → shell home; `/^(go |return |navigate )?back( to( the)? previous( screen)?)?$/i`
   → shell back.
6. Otherwise `resolveAction(topScreenId, message, formState)` and push the resulting
   screen (§13 of `capabilities.md` covers caching/prefetch semantics; the request
   sent to the model is the message, plus, when `formState` is non-empty,
   `"\n\nSubmitted form values: " + JSON.stringify(formState)` — note the values are
   the wrapped `{value, componentType}` objects). *Source: store.ts `resolveAction`.*

**Chips** have no action prop: tapping chip *label* dispatches
`triggerAction('Apply the "<label>" filter and re-render this screen with only
matching content', undefined, undefined)` — i.e. a plain continue_conversation with
that exact message (skipped when the chip is already active).
*Source: `ui/cupertino/components.tsx` Chips.*

### 9.5 `$variable` bindings and form state

- A `$x = expr` **statement** declares state: its materialized value lands in
  `stateDeclarations["$x"]`. Any `$y` referenced anywhere but never declared is
  auto-declared with default `null`. *Source: `parser/parser.js` `extractStatements`.*
- The Renderer initializes a per-screen store from `stateDeclarations` (+ host
  `initialState`), preserving already-set keys across streaming re-parses (user edits
  are never clobbered by re-initialization). *Source: `runtime/store.js` `initialize`.*
- A `StateRef` in a prop position evaluates as follows: if the prop's zod schema was
  marked `reactive()` → a `ReactiveAssign` two-way binding marker; otherwise → the
  **current state value** (one-way read).
  **AppLess reality check [verified]:** the GenOS contract types every `value` prop as
  plain `z.any()` and never calls `reactive()`, so in this app `$draft` in
  `Input(..., $draft)` resolves to the declared default value (a seed), and the actual
  two-way field state flows through the form-state API instead
  (`useFieldState`/`getFieldValue`/`setFieldValue`, values stored as
  `{value, componentType}` under the form's name). Native ports must reproduce the
  *seed* behavior, not invent live two-way `$` bindings.
  *Source: `runtime/evaluate-prop.js`; `ui/contract.tsx`; `ui/shared/forms.ts`;
  react-lang `context.js` `useSetDefaultValue` (seeding is a no-op while
  `isStreaming`, and only applies when the field has no user value yet).*

## 10. Streaming semantics (normative)

The Renderer creates one incremental parser (`createStreamParser`) per library and
feeds it the **full accumulated text** on every pass via `set(fullText)`.
*Source: lang-core `parser/parser.js` `createStreamParser`; react-lang
`hooks/useOpenUIState.js`.*

### 10.1 Incremental architecture

State: `buf` (all text seen), `completedEnd` (watermark), `completedStmtMap`
(cache of parsed statements), `firstId`.

On each result request:

1. **Scan** `buf` from the watermark for newly *completed* statements: a character
   scanner tracking double/single-quote string state (escape-aware), bracket depth,
   and depth-0 ternary depth. A newline at depth 0 (with the §5.2 ternary lookahead)
   ends a statement; the statement text is comment-stripped, fence-marker lines
   (`/^```/`) are skipped, and the rest is tokenized/parsed/classified into the
   completed cache. The watermark advances past it.
2. **Pending tail** = text after the last completed statement. It is
   `stripComments(stripFences(tail))`-cleaned, then **autoClosed** (§7), tokenized and
   parsed. `wasIncomplete` from autoClose becomes `meta.incomplete`.
3. **Merge**: completed statements + pending statements, except a pending statement
   whose id already exists in the completed cache is **ignored** (a half-re-streamed
   `root = Card` cannot corrupt the completed `root`).
4. Build the result from the merged map exactly as in batch mode (§8).

### 10.2 `set()` reset rule

`set(fullText)`: if `fullText` is shorter than `buf` or not a prefix-extension of it,
the parser **resets completely** and reparses from scratch. **[verified]** (This is
what makes retry / screen-content replacement work.)

### 10.3 Streaming hazards to reproduce

- The completed-statement scanner is quote-aware but **not comment-aware**: an
  apostrophe or unbalanced quote inside a `//` comment puts the scanner in string
  state and glues following lines into one pending statement until another matching
  quote arrives. (Comment stripping happens per-statement *after* the scan.)
- Statements are cached permanently: a later **completed** duplicate id *does*
  overwrite the earlier completed one (`Map.set`) — see §10.6.
- `meta.statementCount` counts completed adds cumulatively plus pending statements —
  duplicates are counted per add; it is informational only.

### 10.4 Observed progressive behavior **[verified end-to-end]**

For `root = Card([header, list])\nheader = CardHeader("Wallet", "Personal")\n…`
truncated at successive byte offsets:

| Prefix state | Result |
|---|---|
| `root = Car` | root `null` (Ref "Car" unresolved), `incomplete:false` |
| `root = Card([header, l` | `Card` renders with **empty children** (unresolved refs dropped), `partial:true`, `incomplete:true`, unresolved `["header","l"]` |
| first line complete | same tree, `incomplete:false` |
| `header = Car` (partial name) | truncated identifier is just an unresolved ref; tree unchanged |
| `header = CardHeader("Wallet` | header appears with `title:"Wallet"` (autoclosed string), `partial:true` |
| header line complete | header complete; `subtitle` present |
| mid `r1 = ListItem("Cof` | ListBlock renders containing partial ListItem `title:"Cof"` |
| complete | full tree; `action` prop = raw `Action` AST until runtime evaluation |

Consequences implementers MUST preserve:

- **Top-down reveal**: because refs resolve against whatever exists on each pass,
  writing `root` first makes the shell appear immediately and children pop in as
  their statements complete ("hoisting"). Order truly does not matter for the final
  tree — only for the reveal sequence.
- A truncated *string* renders its partial text; a truncated *call* renders only once
  its required props are satisfiable (§8.2), otherwise it is absent (with a
  transient `missing-required` error in `meta.errors`).
- A missing/unparsable root ⇒ `result.root === null` ⇒ the Renderer returns null; the
  AppLess host shows its skeleton until content parses.

### 10.5 The `partial` flag and `meta`

`meta.incomplete` = the pending tail needed autoClosing this pass. Every ElementNode
materialized in a pass carries `partial = meta.incomplete` — including elements whose
own statements were long complete **[verified]**: the flag means "this tree was built
from an incomplete program", not "this node is incomplete". `meta.unresolved` lists
every reference that failed to resolve during the pass (duplicates possible);
`meta.errors` carries validation errors (§8.2) with `statementId` attribution.

### 10.6 Duplicate statement ids

- Batch parse: **last wins**. **[verified]**
- Streaming: last **completed** wins; a **pending** duplicate of a completed id is
  ignored until it completes (then it overwrites). **[verified]**

### 10.7 The `isStreaming` renderer flag

`isStreaming` does not change parsing. It gates the React runtime:
*Source: react-lang `hooks/useOpenUIState.js`, `context.js`.*

- `onError` reporting is suppressed while streaming (and previously reported errors
  are cleared with an empty-array callback when streaming restarts); errors fire once
  streaming stops.
- Error-boundary `reportError` is a no-op while streaming.
- Query/mutation evaluation is deferred (unused in AppLess).
- `useSetDefaultValue` (form seed values) is a no-op until streaming ends.

The AppLess host passes `isStreaming = (status === "pending" || status === "streaming")`
and re-renders at most every `STREAM_FLUSH_MS = 50` ms during streaming (store-level
throttle; status changes flush immediately). *Source: GenOS.tsx; store.ts.*

## 11. App-level pure helpers (must be ported byte-exact)

### 11.1 `cleanLang(text)` — fence stripping

*Source: store.ts.* Algorithm:

```
opened := text matches /^\s*```/
t := text with ONE leading /^\s*```[\w-]*[^\S\n]*\n?/ removed
if opened:
    end := index of "\n```" in t; if found, truncate t there
else:
    remove one trailing /\n```\s*$/
return t
```

Verified behaviors **[verified]**:

| Input | Output |
|---|---|
| `` `​``op `` (partial fence, no newline yet) | `""` (safe on partial streams — the fence-line regex eats it) |
| `` ```openui-lang\nPROG\n``` `` | `PROG` |
| `` ```openui\nPROG\n``` trailing `` | `PROG` (everything after close cut, but **only** when an opening fence was present) |
| `PROG\n``` ` (no opener) | `PROG` (trailing fence removed) |
| program containing `` ``` `` mid-string, no opener | unchanged (mid-text fences survive) |
| opener present and `\n```` ``` ```` occurs **inside a string** | truncated at it — `cleanLang` is *not* string-aware, unlike the parser's `stripFences` (§4) |

### 11.2 `extractActions(content)`

Regex `/@ToAssistant\(\s*"((?:\\.|[^"\\])*)"/g` over the (complete, cleaned) program;
each capture is unescaped with `replace(/\\(.)/g, "$1")` (every backslash-pair
collapses — not JSON semantics: `\n` becomes `n`), trimmed, empty strings skipped,
**deduped preserving first-seen order**. Double quotes only; leading whitespace after
`(` allowed. Used for prefetch (first `MAX_PREFETCH = 6` messages).
**[verified]** incl. escaped-quote capture and dedupe. *Source: store.ts.*

### 11.3 `parseOsCommand(text)`

Applied to every completed screen's full content, after `cleanLang` and `trim`:

```
/^@OS\(\s*(back|home|switcher|open)\s*(?:,\s*"([^"]+)")?\s*\)$/i
```

- Must match the **entire** cleaned response (`@OS(back)\nroot = …` → no match).
- Case-insensitive; command lower-cased in the result. Arg only in double quotes —
  `@OS(open, 'music')` does **not** match. Arg is optional at parse level; the shell
  only acts on `open` when an arg is present.
- Works through fences (cleanLang runs first). **[verified]**

The parser proper never sees a meaning for `@OS(...)`: fed through it, the line is not
a statement and yields an empty program (`root: null`). **[verified]** Detection and
execution are entirely the app's (`Screen.osCommand`, shell effect: remove the pending
command screen from the stack — for `back`, additionally pop one more screen only if
more than one remains — then run home/switcher/open; `open` matches known apps by id
or name, otherwise summons a new app). *Source: store.ts, GenOS.tsx.*

### 11.4 `parseGenosUrl(url)`

```
/^genos:\/\/([a-z]+)\/?(?:\?(.*))?$/i
```

Hand-rolled (Hermes URL support for custom schemes is unreliable). Command
lower-cased. Query pairs split on `&`; key/value split at the **first** `=`
(key-only pair → value `""`); key `decodeURIComponent`ed as-is; value: `+`→space
**then** `decodeURIComponent`; on decode failure both fall back to raw. **[verified]**
incl.: trailing slash ok, `GENOS://HOME` ok, bad percent-escapes kept raw,
non-genos URL → null. *Source: GenOS.tsx.*

### 11.5 `parseImgUrl(src)` and image resolution

Only srcs starting with `/api/img` are semantic; anything else passes through
untouched. Query parsing: split on `&`, first-`=` split, values
`decodeURIComponent`ed (raw on failure), keys not decoded.

- `q`: default `"abstract gradient"`; `+`→space; strip everything but
  `[a-zA-Z0-9, -]`; trim. (So `caf%C3%A9 "neon"!` → `caf neon`.) **[verified]**
- `seed`: `parseInt`, default 1, clamped to [1, 10000]; `w`: default 800, clamp
  [40, 1600]; `h`: default 500, clamp [40, 1600]; NaN → the min bound.

Resolution *(Source: tools/images.ts)*:

- **No Unsplash key** → LoremFlickr:
  `https://loremflickr.com/{w}/{h}/{encodeURIComponent(q with /[ ,]+/g→",")}?lock={seed}`
  e.g. `/api/img?q=sushi+platter&seed=3&w=800&h=440` →
  `https://loremflickr.com/800/440/sushi%2Cplatter?lock=3`. **[verified]**
- **With key** → Unsplash search `GET /search/photos?query={q}&per_page=10`
  (`Authorization: Client-ID <key>`), results cached per `q` (in-flight de-dupe);
  while searching the image slot renders a placeholder (`undefined` src); empty/
  failed search → LoremFlickr fallback; else pick `raw` URL at index
  `seed % candidates.length` and append `&w={w}&h={h}&fit=crop&q=80`.

## 12. `@OS` whole-response commands — summary

Covered in §11.3. Normative statement: `@OS(back|home|switcher|open, "arg")` is a
**transport-level protocol between model and shell**, not part of openui-lang. Native
parsers MUST NOT special-case it; native shells MUST implement the exact regex and
stack semantics above.

## 13. Error taxonomy

Validation errors (parser): `unknown-component`, `missing-required`, `null-required`,
`inline-reserved` — each `{code, component, path, message, statementId}`. Runtime:
`runtime-error` (per-prop, caught). React adapter adds `parse-exception`,
`parse-failed` (response present but no root), and `render-error` (error boundary).
AppLess passes no `onError`, so errors only reach `console.warn`; native ports may
log equivalently. Errors never abort a parse — the tree is always best-effort.
*Source: `materialize.js`, `evaluate-tree.js`, react-lang `hooks/useOpenUIState.js`,
`enrich-errors.js`.*

## 14. What the repo patch changes (and does not)

`patches/@openuidev+react-lang+0.1.5.patch` modifies **only**
`react-lang/dist/Renderer.js`:

1. **Error-boundary recovery keyed on the parsed node**: recovery from a child render
   error happens only when the underlying parsed `el` node identity changes (a
   genuinely new streaming delta) and never retries the same node — preventing an
   infinite recover→throw loop ("Maximum update depth exceeded") on React Native.
   Native renderers should mirror the *policy*: on a per-component render failure,
   keep showing the last good render of that subtree and retry only when its resolved
   node changes.
2. **DefaultQueryLoader → null** (removes a DOM spinner) and **removal of the two
   wrapper `<div>`s** around the rendered root (RN has no DOM) — pure rendering
   concerns, no tree/semantic change.

The patch does **not** touch tokenizing, parsing, materialization, evaluation, or
action dispatch. All grammar behavior above is unpatched upstream lang-core 0.1.2.
*Source: the patch file (3 hunks), diffed against the pristine install.*

---

## Appendix A — parse-result shapes (for fixture serialization)

```ts
ParseResult {
  root: ElementNode | null;
  meta: { incomplete: boolean; unresolved: string[];
          statementCount: number; errors: ValidationError[] };
  stateDeclarations: Record<string, unknown>;   // "$name" → default
  queryStatements: [];                          // always empty for AppLess programs
  mutationStatements: [];
}
ElementNode { type: "element"; typeName: string;
              props: Record<string, unknown>;   // post-runtime-eval: plain values,
                                                // ElementNodes, arrays, ActionPlans
              partial: boolean; hasDynamicProps: boolean; statementId?: string }
ActionPlan  { steps: ActionStep[] }
ActionEvent { type: "continue_conversation" | "open_url";
              params: Record<string, unknown>; humanFriendlyMessage: string;
              formState: Record<string, unknown>; formName?: string }
```
*Source: lang-core `parser/types.js`, `parser/parser.js`; verified output shapes.*
