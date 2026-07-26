/**
 * Differential-fuzz orchestrator.
 *
 * Generates (or reads) a campaign from `gen-fuzz-corpus.mjs`, replays it through
 * all THREE implementations — the JS reference oracle, the Swift port
 * (`ios/Packages/OpenUILang`) and the Kotlin port (`android/openui-lang`) —
 * and byte-compares the three output streams step by step. Any divergence is
 * reported with the failing program and both trees, and the process exits
 * non-zero.
 *
 * Usage (from spec/fixtures/generator):
 *   node probes/run-differential.mjs                        # pinned smoke campaign
 *   node probes/run-differential.mjs --campaign prefix      # exhaustive prefix
 *   node probes/run-differential.mjs --campaign mutation
 *   node probes/run-differential.mjs --campaign nonmonotonic
 *   node probes/run-differential.mjs --campaign all
 *
 * Options:
 *   --campaign NAME[,NAME]   prefix | nonmonotonic | mutation | pinned | all
 *   --campaign-file FILE     replay a pre-generated campaign instead
 *   --out-dir DIR            where the three output streams land
 *                            (default: a temp dir, removed unless --keep)
 *   --keep                   keep the output streams for `cmp`/`diff`
 *   --skip-swift             run only the programs that are available
 *   --skip-kotlin
 *   --max-divergences N      how many divergences to print (default 5)
 *   --mutations-per-fixture N
 *
 * Exit codes: 0 = all programs agree, 1 = divergence(s), 2 = usage/setup error.
 */
import { mkdtempSync, mkdirSync, rmSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import os from "node:os";
import path from "node:path";
import {
  buildCampaign,
  stepCountsByCampaign,
  stepText,
} from "./gen-fuzz-corpus.mjs";
import { createOracle, serializeResult } from "./expected-tree.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, "..", "..", "..", "..");
const SWIFT_PACKAGE = path.join(REPO_ROOT, "ios", "Packages", "OpenUILang");
const ANDROID_DIR = path.join(REPO_ROOT, "android");
/** The one contract all three implementations load. */
const SCHEMA = path.join(REPO_ROOT, "spec", "contract", "genos.schema.json");

const args = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = args.indexOf(name);
  return i === -1 ? fallback : args[i + 1];
};
const has = (name) => args.includes(name);

const campaignName = flag("--campaign", "pinned");
const campaignFile = flag("--campaign-file");
const keep = has("--keep");
const skipSwift = has("--skip-swift");
const skipKotlin = has("--skip-kotlin");
const maxDivergences = Number(flag("--max-divergences", "5"));
const perFixture = flag("--mutations-per-fixture");

const outDir = flag("--out-dir") ?? mkdtempSync(path.join(os.tmpdir(), "openui-difffuzz-"));
mkdirSync(outDir, { recursive: true });

const log = (...a) => console.log(...a);
const secs = (ms) => (ms / 1000).toFixed(2);

// ── 1. Campaign ──────────────────────────────────────────────────────────────

let campaign;
let campaignPath;
if (campaignFile) {
  campaignPath = path.resolve(campaignFile);
  campaign = JSON.parse(readFileSync(campaignPath, "utf8"));
  log(`[differential] campaign file ${campaignPath}`);
} else {
  const t0 = Date.now();
  campaign = buildCampaign(campaignName, {
    mutationsPerFixture: perFixture ? Number(perFixture) : undefined,
  });
  campaignPath = path.join(outDir, "campaign.json");
  writeFileSync(campaignPath, JSON.stringify(campaign) + "\n");
  log(`[differential] generated campaign "${campaignName}" in ${secs(Date.now() - t0)}s`);
}
const counts = stepCountsByCampaign(campaign);
log(
  `[differential] seed=${campaign.seed ?? "n/a"} sessions=${campaign.sessions.length} ` +
    `steps=${campaign.sessions.reduce((a, s) => a + s.steps.length, 0)} ` +
    `(${Object.entries(counts)
      .map(([k, v]) => `${k}=${v}`)
      .join(" ")})`
);

// ── 2. Programs ──────────────────────────────────────────────────────────────

/** The canonical per-step record every program emits. */
const header = (name, index) => `=== ${name} step ${index} ===\n`;

