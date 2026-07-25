/**
 * Regenerate — and mechanically verify — the JS-oracle expected trees inlined
 * in ios/Packages/OpenUILang/Tests/OpenUILangTests/StreamingSemanticsTests.swift.
 *
 * Each scenario below is the exact `set()` sequence that Swift test runs
 * (scenario names match the Swift test methods). Every scenario gets ONE
 * fresh streaming parser; each step's full accumulated text is fed to
 * `sp.set(...)` and the result is pushed through the generator's runtime +
 * serialization pipeline (see probes/expected-tree.mjs / generate.mjs).
 *
 * Usage:
 *   node probes/regen-streaming-expectations.mjs
 *       Print mode. For every scenario step, a marker line
 *         === <scenarioName> step <N> ===
 *       followed by the expected JSON document, byte-identical (modulo the
 *       Swift source's triple-quote indentation) to the string literal
 *       inlined in StreamingSemanticsTests.swift. When editing scenarios,
 *       re-run this script and paste the regenerated JSON back into the test.
 *
 *   node probes/regen-streaming-expectations.mjs --check <path-to-Swift-file>
 *       Drift gate (run by the generator's `npm test`). Parses
 *       StreamingSemanticsTests.swift, extracts every `runScenario` step's
 *       set() text AND inline expected-JSON literal (handling Swift
 *       triple-quote dedenting, `+` literal concatenation, and the
 *       `Self.rootWithText(_:incomplete:)` template), then verifies
 *         1. the Swift scenarios and this script's SCENARIOS table agree
 *            (same names, step counts, byte-identical step texts), and
 *         2. every Swift inline expectation byte-matches a freshly generated
 *            oracle tree for that step.
 *       Exits non-zero listing each drift. The Swift file must keep the
 *       machine-readable shape this parser understands (plain literals,
 *       `steps: [ (text, expected), ... ]`, rootWithText for shared trees);
 *       the parser fails loudly on anything it cannot extract.
 */
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { createOracle, runSteps } from "./expected-tree.mjs";

/**
 * Scenario table — the same names + step texts as the Swift test methods.
 * `--check` verifies this mechanically against StreamingSemanticsTests.swift.
 */
export const SCENARIOS = [
  {
    name: "prefixExtensionCaching",
    steps: [
      'root = Card([CardHeader("Count: " + $n)])\n',
      'root = Card([CardHeader("Count: " + $n)])\n$n = 5',
    ],
  },
  {
    name: "batchCompletedDuplicateOverwrites",
    steps: ['root = Card([TextContent("one")])\nroot = Card([TextContent("two")])\n'],
  },
  {
    name: "pendingCannotOverwriteCompleted",
    steps: [
      'root = Card([TextContent("one")])\n',
      // Redefinition is still pending (no trailing newline): "one" must survive.
      'root = Card([TextContent("one")])\nroot = Card([TextContent("two")])',
    ],
  },
  {
    name: "streamedCompletedDuplicateOverwrites",
    steps: [
      'root = Card([TextContent("one")])\n',
      'root = Card([TextContent("one")])\nroot = Card([TextContent("two")])\n',
    ],
  },
  {
    name: "nonPrefixResets",
    steps: [
      'root = Card([TextContent("one")])\n',
      'root = Card([TextContent("reset")])\n',
    ],
  },
  {
    name: "apostropheCommentGlue",
    steps: [
      'root = Card([header, tail])\n# don\'t split here\nheader = CardHeader("Streams")\n',
      'root = Card([header, tail])\n# don\'t split here\nheader = CardHeader("Streams")\n' +
        'tail = TextContent("done: " + $ok)\n$ok = "yes',
    ],
  },
  {
    name: "chunkBoundaryInsideCRLF",
    steps: [
      'root = Card([hd, tl])\r\nhd = CardHeader("Split")\r',
      'root = Card([hd, tl])\r\nhd = CardHeader("Split")\r' +
        '\ntl = TextContent("tail: " + $z)\r\n$z = 9\r\n',
    ],
  },
];

// ───────────────────────────────────────────────────────────────────────────
// --check: extract scenarios from StreamingSemanticsTests.swift
// ───────────────────────────────────────────────────────────────────────────

/**
 * Minimal scanner for the subset of Swift the test file uses: whitespace,
 * `//`/`/*` comments, single-line string literals with simple escapes,
 * triple-quote multiline literals (dedented to the closing delimiter, with
 * `\(...)` interpolation captured as template parts), `+` concatenation of
 * literals, and the `Self.rootWithText("...", incomplete: bool)` call.
 * Anything else is a hard error: the Swift file must stay machine-readable.
 */
export class SwiftScanner {
  constructor(text, pos, label) {
    this.text = text;
    this.pos = pos;
    this.label = label;
  }

