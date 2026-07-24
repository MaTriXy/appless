/**
 * Phase 0 exit-criterion gate (prompt half): the system prompt assembled from
 * spec/prompt/ sources must be BYTE-IDENTICAL to the SYSTEM_PROMPT export the
 * RN app ships in src/genos/generated/system-prompt.ts.
 *
 * Exit 0 on a byte-identical match; exit 1 with a first-divergence diff
 * otherwise. Also refreshes system-prompt.generated.txt so the committed
 * artifact never goes stale when the check passes.
 *
 * Usage: node spec/prompt/check-prompt.mjs
 */
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { buildPrompt, GENERATED_OUT } from "./build-prompt.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "../..");
const EMBEDDED_TS = path.join(repoRoot, "src/genos/generated/system-prompt.ts");

/** Extract the SYSTEM_PROMPT string literal (a JSON string) from the TS module. */
function readEmbeddedPrompt() {
  const src = readFileSync(EMBEDDED_TS, "utf8");
  const m = src.match(/export const SYSTEM_PROMPT = ("(?:[^"\\]|\\.)*");/);
  if (!m) throw new Error(`[check-prompt] SYSTEM_PROMPT export not found in ${EMBEDDED_TS}`);
  return JSON.parse(m[1]);
}

function firstDivergence(a, b) {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) if (a[i] !== b[i]) return i;
  return a.length === b.length ? -1 : n;
}

const embedded = readEmbeddedPrompt();
const assembled = await buildPrompt();
writeFileSync(GENERATED_OUT, assembled);

if (assembled === embedded) {
  console.log(`[check-prompt] OK - byte-identical (${assembled.length} chars).`);
  process.exit(0);
}

const i = firstDivergence(assembled, embedded);
const ctx = 120;
const line = embedded.slice(0, i).split("\n").length;
console.error(`[check-prompt] MISMATCH: assembled prompt differs from embedded SYSTEM_PROMPT.`);
console.error(`  lengths: assembled=${assembled.length} embedded=${embedded.length}`);
console.error(`  first divergence at char ${i} (embedded line ${line})`);
console.error(`--- embedded ---\n${JSON.stringify(embedded.slice(Math.max(0, i - ctx), i + ctx))}`);
console.error(`--- assembled --\n${JSON.stringify(assembled.slice(Math.max(0, i - ctx), i + ctx))}`);
process.exit(1);