/**
 * Body written for a step where the REFERENCE ITSELF throws — there is no
 * expected tree, so the step cannot be compared against the oracle.
 *
 * Two shapes reach it, both in `lib/serialize.mjs` and both `Object.keys` on a
 * nullish value: a `null`/`undefined` ACTION STEP (`{steps: [null]}`,
 * serialize.mjs:51) and an object that duck-types as an element but has no
 * `props` (`{type: "element", typeName: "X"}`, serialize.mjs:84). Prefix and
 * mutation fuzzing over the element-shaped fixtures (094-097) can construct
 * both by truncating or damaging a literal. The fixture generator dies the same
 * way, which is why no fixture pins these shapes and both READMEs carry them as
 * the "serializer-level TypeError" deviation.
 *
 * Rather than crash the run or silently drop the step, those steps are compared
 * BETWEEN THE PORTS instead — the two must still agree with each other — and
 * the count is reported.
 */
const ORACLE_THREW = "<<oracle-threw>>\n";

const timings = {};
/** Steps where the reference implementation threw (see ORACLE_THREW). */
const oracleThrows = [];

/** JS reference oracle — in-process, same pipeline as the fixture generator. */
async function runNode() {
  const t0 = Date.now();
  const oracle = await createOracle();
  const chunks = [];
  // lang-core's evaluator console.warn's on unknown component names, which fuzz
  // inputs produce constantly. Count them instead of flooding the CI log.
  const realWarn = console.warn;
  let warnings = 0;
  console.warn = () => {
    warnings++;
  };
  try {
    for (const session of campaign.sessions) {
      const sp = oracle.langCore.createStreamingParser(oracle.schema, oracle.library.root);
      session.steps.forEach((step, index) => {
        let tree;
        try {
          tree = serializeResult(oracle, sp.set(stepText(session, step)));
        } catch (e) {
          oracleThrows.push({ step: `=== ${session.name} step ${index} ===`, error: String(e) });
          tree = ORACLE_THREW;
        }
        chunks.push(header(session.name, index), tree.endsWith("\n") ? tree : tree + "\n");
      });
    }
  } finally {
    console.warn = realWarn;
  }
  if (warnings) log(`[differential] node: ${warnings} lang-core warning(s) suppressed`);
  const file = path.join(outDir, "node.txt");
  writeFileSync(file, chunks.join(""));
  timings.node = (Date.now() - t0) / 1000;
  log(`[differential] node    ok  ${secs(Date.now() - t0)}s -> ${file}`);
  return file;
}

function run(cmd, argv, opts = {}) {
  return spawnSync(cmd, argv, { encoding: "utf8", maxBuffer: 1 << 28, ...opts });
}

/** Swift port. Builds the driver in release, then replays the campaign. */
function runSwift() {
  const build = run("swift", ["build", "-c", "release", "--product", "openui-fuzz-driver"], {
    cwd: SWIFT_PACKAGE,
    stdio: ["ignore", "inherit", "inherit"],
  });
  if (build.status !== 0) {
    console.error("[differential] swift build FAILED");
    process.exit(2);
  }
  const binPath = run("swift", ["build", "-c", "release", "--show-bin-path"], {
    cwd: SWIFT_PACKAGE,
  }).stdout.trim();
  const file = path.join(outDir, "swift.txt");
  const t0 = Date.now();
  const res = run(
    path.join(binPath, "openui-fuzz-driver"),
    [campaignPath, "--out", file, "--schema", SCHEMA],
    { cwd: REPO_ROOT }
  );
  timings.swift = (Date.now() - t0) / 1000;
  if (res.status !== 0) {
    console.error(`[differential] swift driver FAILED\n${res.stderr ?? ""}`);
    process.exit(2);
  }
  process.stderr.write(res.stderr ?? "");
  log(`[differential] swift   ok  ${secs(Date.now() - t0)}s -> ${file}`);
  return file;
}