  fail(msg) {
    const line = this.text.slice(0, this.pos).split("\n").length;
    throw new Error(`${this.label} (line ${line}): ${msg}`);
  }

  peek() {
    return this.text[this.pos];
  }

  startsWith(s) {
    return this.text.startsWith(s, this.pos);
  }

  expect(s) {
    if (!this.startsWith(s)) {
      this.fail(
        `expected ${JSON.stringify(s)}, found ` +
          `${JSON.stringify(this.text.slice(this.pos, this.pos + 24))}`
      );
    }
    this.pos += s.length;
  }

  skipTrivia() {
    for (;;) {
      const c = this.text[this.pos];
      if (c === " " || c === "\t" || c === "\n" || c === "\r") {
        this.pos++;
      } else if (this.startsWith("//")) {
        const nl = this.text.indexOf("\n", this.pos);
        this.pos = nl === -1 ? this.text.length : nl;
      } else if (this.startsWith("/*")) {
        const end = this.text.indexOf("*/", this.pos + 2);
        if (end === -1) this.fail("unterminated block comment");
        this.pos = end + 2;
      } else {
        return;
      }
    }
  }

  /** `"..."` with \n \r \t \0 \" \' \\ escapes. Interpolation is rejected. */
  parseSingleLineLiteral() {
    this.expect('"');
    let out = "";
    for (;;) {
      const c = this.text[this.pos];
      if (c === undefined || c === "\n") this.fail("unterminated string literal");
      if (c === '"') {
        this.pos++;
        return out;
      }
      if (c === "\\") {
        const e = this.text[this.pos + 1];
        this.pos += 2;
        if (e === "n") out += "\n";
        else if (e === "r") out += "\r";
        else if (e === "t") out += "\t";
        else if (e === "0") out += "\0";
        else if (e === '"') out += '"';
        else if (e === "'") out += "'";
        else if (e === "\\") out += "\\";
        else if (e === "(")
          this.fail(
            "string interpolation in a scenario literal — keep step texts plain so --check can parse them"
          );
        else this.fail(`unsupported escape \\${e}`);
        continue;
      }
      out += c;
      this.pos++;
    }
  }

  /**
   * `"""` ... `"""` — returns template parts: `{ str }` runs interleaved with
   * `{ interp }` for each `\(expression)`. Dedents by the closing delimiter's
   * indentation, exactly like Swift.
   */
  parseMultilineParts() {
    this.expect('"""');
    const nl = this.text.indexOf("\n", this.pos);
    if (nl === -1 || this.text.slice(this.pos, nl).trim() !== "") {
      this.fail('expected newline right after opening """');
    }
    this.pos = nl + 1;
    const close = /\n([ \t]*)"""/.exec(this.text.slice(this.pos));
    if (!close) this.fail("unterminated multiline string literal");
    const raw = this.text.slice(this.pos, this.pos + close.index);
    const indent = close[1];
    this.pos += close.index + close[0].length;

    const dedented = raw
      .split("\n")
      .map((line) => {
        if (line.startsWith(indent)) return line.slice(indent.length);
        if (line.trim() === "") return "";
        this.fail(
          `multiline literal line not indented to the closing delimiter: ${JSON.stringify(line)}`
        );
      })
      .join("\n");

    const parts = [];
    let buf = "";
    for (let i = 0; i < dedented.length; i++) {
      const c = dedented[i];
      if (c !== "\\") {
        buf += c;
        continue;
      }
      const e = dedented[i + 1];
      if (e === "(") {
        // Balanced-paren, quote-aware interpolation capture. String literals
        // inside the expression are tracked with full escape state, so an
        // escaped quote (\") or backslash (\\) — and parens inside the
        // string — cannot desync the paren balance. Shapes we can't capture
        // faithfully (nested interpolations inside those strings, multiline
        // literals) fail loudly instead of misparsing.
        let depth = 1;
        let inString = false;
        let j = i + 2;
        while (j < dedented.length && depth > 0) {
          const d = dedented[j];
          if (inString) {
            if (d === "\\") {
              if (dedented[j + 1] === "(") {
                this.fail(
                  "nested \\(...) interpolation inside a string literal within a " +
                    "\\(...) interpolation is not supported — keep interpolation expressions simple"
                );
              }
              j += 2; // escaped char (\" \\ \n ...) can never end the string
              continue;
            }
            if (d === '"') inString = false;
          } else if (d === '"') {
            if (dedented.startsWith('"""', j)) {
              this.fail(
                'multiline (""") string literal inside a \\(...) interpolation is not supported'
              );
            }
            inString = true;
          } else if (d === "(") {
            depth++;
          } else if (d === ")") {
            depth--;
          }
          j++;
        }
        if (depth !== 0) {
          this.fail(
            inString
              ? "unterminated string literal inside \\(...) interpolation"
              : "unterminated \\(...) interpolation"
          );
        }
        if (buf) {
          parts.push({ str: buf });
          buf = "";
        }
        parts.push({ interp: dedented.slice(i + 2, j - 1).trim() });
        i = j - 1;
      } else {
        if (e === "n") buf += "\n";
        else if (e === "r") buf += "\r";
        else if (e === "t") buf += "\t";
        else if (e === '"') buf += '"';
        else if (e === "\\") buf += "\\";
        else this.fail(`unsupported escape \\${e} in multiline literal`);
        i++;
      }
    }
    if (buf) parts.push({ str: buf });
    return parts;
  }

  /** A literal (single- or multiline) evaluated to a plain string. */
  parseLiteralString() {
    if (this.startsWith('"""')) {
      const parts = this.parseMultilineParts();
      const interp = parts.find((p) => p.interp !== undefined);
      if (interp) {
        this.fail(
          `unexpected interpolation \\(${interp.interp}) — inline expectations must be ` +
            "plain literals (shared templates go through rootWithText)"
        );
      }
      return parts.map((p) => p.str).join("");
    }
    return this.parseSingleLineLiteral();
  }

  /**
   * A string expression: literal (+ literal)* concatenation, or a
   * `Self.rootWithText("text", incomplete: bool)` call expanded through
   * `rootTemplate` (pass null where the call is not allowed).
   */
  parseStringExpr(rootTemplate) {
    this.skipTrivia();
    if (this.startsWith("Self.rootWithText(")) {
      if (!rootTemplate) {
        this.fail("rootWithText call where a plain literal was expected (or its template was not found)");
      }
      this.pos += "Self.rootWithText(".length;
      this.skipTrivia();
      const text = this.parseSingleLineLiteral();
      this.skipTrivia();
      this.expect(",");
      this.skipTrivia();
      this.expect("incomplete:");
      this.skipTrivia();
      let incomplete;
      if (this.startsWith("true")) {
        incomplete = true;
        this.pos += 4;
      } else if (this.startsWith("false")) {
        incomplete = false;
        this.pos += 5;
      } else {
        this.fail("expected a true/false literal for incomplete:");
      }
      this.skipTrivia();
      this.expect(")");
      return evaluateRootWithText(rootTemplate, text, incomplete);
    }
    let out = this.parseLiteralString();
    for (;;) {
      const save = this.pos;
      this.skipTrivia();
      if (this.peek() === "+") {
        this.pos++;
        this.skipTrivia();
        out += this.parseLiteralString();
      } else {
        this.pos = save;
        return out;
      }
    }
  }
}

