/**
 * Scanner-level tests for the SwiftScanner in regen-streaming-expectations.mjs
 * (run by the generator's `npm test`, before the streaming drift gate).
 *
 * Synthetic Swift snippets prove that the multiline-literal `\(...)`
 * interpolation capture tracks quote/escape state correctly (escaped quotes,
 * escaped backslashes, and parens inside string literals within the
 * expression), that genuinely unsupported shapes still fail loudly with a
 * useful message (never a silent misparse), and — as a regression gate — that
 * the real StreamingSemanticsTests.swift still extracts byte-for-byte against
 * the SCENARIOS table.
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { SwiftScanner, SCENARIOS, extractSwiftScenarios } from "./regen-streaming-expectations.mjs";

let failures = 0;
const fail = (msg) => {
  failures++;
  console.error(`  FAIL: ${msg}`);
};
const ok = (msg) => console.log(`  ok: ${msg}`);

/** Parse a snippet whose first character is the opening `"""`. */
function parseParts(snippet, label) {
  return new SwiftScanner(snippet, 0, label).parseMultilineParts();
}

function expectParts(name, snippet, wantParts) {
  let got;
  try {
    got = parseParts(snippet, name);
  } catch (e) {
    fail(`${name}: threw unexpectedly: ${e instanceof Error ? e.message : e}`);
    return;
  }
  const gotJson = JSON.stringify(got);
  const wantJson = JSON.stringify(wantParts);
  if (gotJson !== wantJson) {
    fail(`${name}: parts mismatch\n      want: ${wantJson}\n      got:  ${gotJson}`);
  } else {
    ok(name);
  }
}

function expectFailure(name, snippet, msgPattern) {
  try {
    const got = parseParts(snippet, name);
    fail(
      `${name}: expected a loud parse error, got a successful parse: ${JSON.stringify(got)}`
    );
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (msgPattern.test(msg)) {
      ok(`${name} (fails loudly: ${JSON.stringify(msg)})`);
    } else {
      fail(`${name}: error message ${JSON.stringify(msg)} does not match ${msgPattern}`);
    }
  }
}

// ── 1. interpolation quote/escape handling ─────────────────────────────────
console.log("[scanner-tests] interpolation quote/escape handling");

// (a) Escaped quote inside a string literal within \(...), with unbalanced
// parens inside that string — the capture must not end early at the `)`.
expectParts(
  "escaped quote (and parens) inside interpolated string",
  ['"""', 'prefix \\(f("a\\")(b")) suffix', '"""'].join("\n"),
  [{ str: "prefix " }, { interp: 'f("a\\")(b")' }, { str: " suffix" }]
);

// Escaped backslash right before the closing quote: \\ must not eat the quote.
expectParts(
  "escaped backslash before closing quote inside interpolated string",
  ['"""', 'a \\(g("x\\\\")) b', '"""'].join("\n"),
  [{ str: "a " }, { interp: 'g("x\\\\")' }, { str: " b" }]
);

// The real rootWithText template shape: plain strings inside a ternary.
expectParts(
  "ternary with plain string literals (rootWithText shape)",
  ['"""', '{ "flag": \\(incomplete ? "true" : "false") }', '"""'].join("\n"),
  [{ str: '{ "flag": ' }, { interp: 'incomplete ? "true" : "false"' }, { str: " }" }]
);

// Nested parens outside strings still balance.
expectParts(
  "nested parens outside strings",
  ['"""', 'n=\\(max(a, min(b, c)))!', '"""'].join("\n"),
  [{ str: "n=" }, { interp: "max(a, min(b, c))" }, { str: "!" }]
);

// ── 2. unsupported shapes fail loudly ──────────────────────────────────────
console.log("[scanner-tests] unsupported shapes fail loudly");

expectFailure(
  "nested interpolation inside interpolated string",
  ['"""', 'x \\("a \\(y) b") z', '"""'].join("\n"),
  /nested \\\(\.\.\.\) interpolation inside a string literal/
);

expectFailure(
  "multiline string literal inside interpolation",
  ['"""', 'x \\(f(""")) z', '"""'].join("\n"),
  /multiline \(\"\"\"\) string literal inside a \\\(\.\.\.\) interpolation is not supported/
);

expectFailure(
  "unterminated string literal inside interpolation",
  ['"""', 'x \\(f("abc) z', '"""'].join("\n"),
  /unterminated string literal inside \\\(\.\.\.\) interpolation/
);

expectFailure(
  "unterminated interpolation (no string involved)",
  ['"""', 'x \\(f(y z', '"""'].join("\n"),
  /unterminated \\\(\.\.\.\) interpolation/
);

// ── 3. regression: the real Swift test file still extracts ─────────────────
console.log("[scanner-tests] StreamingSemanticsTests.swift extraction regression");

const failuresBeforeRegression = failures;
const swiftPath = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../../../ios/Packages/OpenUILang/Tests/OpenUILangTests/StreamingSemanticsTests.swift"
);
try {
  const source = readFileSync(swiftPath, "utf8");
  const swiftScenarios = extractSwiftScenarios(source, swiftPath);
  const swiftByName = new Map(swiftScenarios.map((s) => [s.name, s]));

  if (swiftScenarios.length !== SCENARIOS.length) {
    fail(
      `scenario count differs: Swift file has ${swiftScenarios.length}, SCENARIOS has ${SCENARIOS.length}`
    );
  }
  for (const scenario of SCENARIOS) {
    const swift = swiftByName.get(scenario.name);
    if (!swift) {
      fail(`scenario "${scenario.name}" missing from Swift extraction`);
      continue;
    }
    if (swift.steps.length !== scenario.steps.length) {
      fail(
        `${scenario.name}: step count differs (Swift ${swift.steps.length}, SCENARIOS ${scenario.steps.length})`
      );
      continue;
    }
    scenario.steps.forEach((text, i) => {
      if (swift.steps[i].text !== text) {
        fail(
          `${scenario.name} step ${i}: extracted set() text is not byte-identical to SCENARIOS` +
            `\n      SCENARIOS: ${JSON.stringify(text)}` +
            `\n      Swift:     ${JSON.stringify(swift.steps[i].text)}`
        );
      }
      const expected = swift.steps[i].expected;
      try {
        JSON.parse(expected);
      } catch {
        fail(`${scenario.name} step ${i}: extracted expected tree is not valid JSON`);
      }
      if (!expected.endsWith("\n")) {
        fail(`${scenario.name} step ${i}: extracted expected tree lost its trailing newline`);
      }
    });
  }
  if (failures === failuresBeforeRegression) {
    const stepCount = SCENARIOS.reduce((n, s) => n + s.steps.length, 0);
    ok(
      `${swiftScenarios.length} scenarios / ${stepCount} steps extracted; set() texts ` +
        "byte-identical to SCENARIOS, all expected trees valid JSON"
    );
  }
} catch (e) {
  fail(`extraction threw: ${e instanceof Error ? e.message : e}`);
}

// Note: byte-for-byte comparison of every extracted expectation against a
// freshly generated oracle tree is the job of `npm run check:streaming`,
// which `npm test` runs right after this file.

if (failures > 0) {
  console.error(`[scanner-tests] ${failures} failure(s).`);
  process.exit(1);
}
console.log("[scanner-tests] all checks passed.");