/** Kotlin port, via the module's `fuzzDriver` JavaExec task. */
function runKotlin() {
  const file = path.join(outDir, "kotlin.txt");
  const t0 = Date.now();
  const res = run(
    path.join(ANDROID_DIR, "gradlew"),
    [
      "--console=plain",
      "-q",
      ":openui-lang:fuzzDriver",
      `-PfuzzCampaign=${campaignPath}`,
      `-PfuzzOut=${file}`,
      `-PfuzzSchema=${SCHEMA}`,
    ],
    { cwd: ANDROID_DIR }
  );
  timings.kotlin = (Date.now() - t0) / 1000;
  if (res.status !== 0) {
    console.error(`[differential] kotlin driver FAILED\n${res.stdout ?? ""}\n${res.stderr ?? ""}`);
    process.exit(2);
  }
  // The driver's own elapsed line (excludes Gradle start-up).
  const own = (res.stderr ?? "").split("\n").find((l) => l.startsWith("[fuzz-driver:kotlin]"));
  if (own) {
    process.stderr.write(own + "\n");
    const m = own.match(/elapsed=([\d.]+)s/);
    if (m) timings.kotlinDriverOnly = Number(m[1]);
  }
  log(`[differential] kotlin  ok  ${secs(Date.now() - t0)}s (incl. Gradle) -> ${file}`);
  return file;
}

// ── 3. Three-way comparison ──────────────────────────────────────────────────

/**
 * Split a program's stream into `[header, tree]` records. The header line is
 * unambiguous: trees are `stableStringify` JSON documents, which never contain a
 * line starting with "=== ".
 */
function records(file) {
  const text = readFileSync(file, "utf8");
  if (text.length === 0) return [];
  if (!text.startsWith("=== ")) {
    throw new Error(`${path.basename(file)}: does not start with a step header`);
  }
  // Every tree line is either indented or a bare brace, so "\n=== " only ever
  // introduces the next record.
  const starts = [0];
  for (let i = text.indexOf("\n=== "); i !== -1; i = text.indexOf("\n=== ", i + 1)) {
    starts.push(i + 1);
  }
  const out = [];
  for (let i = 0; i < starts.length; i++) {
    const s = starts[i];
    const nl = text.indexOf("\n", s);
    const end = i + 1 < starts.length ? starts[i + 1] : text.length;
    out.push([text.slice(s, nl), text.slice(nl + 1, end)]);
  }
  return out;
}

function firstByteDivergence(a, b) {
  const ab = Buffer.from(a, "utf8");
  const bb = Buffer.from(b, "utf8");
  let k = 0;
  while (k < Math.min(ab.length, bb.length) && ab[k] === bb[k]) k++;
  return { offset: k, aLen: ab.length, bLen: bb.length };
}

function excerpt(tree, offset, context = 120) {
  const b = Buffer.from(tree, "utf8");
  const lo = Math.max(0, offset - context);
  const hi = Math.min(b.length, offset + context);
  return b
    .slice(lo, hi)
    .toString("utf8")
    .replace(/\n/g, "\\n")
    .replace(/\t/g, "\\t");
}

