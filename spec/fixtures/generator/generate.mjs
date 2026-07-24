/**
 * Golden-fixture generator: parse every spec/fixtures/**\/*.oui file with the
 * REAL @openuidev/lang-core parser + the REAL GenOS contract, and write the
 * expected tree next to it as NNN-name.expected.json.
 *
 * Pipeline per fixture (mirrors the app's steady-state Renderer pipeline;
 * see spec/openui-lang.md §1 and §10):
 *   1. fresh createStreamingParser(library.toJSONSchema(), library.root)
 *   2. result = sp.set(<file bytes, verbatim>)   — same entry point the
 *      Renderer uses on every store flush (full text, not deltas). Partial
 *      fixtures are simply prefix-truncated files; `isStreaming` does not
 *      change parsing (spec §10.7), so the same call captures the streaming
 *      partial tree incl. meta.incomplete / partial flags.
 *   3. store = createStore(); store.initialize(result.stateDeclarations, {})
 *   4. evaluateElementProps(result.root, { ctx, library, store, errors })
 *      with the same EvaluationContext shape react-lang builds (getState
 *      unwraps {value, componentType}; resolveRef has no query manager —
 *      AppLess never uses Query/Mutation).
 *   5. serialize deterministically (sorted keys) and write.
 *
 * Usage: node generate.mjs [--out <dir>]
 *   --out writes the .expected.json files into <dir> (mirroring the fixture
 *   directory layout) instead of next to the .oui files. Used by test.mjs.
 */
import { readFileSync, writeFileSync, readdirSync, mkdirSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { loadRuntime, buildLibrary } from "./lib/build-library.mjs";
import { serializeExpected, stableStringify } from "./lib/serialize.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
export const FIXTURES_ROOT = path.resolve(here, "..");

/** Recursively collect .oui files under root (skips generator/ and node_modules). */
export function collectFixtures(root = FIXTURES_ROOT) {
  const out = [];
  const walk = (dir) => {
    for (const name of readdirSync(dir).sort()) {
      const p = path.join(dir, name);
      const st = statSync(p);
      if (st.isDirectory()) {
        if (name === "generator" || name === "node_modules") continue;
        walk(p);
      } else if (name.endsWith(".oui")) {
        out.push(p);
      }
    }
  };
  walk(root);
  return out;
}

/** Unwrap { value, componentType } wrappers exactly like useOpenUIState does. */
function unwrapFieldValue(v) {
  if (v && typeof v === "object" && !Array.isArray(v) && "value" in v) return v.value;
  return v;
}

export async function generateAll(outRoot = null) {
  const { langCore } = await loadRuntime();
  const library = await buildLibrary();
  const schema = library.toJSONSchema();
  const fixtures = collectFixtures();
  if (fixtures.length === 0) throw new Error("no .oui fixtures found");

  const written = [];
  for (const ouiPath of fixtures) {
    const source = readFileSync(ouiPath, "utf8"); // verbatim — no trimming
    const sp = langCore.createStreamingParser(schema, library.root);
    const result = sp.set(source);

    // Steady-state runtime evaluation (store initialized from declarations).
    const store = langCore.createStore();
    store.initialize(result.stateDeclarations ?? {}, {});
    const evaluationContext = {
      getState: (name) => unwrapFieldValue(store.get(name)),
      resolveRef: () => undefined, // no QueryManager — AppLess has no tools here
    };
    const errors = [];
    let evaluatedRoot = null;
    if (result.root) {
      evaluatedRoot = langCore.evaluateElementProps(result.root, {
        ctx: evaluationContext,
        library,
        store,
        errors,
      });
    }

    const expected = serializeExpected(result, evaluatedRoot, errors);
    const rel = path.relative(FIXTURES_ROOT, ouiPath);
    const outPath = path.join(outRoot ?? FIXTURES_ROOT, rel.replace(/\.oui$/, ".expected.json"));
    mkdirSync(path.dirname(outPath), { recursive: true });
    writeFileSync(outPath, stableStringify(expected));
    written.push(outPath);
  }
  return { fixtures, written };
}

const invokedDirectly = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  const outIdx = process.argv.indexOf("--out");
  const outRoot = outIdx !== -1 ? path.resolve(process.argv[outIdx + 1]) : null;
  generateAll(outRoot)
    .then(({ written }) => {
      console.log(`[generate] wrote ${written.length} expected trees${outRoot ? ` to ${outRoot}` : ""}.`);
    })
    .catch((e) => {
      console.error("[generate] FAILED:", e);
      process.exit(1);
    });
}