/** Expand the Swift `rootWithText(_:incomplete:)` template with given args. */
function evaluateRootWithText(parts, text, incomplete) {
  return parts
    .map((p) => {
      if (p.str !== undefined) return p.str;
      if (p.interp === "text") return text;
      if (/^incomplete\s*\?\s*"true"\s*:\s*"false"$/.test(p.interp)) {
        return incomplete ? "true" : "false";
      }
      throw new Error(`unsupported interpolation \\(${p.interp}) in rootWithText template`);
    })
    .join("");
}

/** Locate `func rootWithText(` and parse its multiline body as a template. */
function extractRootWithTextTemplate(source, label) {
  const idx = source.indexOf("func rootWithText(");
  if (idx === -1) return null;
  const open = source.indexOf('"""', idx);
  if (open === -1) {
    throw new Error(`${label}: rootWithText exists but has no multiline literal body`);
  }
  return new SwiftScanner(source, open, `${label} rootWithText`).parseMultilineParts();
}

/**
 * Extract every `@Test func <name>()` that drives `runScenario`, returning
 * `[{ name, steps: [{ text, expected }] }]` with all Swift literal semantics
 * (escapes, dedent, concatenation, rootWithText) already applied.
 */
export function extractSwiftScenarios(source, label = "StreamingSemanticsTests.swift") {
  const template = extractRootWithTextTemplate(source, label);
  const tests = [...source.matchAll(/@Test func (\w+)\(\)/g)];
  const scenarios = [];
  for (let i = 0; i < tests.length; i++) {
    const name = tests[i][1];
    const end = i + 1 < tests.length ? tests[i + 1].index : source.length;
    const body = source.slice(tests[i].index, end);
    if (!body.includes("runScenario(")) continue; // not a streaming scenario test
    const stepsIdx = body.indexOf("steps: [");
    if (stepsIdx === -1) {
      throw new Error(
        `${label}: ${name} calls runScenario but has no "steps: [" array — ` +
          "keep the standard shape so --check can parse it"
      );
    }
    const sc = new SwiftScanner(body, stepsIdx + "steps: [".length, `${label}#${name}`);
    const steps = [];
    for (;;) {
      sc.skipTrivia();
      if (sc.peek() === "]") break;
      sc.expect("(");
      const text = sc.parseStringExpr(null);
      sc.skipTrivia();
      sc.expect(",");
      const expected = sc.parseStringExpr(template);
      sc.skipTrivia();
      sc.expect(")");
      sc.skipTrivia();
      if (sc.peek() === ",") sc.pos++;
      steps.push({ text, expected });
    }
    scenarios.push({ name, steps });
  }
  return scenarios;
}