(async () => {
  const streams = { node: await runNode() };
  if (!skipSwift) streams.swift = runSwift();
  if (!skipKotlin) streams.kotlin = runKotlin();

  const parsed = {};
  for (const [program, file] of Object.entries(streams)) parsed[program] = records(file);

  const programs = Object.keys(parsed);
  const expectedSteps = campaign.sessions.reduce((a, s) => a + s.steps.length, 0);
  const divergences = [];

  // Pinned campaigns carry the oracle's own expectations — a regression gate on
  // the JS reference itself, checked as a fourth "program".
  const pinned = [];
  for (const session of campaign.sessions) {
    if (!session.expected) continue;
    session.expected.forEach((tree, index) => {
      pinned.push([`=== ${session.name} step ${index} ===`, tree.endsWith("\n") ? tree : tree + "\n"]);
    });
  }
  if (pinned.length) {
    parsed["pinned-expected"] = pinned;
    programs.push("pinned-expected");
  }

  for (const program of programs) {
    if (parsed[program].length !== expectedSteps) {
      divergences.push({
        step: "-",
        kind: "step-count",
        detail:
          `${program} emitted ${parsed[program].length} records, ` +
          `campaign has ${expectedSteps} steps`,
      });
    }
  }

  const total = Math.min(...programs.map((p) => parsed[p].length));
  const others = programs.filter((p) => p !== "node");
  let compared = 0;
  let skipped = 0;
  for (let i = 0; i < total; i++) {
    const [refHead, refTree] = parsed.node[i];
    // No oracle answer for this step: hold the PORTS to each other instead.
    if (refTree === ORACLE_THREW) {
      skipped++;
      compared++;
      if (others.length > 1) {
        const [baseHead, baseTree] = parsed[others[0]][i];
        for (const program of others.slice(1)) {
          const [head, tree] = parsed[program][i];
          if (head === baseHead && tree === baseTree) continue;
          const d = firstByteDivergence(baseTree, tree);
          divergences.push({
            step: baseHead,
            otherStep: head,
            program: `${program} (vs ${others[0]}; oracle threw)`,
            kind: head !== baseHead ? "step-desync" : "tree",
            offset: d.offset,
            nodeTree: baseTree,
            otherTree: tree,
            lengths: [d.aLen, d.bLen],
          });
        }
      }
      if (divergences.length >= maxDivergences) break;
      continue;
    }
    for (const program of programs) {
      if (program === "node") continue;
      const [head, tree] = parsed[program][i];
      if (head === refHead && tree === refTree) continue;
      const d = firstByteDivergence(refTree, tree);
      divergences.push({
        step: refHead,
        otherStep: head,
        program,
        kind: head !== refHead ? "step-desync" : "tree",
        offset: d.offset,
        nodeTree: refTree,
        otherTree: tree,
        lengths: [d.aLen, d.bLen],
      });
    }
    compared++;
    if (divergences.length >= maxDivergences) break;
  }

  // ── Summary ────────────────────────────────────────────────────────────────
  log("");
  log("──────────────── differential fuzz summary ────────────────");
  log(`campaign      : ${campaign.campaigns?.join(",") ?? campaignName}`);
  log(`sessions      : ${campaign.sessions.length}`);
  log(`steps         : ${expectedSteps}   (compared: ${compared})`);
  if (skipped) {
    log(
      `oracle threw  : ${skipped} step(s) — no expected tree exists ` +
        `(serialize.mjs Object.keys on a nullish value); ports cross-compared instead`
    );
    for (const t of oracleThrows.slice(0, 3)) log(`                ${t.step}`);
    if (oracleThrows.length > 3) log(`                … and ${oracleThrows.length - 3} more`);
  }
  log(`programs      : ${programs.join(", ")}`);
  for (const [k, v] of Object.entries(timings)) log(`runtime ${k.padEnd(6)}: ${v.toFixed(2)}s`);
  log(`divergences   : ${divergences.length}`);
  log("───────────────────────────────────────────────────────────");

  if (divergences.length === 0) {
    log("[differential] PASS — all programs byte-identical on every step.");
    if (!keep && !flag("--out-dir")) rmSync(outDir, { recursive: true, force: true });
    else log(`[differential] streams kept in ${outDir}`);
    process.exit(0);
  }

  console.error("");
  console.error(`[differential] FAIL — ${divergences.length} divergence(s), first ${Math.min(
    divergences.length,
    maxDivergences
  )} shown:`);
  for (const d of divergences.slice(0, maxDivergences)) {
    console.error("");
    console.error("═══════════════════════════════════════════════════════════");
    if (d.kind === "step-count") {
      console.error(`DIVERGENCE (step-count): ${d.detail}`);
      continue;
    }
    console.error(`DIVERGENCE (${d.kind}) in ${d.program}`);
    console.error(`  step        : ${d.step}`);
    if (d.kind === "step-desync") console.error(`  ${d.program} was at : ${d.otherStep}`);
    console.error(
      `  byte offset : ${d.offset} (node ${d.lengths[0]} bytes, ${d.program} ${d.lengths[1]} bytes)`
    );
    console.error(`  node   tree : …${excerpt(d.nodeTree, d.offset)}…`);
    console.error(`  ${d.program.padEnd(6)} tree : …${excerpt(d.otherTree, d.offset)}…`);
  }
  console.error("═══════════════════════════════════════════════════════════");
  console.error(`[differential] full streams: ${outDir}`);
  for (const program of Object.keys(streams)) {
    if (program === "node") continue;
    console.error(
      `[differential] reproduce: cmp ${path.join(outDir, "node.txt")} ` +
        `${path.join(outDir, `${program}.txt`)}`
    );
  }
  process.exit(1);
})().catch((e) => {
  console.error("[differential] ERROR:", e);
  process.exit(2);
});
