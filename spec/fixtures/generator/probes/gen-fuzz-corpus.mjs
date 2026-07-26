/**
 * Differential-fuzz campaign generator.
 *
 * Emits a deterministic JSON "campaign" describing streaming-parser sessions to
 * be replayed identically by the JS oracle (`expected-tree.mjs`), the Swift port
 * (`ios/Packages/OpenUILang` -> `openui-fuzz-driver`) and the Kotlin port
 * (`android/openui-lang` -> `:openui-lang:fuzzDriver`). `run-differential.mjs`
 * runs all three and byte-compares their output streams.
 *
 * Determinism: a mulberry32 PRNG with a FIXED seed, one independent stream per
 * campaign (seed XOR a per-campaign salt) so `--campaign mutation` produces the
 * exact same sessions whether or not the other campaigns are generated too.
 * No Date, no Math.random — re-running reproduces the file byte-identically.
 *
 * Usage:
 *   node probes/gen-fuzz-corpus.mjs --campaign prefix        --out FILE
 *   node probes/gen-fuzz-corpus.mjs --campaign nonmonotonic  --out FILE
 *   node probes/gen-fuzz-corpus.mjs --campaign mutation      --out FILE
 *   node probes/gen-fuzz-corpus.mjs --campaign pinned        --out FILE --with-expected
 *   node probes/gen-fuzz-corpus.mjs --campaign all           --out FILE
 *   node probes/gen-fuzz-corpus.mjs --campaign prefix --stats     # counts only
 *
 * `--with-expected` records each step's tree from the REAL JS oracle into the
 * campaign (`session.expected[]`). That is how the committed
 * `fuzz-campaign-pinned.json` is produced; the big campaigns are generated
 * (without expectations) in CI and compared three-way instead.
 *
 * ── Campaigns ────────────────────────────────────────────────────────────────
 *   prefix        EXHAUSTIVE PREFIX. For every fixture in spec/fixtures, every
 *                 UTF-16 code-unit prefix (0..len, cuts that would split a
 *                 surrogate pair are skipped) fed CUMULATIVELY to ONE streaming
 *                 parser — the shape the Renderer's store-flush contract
 *                 produces (spec/openui-lang.md §10).
 *   nonmonotonic  Random shrink / cross-fixture switch sequences: the text goes
 *                 BACKWARDS or jumps to an unrelated program, which forces
 *                 StreamCore's cache-reset path that prefix fuzzing never hits.
 *   mutation      Single-code-point insert/delete/replace over each fixture
 *                 using a hazard alphabet (quotes, brackets, backslash, CR, LF,
 *                 NBSP, U+FEFF, combining acute, `@`, `$`, `#`, `//`). One
 *                 fresh parser per mutant.
 *   pinned        A small, committed cross-section of all three (smoke test /
 *                 self-check; carries `expected` so it needs no JS at replay).
 *
 * ── Campaign file shape ──────────────────────────────────────────────────────
 *   {
 *     "version": 1, "seed": "0x...", "campaigns": ["prefix"],
 *     "sessionCount": N, "stepCount": N,
 *     "sessions": [
 *       { "campaign": "prefix",
 *         "name": "prefix/001-minimal-card",
 *         "sources": ["<full text>", ...],
 *         "steps": [[srcIndex, utf16PrefixLength], ...],
 *         "expected": ["<tree>", ...]        // only with --with-expected
 *       }, ...
 *     ]
 *   }
 *
 * Every step's text is `sources[srcIndex].slice(0, utf16PrefixLength)` in UTF-16
 * code units, and all steps of a session go to ONE parser in order. That single
 * rule is the whole contract the two native drivers implement.
 */
import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const FIXTURES_ROOT = path.resolve(HERE, "..", "..");

/** Fixed seed. Never derive anything from Date/Math.random. */
export const SEED = 0x0f1_22ed5;

const SALT = {
  prefix: 0x9e3779b9,
  nonmonotonic: 0x85ebca6b,
  mutation: 0xc2b2ae35,
  pinned: 0x27d4eb2f,
  synthesis: 0x165667b1,
};

const NONMONO_SESSIONS = 48;
const NONMONO_STEPS = [8, 16]; // inclusive range
const MUTATIONS_PER_FIXTURE = 24;