/** First differing line of two multi-line strings, for readable drift output. */
function firstDiff(swift, oracle) {
  const a = swift.split("\n");
  const b = oracle.split("\n");
  const n = Math.max(a.length, b.length);
  for (let i = 0; i < n; i++) {
    if (a[i] !== b[i]) {
      return (
        `\n      first difference at expected-JSON line ${i + 1}:` +
        `\n        Swift:  ${JSON.stringify(a[i] ?? "<missing>")}` +
        `\n        oracle: ${JSON.stringify(b[i] ?? "<missing>")}`
      );
    }
  }
  return "\n      (differs only in trailing bytes)";
}

/** Compare Swift-extracted scenarios against SCENARIOS + fresh oracle trees. */
async function check(swiftPath) {
  const source = readFileSync(swiftPath, "utf8");
  const swiftScenarios = extractSwiftScenarios(source, swiftPath);
  const swiftByName = new Map(swiftScenarios.map((s) => [s.name, s]));
  const dataByName = new Map(SCENARIOS.map((s) => [s.name, s]));

  const drift = [];
  for (const name of dataByName.keys()) {
    if (!swiftByName.has(name)) {
      drift.push(`scenario "${name}" is in this script's SCENARIOS but has no @Test func in the Swift file`);
    }
  }
  for (const name of swiftByName.keys()) {
    if (!dataByName.has(name)) {
      drift.push(`@Test func ${name} runs a scenario missing from this script's SCENARIOS`);
    }
  }

  const oracle = await createOracle();
  for (const scenario of SCENARIOS) {
    const swift = swiftByName.get(scenario.name);
    if (!swift) continue;
    if (swift.steps.length !== scenario.steps.length) {
      drift.push(
        `${scenario.name}: step count differs (SCENARIOS has ${scenario.steps.length}, Swift has ${swift.steps.length})`
      );
      continue;
    }
    const trees = await runSteps(scenario.steps, oracle);
    scenario.steps.forEach((text, i) => {
      if (swift.steps[i].text !== text) {
        drift.push(
          `${scenario.name} step ${i}: set() text differs` +
            `\n      SCENARIOS: ${JSON.stringify(text)}` +
            `\n      Swift:     ${JSON.stringify(swift.steps[i].text)}`
        );
      }
      if (swift.steps[i].expected !== trees[i]) {
        drift.push(
          `${scenario.name} step ${i}: Swift inline expected JSON differs from fresh oracle output` +
            firstDiff(swift.steps[i].expected, trees[i])
        );
      }
    });
  }

  if (drift.length > 0) {
    console.error(`[check] StreamingSemanticsTests drift: ${drift.length} finding(s)`);
    for (const d of drift) console.error(`  DRIFT: ${d}`);
    console.error(
      "[check] fix: align StreamingSemanticsTests.swift and SCENARIOS in " +
        "probes/regen-streaming-expectations.mjs, regenerating expectations with " +
        "`node probes/regen-streaming-expectations.mjs` (print mode)."
    );
    process.exit(1);
  }
  const stepCount = SCENARIOS.reduce((n, s) => n + s.steps.length, 0);
  console.log(
    `[check] StreamingSemanticsTests in sync: ${SCENARIOS.length} scenarios / ${stepCount} steps ` +
      "match SCENARIOS and fresh oracle output byte-for-byte."
  );
}

// ───────────────────────────────────────────────────────────────────────────
// entry point
// ───────────────────────────────────────────────────────────────────────────

// Run only when executed directly (`node probes/regen-streaming-expectations.mjs`);
// importing this module (e.g. from probes/scanner-tests.mjs) must not print.
const isMain =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;

if (isMain) {
  const args = process.argv.slice(2);
  const checkIdx = args.indexOf("--check");
  if (checkIdx !== -1) {
    const swiftPath = args[checkIdx + 1];
    if (!swiftPath) {
      console.error("usage: node probes/regen-streaming-expectations.mjs --check <StreamingSemanticsTests.swift>");
      process.exit(2);
    }
    try {
      await check(swiftPath);
    } catch (e) {
      console.error("[check] FAILED:", e instanceof Error ? e.message : e);
      process.exit(1);
    }
  } else {
    const oracle = await createOracle();
    for (const scenario of SCENARIOS) {
      const trees = await runSteps(scenario.steps, oracle);
      trees.forEach((tree, i) => {
        process.stdout.write(`=== ${scenario.name} step ${i} ===\n${tree}`);
      });
    }
  }
}
