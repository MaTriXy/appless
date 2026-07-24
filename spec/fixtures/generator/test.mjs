/**
 * Generator self-test:
 *   1. Corpus integrity — every *.oui has a matching *.expected.json (and no
 *      orphaned *.expected.json without its *.oui).
 *   2. Determinism — run generation twice into two temp dirs and byte-diff.
 *   3. Freshness — the committed *.expected.json files are byte-identical to
 *      a fresh regeneration (catches stale fixtures after contract/corpus
 *      edits).
 */
import { readFileSync, readdirSync, statSync, mkdtempSync, rmSync } from "node:fs";
import path from "node:path";
import os from "node:os";
import { generateAll, collectFixtures, FIXTURES_ROOT } from "./generate.mjs";

let failures = 0;
const fail = (msg) => {
  failures++;
  console.error(`  FAIL: ${msg}`);
};
const ok = (msg) => console.log(`  ok: ${msg}`);

function collectExpected(root) {
  const out = [];
  const walk = (dir) => {
    for (const name of readdirSync(dir).sort()) {
      const p = path.join(dir, name);
      const st = statSync(p);
      if (st.isDirectory()) {
        if (name === "generator" || name === "node_modules") continue;
        walk(p);
      } else if (name.endsWith(".expected.json")) {
        out.push(p);
      }
    }
  };
  walk(root);
  return out;
}

// ── 1. corpus integrity ─────────────────────────────────────────────────────
console.log("[test] corpus integrity");
const ouiFiles = collectFixtures();
const expectedFiles = collectExpected(FIXTURES_ROOT);
const expectedSet = new Set(expectedFiles);
for (const oui of ouiFiles) {
  const want = oui.replace(/\.oui$/, ".expected.json");
  if (!expectedSet.has(want)) fail(`missing expected tree for ${path.relative(FIXTURES_ROOT, oui)}`);
  expectedSet.delete(want);
}
for (const orphan of expectedSet) {
  fail(`orphaned expected tree with no .oui source: ${path.relative(FIXTURES_ROOT, orphan)}`);
}
if (ouiFiles.length < 60) fail(`corpus has only ${ouiFiles.length} fixtures (target 60-80)`);
ok(`${ouiFiles.length} fixtures, all paired`);

// ── 2 + 3. determinism & freshness ──────────────────────────────────────────
console.log("[test] determinism (double generation into temp dirs)");
const tmpA = mkdtempSync(path.join(os.tmpdir(), "oui-fixtures-a-"));
const tmpB = mkdtempSync(path.join(os.tmpdir(), "oui-fixtures-b-"));
try {
  await generateAll(tmpA);
  await generateAll(tmpB);
  let diffs = 0;
  for (const oui of ouiFiles) {
    const rel = path.relative(FIXTURES_ROOT, oui).replace(/\.oui$/, ".expected.json");
    const a = readFileSync(path.join(tmpA, rel), "utf8");
    const b = readFileSync(path.join(tmpB, rel), "utf8");
    if (a !== b) {
      diffs++;
      fail(`non-deterministic output for ${rel}`);
    }
    const committedPath = path.join(FIXTURES_ROOT, rel);
    let committed = null;
    try {
      committed = readFileSync(committedPath, "utf8");
    } catch {
      /* missing already reported above */
    }
    if (committed !== null && committed !== a) {
      fail(`stale committed expected tree: ${rel} (re-run \`npm run generate\`)`);
    }
  }
  if (diffs === 0) ok("two runs byte-identical; committed trees fresh");
} finally {
  rmSync(tmpA, { recursive: true, force: true });
  rmSync(tmpB, { recursive: true, force: true });
}

if (failures > 0) {
  console.error(`[test] ${failures} failure(s).`);
  process.exit(1);
}
console.log("[test] all checks passed.");