/** Hazard alphabet — the characters that historically broke the ports. */
const HAZARDS = [
  '"',
  "'",
  "`",
  "[",
  "]",
  "{",
  "}",
  "(",
  ")",
  "\\",
  "\r",
  "\n",
  "\r\n",
  " ", // NBSP
  "﻿", // ZWNBSP / BOM
  "́", // combining acute accent
  "@",
  "$",
  "#",
  "//",
  ":",
  ",",
  ".",
];

function mulberry32(a) {
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Independent, campaign-scoped PRNG stream. */
function prngFor(campaign) {
  const rand = mulberry32((SEED ^ SALT[campaign]) | 0);
  return {
    rand,
    int: (lo, hi) => lo + Math.floor(rand() * (hi - lo + 1)),
    pick: (arr) => arr[Math.floor(rand() * arr.length)],
  };
}

// ── Fixture discovery ────────────────────────────────────────────────────────

function scanOui(dir, prefix, out) {
  for (const entry of readdirSync(dir)) {
    if (!entry.endsWith(".oui")) continue;
    out.push({
      name: prefix + entry.slice(0, -".oui".length),
      text: readFileSync(path.join(dir, entry), "utf8"), // verbatim — no trimming
    });
  }
}

/**
 * Every `.oui` under spec/fixtures (top level + `partial/`), sorted by name —
 * the SAME order and the same names the two ports' FixtureOracle suites use.
 */
export function discoverFixtures() {
  const out = [];
  scanOui(FIXTURES_ROOT, "", out);
  scanOui(path.join(FIXTURES_ROOT, "partial"), "partial/", out);
  out.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  return out;
}

/**
 * Hazard SEED programs (`probes/fuzz-seeds/*.oui`) — extra corpus entries that
 * are NOT fixtures (nothing here changes spec/fixtures or any gate).
 *
 * They exist because the fixture corpus is a *feature* corpus, not a *hazard*
 * corpus: it contains no `@Round` tie, no `-0`, no `Infinity`, no `1e21`, no
 * lone combining mark. Reverting the `@Round` tie rule to `floor(x + 0.5)` is
 * invisible to every campaign built from fixtures alone (measured), so the very
 * bug class ad-hoc probing caught would have walked straight through this gate.
 * Prefix + mutation + non-monotonic campaigns treat these exactly like
 * fixtures, which puts the numeric/whitespace/formatting edges under the fuzzer.
 */
export function discoverSeeds() {
  const dir = path.join(HERE, "fuzz-seeds");
  const out = [];
  scanOui(dir, "seed/", out);
  out.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  return out;
}

/** Fixtures + hazard seeds — everything the campaigns fuzz over. */
export function discoverCorpus() {
  return discoverFixtures().concat(discoverSeeds());
}

// ── UTF-16 safety helpers ────────────────────────────────────────────────────

const isHighSurrogate = (c) => c >= 0xd800 && c <= 0xdbff;
const isLowSurrogate = (c) => c >= 0xdc00 && c <= 0xdfff;

/** True when cutting `s` at code-unit index `n` would split a surrogate pair. */
export function splitsPair(s, n) {
  if (n <= 0 || n >= s.length) return false;
  return isHighSurrogate(s.charCodeAt(n - 1)) && isLowSurrogate(s.charCodeAt(n));
}

/** Nearest cut <= n that does not split a surrogate pair. */
function safeCut(s, n) {
  const clamped = Math.max(0, Math.min(n, s.length));
  return splitsPair(s, clamped) ? clamped - 1 : clamped;
}

/** Code-unit index of every code-point boundary in `s` (0..len inclusive). */
function codePointBoundaries(s) {
  const b = [];
  for (let i = 0; i <= s.length; i++) if (!splitsPair(s, i)) b.push(i);
  return b;
}

// ── Campaign builders ────────────────────────────────────────────────────────

/** (a) EXHAUSTIVE PREFIX — cumulative, one parser per fixture. */
export function buildPrefixSessions(fixtures) {
  return fixtures.map((f) => {
    const steps = [];
    for (let n = 0; n <= f.text.length; n++) {
      if (splitsPair(f.text, n)) continue; // surrogate-pair-safe cut
      steps.push([0, n]);
    }
    return {
      campaign: "prefix",
      name: `prefix/${f.name}`,
      sources: [f.text],
      steps,
    };
  });
}

/**
 * (b) NON-MONOTONIC — shrinks and cross-fixture switches. Prefix fuzzing only
 * ever grows the text, so StreamCore's "new text is not an extension of the
 * previous one -> drop the completed-statement cache" branch is unreachable
 * there. These sessions go backwards and sideways on purpose.
 */
export function buildNonMonotonicSessions(fixtures) {
  const rng = prngFor("nonmonotonic");
  const sessions = [];
  for (let s = 0; s < NONMONO_SESSIONS; s++) {
    const sourceCount = rng.int(2, 3);
    const chosen = [];
    while (chosen.length < sourceCount) {
      const f = fixtures[rng.int(0, fixtures.length - 1)];
      if (!chosen.includes(f)) chosen.push(f);
    }
    const sources = chosen.map((f) => f.text);
    const steps = [];
    let src = 0;
    let len = safeCut(sources[0], rng.int(0, sources[0].length));
    steps.push([src, len]);
    const stepCount = rng.int(NONMONO_STEPS[0], NONMONO_STEPS[1]);
    for (let i = 1; i < stepCount; i++) {
      const op = rng.int(0, 9);
      if (op <= 2) {
        // shrink — the reset path
        len = safeCut(sources[src], rng.int(0, len));
      } else if (op <= 5) {
        // grow (may still be a reset if the tail changed under it)
        len = safeCut(sources[src], rng.int(len, sources[src].length));
      } else if (op <= 7) {
        // switch fixture, keep a comparable length -> almost never an extension
        src = rng.int(0, sources.length - 1);
        len = safeCut(sources[src], rng.int(0, sources[src].length));
      } else if (op === 8) {
        // hard reset to empty
        len = 0;
      } else {
        // jump straight to a complete program
        src = rng.int(0, sources.length - 1);
        len = sources[src].length;
      }
      steps.push([src, len]);
    }
    sessions.push({
      campaign: "nonmonotonic",
      name: `nonmonotonic/${String(s).padStart(3, "0")}-${chosen
        .map((f) => f.name.replace("partial/", "p:"))
        .join("+")}`,
      sources,
      steps,
    });
  }
  return sessions;
}

/**
 * (c) MUTATION — one single-code-point edit per mutant, hazard alphabet, one
 * fresh parser per mutant (a fresh streaming parser + one `set()` is exactly a
 * batch parse, so this is the fixture oracle re-run on damaged inputs).
 */
export function buildMutationSessions(fixtures, perFixture = MUTATIONS_PER_FIXTURE) {
  const rng = prngFor("mutation");
  const sessions = [];
  for (const f of fixtures) {
    const bounds = codePointBoundaries(f.text);
    for (let m = 0; m < perFixture; m++) {
      const op = rng.int(0, 2); // 0 insert, 1 delete, 2 replace
      const bIdx = rng.int(0, bounds.length - 1);
      const at = bounds[bIdx];
      const nextBoundary = bounds[Math.min(bIdx + 1, bounds.length - 1)];
      const hazard = rng.pick(HAZARDS);
      let mutated;
      let label;
      if (op === 0) {
        mutated = f.text.slice(0, at) + hazard + f.text.slice(at);
        label = `insert@${at}`;
      } else if (op === 1 && nextBoundary > at) {
        mutated = f.text.slice(0, at) + f.text.slice(nextBoundary);
        label = `delete@${at}`;
      } else {
        const end = nextBoundary > at ? nextBoundary : at;
        mutated = f.text.slice(0, at) + hazard + f.text.slice(end);
        label = `replace@${at}`;
      }
      sessions.push({
        campaign: "mutation",
        name: `mutation/${f.name}#${String(m).padStart(2, "0")}-${label}`,
        sources: [mutated],
        steps: [[0, mutated.length]],
      });
    }
  }
  return sessions;
}

// ── (d) SYNTHESIS ────────────────────────────────────────────────────────────
//
// Every other campaign DERIVES from the committed corpus, which is why 31,269
// steps of prefix/nonmonotonic/mutation fuzzing found none of the three
// serializer duck-typing divergences a reviewer found by hand in 61 steps: no
// fixture contained a `{steps: […]}` row, a hand-written `valueAST`, or an
// object spelling out `type`/`typeName`, and no single-code-point mutation can
// invent one. Mutation fuzzing explores a ball of radius 1 around a corpus that
// never enters the neighbourhood.
//
// This campaign does not derive from anything. It writes object literals from
// an alphabet of the exact keys the serializer duck-types on, so the surface is
// reachable by machine instead of by inspiration.

/** The keys `serialize.mjs` and `evaluate-prop.js` actually branch on. */
const SYNTH_KEYS = [
  "steps", // isActionPlan
  "type", // isActionStep / isElementNode
  "typeName", // isElementNode
  "valueAST", // isActionStep + serializeStep's by-NAME wrapping
  "props", // isElementNode + serializeElement's Object.keys
  "partial", // isElementNode (runtime guard only)
  "hasDynamicProps", // evaluateElementProps' `=== false` short-circuit
  "statementId", // copied verbatim into the emitted element
  "k", // isAstNode (serializer + runtime)
  "v",
  "__proto__", // the setter that makes ALL of the above chain-aware
];

/** Values chosen so the duck-type guards actually fire some of the time. */
const SYNTH_SCALARS = [
  '"element"',
  '"TextContent"',
  '"Card"',
  '"Str"',
  '"set"',
  '"ab"',
  '""',
  "0",
  "1",
  "-1",
  "true",
  "false",
  "null",
];

/**
 * Two shapes are DELIBERATELY not generated, because the REFERENCE THROWS on
 * them and therefore has no expected tree to compare against — the fixture
 * generator dies with the same `TypeError` (verified: `{steps: [null]}` and
 * `{type: "element", typeName: "X"}` with no `props` both take
 * `node probes/expected-tree.mjs` down at serialize.mjs:51 / :84):
 *
 *   1. a `null`/`undefined` STEP        — `Object.keys(step)` throws
 *   2. an element-shaped object with no `props` — `Object.keys(el.props)` throws
 *
 * So the generator maintains two invariants: a `steps` array never contains a
 * literal `null`, and `type: "element"` is only ever written alongside a
 * non-nullish `props` in the SAME literal (which every `__proto__` inheritor
 * then inherits too). Both shapes are listed in the ports' READMEs as the
 * "serializer-level TypeError" deviation instead.
 */
function synthValue(rng, depth, allowNull) {
  const roll = rng.int(0, 11);
  if (depth >= 2 || roll <= 4) {
    const scalar = rng.pick(SYNTH_SCALARS);
    return scalar === "null" && !allowNull ? '"ab"' : scalar;
  }
  if (roll <= 7) {
    const n = rng.int(0, 2);
    const items = [];
    for (let i = 0; i < n; i++) items.push(synthValue(rng, depth + 1, allowNull));
    return `[${items.join(", ")}]`;
  }
  return synthObject(rng, depth + 1, null);
}

/** One object literal. `protoRef` (a statement name) becomes its `__proto__`. */
function synthObject(rng, depth, protoRef) {
  const parts = [];
  if (protoRef) parts.push(`"__proto__": ${protoRef}`);
  const keyCount = rng.int(1, 4);
  const used = new Set();
  let wroteElementType = false;
  for (let i = 0; i < keyCount; i++) {
    const key = rng.pick(SYNTH_KEYS);
    if (key === "__proto__" || used.has(key)) continue;
    used.add(key);
    if (key === "type" && rng.int(0, 1) === 0) {
      // The element branch: `type: "element"` always with a props sibling.
      parts.push('type: "element"');
      wroteElementType = true;
      continue;
    }
    if (key === "steps") {
      const n = rng.int(0, 3);
      const items = [];
      // Invariant 1: never a literal null inside a steps array.
      for (let j = 0; j < n; j++) items.push(synthValue(rng, depth + 1, false));
      parts.push(`steps: [${items.join(", ")}]`);
      continue;
    }
    if (key === "props") {
      used.add("props");
      parts.push(`props: ${rng.int(0, 2) === 0 ? synthValue(rng, depth + 1, false) : "{ text: \"t\" }"}`);
      continue;
    }
    parts.push(`${key}: ${synthValue(rng, depth + 1, true)}`);
  }
  // Invariant 2: `type: "element"` implies a non-nullish `props` right here.
  if (wroteElementType && !used.has("props")) parts.push('props: { text: "t" }');
  if (parts.length === 0) parts.push('z: 1');
  return `{ ${parts.join(", ")} }`;
}

const SYNTH_SESSIONS = 400;

/** (d) SYNTHESIS — programs written from the duck-typing key alphabet. */
export function buildSynthesisSessions() {
  const rng = prngFor("synthesis");
  const sessions = [];
  for (let s = 0; s < SYNTH_SESSIONS; s++) {
    const lines = [];
    const names = [];
    const statementCount = rng.int(1, 3);
    for (let i = 0; i < statementCount; i++) {
      const name = `s${i}`;
      // Chain onto an EARLIER statement roughly half the time — that is what
      // puts `type`/`typeName`/`k`/`steps` behind a prototype link.
      const protoRef = names.length && rng.int(0, 1) === 0 ? rng.pick(names) : null;
      lines.push(`${name} = ${synthObject(rng, 0, protoRef)}`);
      names.push(name);
    }
    const rows = names.map((n) => n).join(", ");
    if (rng.int(0, 4) === 0) {
      // Duck-typed ROOT: the entry statement itself answers isElementNode.
      lines.push(
        `root = { type: "element", typeName: "Card", props: { children: [${rows}] }, ` +
          `partial: false${rng.int(0, 1) === 0 ? ", hasDynamicProps: false" : ""} }`
      );
    } else {
      lines.push(`root = Card([CardHeader("synth ${s}"), KVList([${rows}])])`);
    }
    const text = lines.join("\n") + "\n";
    // One fresh parser per program, plus a mid-program cut so the streaming
    // scanner sees the same shapes half-written.
    const cut = safeCut(text, Math.floor(text.length * 0.6));
    sessions.push({
      campaign: "synthesis",
      name: `synthesis/${String(s).padStart(3, "0")}`,
      sources: [text],
      steps: [
        [0, cut],
        [0, text.length],
      ],
    });
  }
  return sessions;
}

/**
 * (e) PINNED — a small committed cross-section carrying oracle expectations, so
 * `run-differential.mjs --campaign pinned` is a self-contained smoke test (and
 * a regression gate on the JS oracle itself).
 */
export function buildPinnedSessions(corpus) {
  const rng = prngFor("pinned");
  const fixtures = corpus ?? discoverCorpus();
  const byName = new Map(fixtures.map((f) => [f.name, f]));
  // Deterministic, meaningful cross-section: surrogate pairs, escapes, streaming
  // partials, and the fixtures the ports have ACTUALLY diverged on - which is
  // the selection rule, so the two newest divergence classes are here too:
  // the JS prototype chain (inherited functions reached through member access)
  // and `@Sort`'s ASCII collation, where `java.text.Collator` and Foundation
  // disagreed with V8 and with each other.
  const wanted = [
    "020-unicode-emoji",
    "016-string-escapes",
    "019-numbers",
    "partial/105-mid-escape",
    "partial/114-mid-number",
    "seed/001-round-ties",
    "seed/004-string-hazards",
    "088-prototype-member-access",
    "090-sort-ascii-collation",
  ].filter((n) => byName.has(n));
  const chosen = wanted.length ? wanted.map((n) => byName.get(n)) : fixtures.slice(0, 5);

  const sessions = [];
  for (const f of chosen) {
    // Subsampled prefixes: the committed file carries oracle expectations, so
    // it stays small on purpose. The EXHAUSTIVE prefix walk is the `prefix`
    // campaign, generated fresh in CI.
    const L = f.text.length;
    const stride = Math.max(1, Math.ceil(L / 24));
    const wantedCuts = new Set([0, L]);
    for (let n = 0; n <= L; n += stride) wantedCuts.add(n);
    for (let n = Math.max(0, L - 12); n <= L; n++) wantedCuts.add(n);
    const steps = [...wantedCuts]
      .sort((a, b) => a - b)
      .filter((n) => !splitsPair(f.text, n))
      .map((n) => [0, n]);
    sessions.push({
      campaign: "pinned",
      name: `pinned-prefix/${f.name}`,
      sources: [f.text],
      steps,
    });
  }
  // A couple of reset sessions plus a handful of mutants, drawn from the same
  // small fixture set so the committed file stays tiny.
  for (const s of buildNonMonotonicSessions(chosen).slice(0, 4)) {
    sessions.push({ ...s, campaign: "pinned", name: `pinned-${s.name}` });
  }
  for (const s of buildMutationSessions(chosen, 4)) {
    sessions.push({ ...s, campaign: "pinned", name: `pinned-${s.name}` });
  }
  void rng;
  return sessions;
}

// ── Assembly ─────────────────────────────────────────────────────────────────

const KNOWN = ["prefix", "nonmonotonic", "mutation", "synthesis", "pinned"];

export function buildCampaign(which, { mutationsPerFixture } = {}) {
  const fixtures = discoverCorpus();
  const names =
    which === "all" ? ["prefix", "nonmonotonic", "mutation", "synthesis"] : which.split(",");
  for (const n of names) {
    if (!KNOWN.includes(n)) throw new Error(`unknown campaign: ${n} (known: ${KNOWN.join(", ")})`);
  }
  let sessions = [];
  for (const n of names) {
    if (n === "prefix") sessions = sessions.concat(buildPrefixSessions(fixtures));
    else if (n === "nonmonotonic") sessions = sessions.concat(buildNonMonotonicSessions(fixtures));
    else if (n === "mutation")
      sessions = sessions.concat(
        buildMutationSessions(fixtures, mutationsPerFixture ?? MUTATIONS_PER_FIXTURE)
      );
    else if (n === "synthesis") sessions = sessions.concat(buildSynthesisSessions());
    else if (n === "pinned") sessions = sessions.concat(buildPinnedSessions(fixtures));
  }
  return {
    version: 1,
    seed: `0x${(SEED >>> 0).toString(16)}`,
    generatedBy: "spec/fixtures/generator/probes/gen-fuzz-corpus.mjs",
    campaigns: names,
    corpusSize: fixtures.length,
    fixtureCount: fixtures.filter((f) => !f.name.startsWith("seed/")).length,
    seedCount: fixtures.filter((f) => f.name.startsWith("seed/")).length,
    sessionCount: sessions.length,
    stepCount: sessions.reduce((a, s) => a + s.steps.length, 0),
    sessions,
  };
}

/** Per-campaign step counts, for the runner's summary. */
export function stepCountsByCampaign(campaign) {
  const counts = {};
  for (const s of campaign.sessions) {
    counts[s.campaign] = (counts[s.campaign] ?? 0) + s.steps.length;
  }
  return counts;
}

/** The text of one step — the ONLY rule the native drivers implement. */
export function stepText(session, step) {
  return session.sources[step[0]].slice(0, step[1]);
}

/** Fill in `session.expected[]` from the REAL JS oracle. */
export async function attachExpected(campaign) {
  const { createOracle, serializeResult } = await import("./expected-tree.mjs");
  const oracle = await createOracle();
  for (const session of campaign.sessions) {
    const sp = oracle.langCore.createStreamingParser(oracle.schema, oracle.library.root);
    session.expected = session.steps.map((step) =>
      serializeResult(oracle, sp.set(stepText(session, step)))
    );
  }
  return campaign;
}

// ── CLI ──────────────────────────────────────────────────────────────────────

const invokedDirectly =
  process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  const args = process.argv.slice(2);
  const flag = (name, fallback = undefined) => {
    const i = args.indexOf(name);
    return i === -1 ? fallback : args[i + 1];
  };
  const which = flag("--campaign", "all");
  const outPath = flag("--out");
  const withExpected = args.includes("--with-expected");
  const statsOnly = args.includes("--stats");
  const perFixture = flag("--mutations-per-fixture");

  try {
    const campaign = buildCampaign(which, {
      mutationsPerFixture: perFixture ? Number(perFixture) : undefined,
    });
    if (withExpected) await attachExpected(campaign);
    const counts = stepCountsByCampaign(campaign);
    const summary =
      `[gen-fuzz-corpus] seed=${campaign.seed} ` +
      `corpus=${campaign.corpusSize} (fixtures=${campaign.fixtureCount} seeds=${campaign.seedCount}) ` +
      `sessions=${campaign.sessionCount} steps=${campaign.stepCount} ` +
      `(${Object.entries(counts)
        .map(([k, v]) => `${k}=${v}`)
        .join(" ")})`;
    if (statsOnly) {
      console.log(summary);
    } else {
      const json = JSON.stringify(campaign, null, withExpected ? 1 : 0) + "\n";
      if (outPath) {
        writeFileSync(outPath, json);
        console.error(`${summary} -> ${outPath} (${json.length} bytes)`);
      } else {
        process.stdout.write(json);
      }
    }
  } catch (e) {
    console.error("[gen-fuzz-corpus] FAILED:", e);
    process.exit(1);
  }
}
