/**
 * Probe oracle driver: run an arbitrary openui-lang program (or a sequence of
 * streaming `set()` steps) through the REAL JS reference implementation and
 * print the serialized expected tree(s), byte-identical to the fixture
 * generator's output format.
 *
 * This is the committed, regenerable replacement for the throwaway scripts
 * that originally produced the JS-oracle-derived expectations referenced by
 * ios/Packages/OpenUILang (StreamingSemanticsTests inline trees, differential
 * probe sweeps). It reuses the generator's own pipeline verbatim:
 * lib/build-library.mjs (real lang-core + real GenOS contract) and
 * lib/serialize.mjs (expected-tree serialization) — the exact same
 * parse -> store.initialize -> evaluateElementProps -> serializeExpected
 * chain as generate.mjs.
 *
 * Usage:
 *   node probes/expected-tree.mjs <program.oui>
 *       One fresh streaming parser, ONE set() with the file's verbatim bytes
 *       (identical to how generate.mjs treats a fixture). The serialized tree
 *       is printed raw to stdout — suitable for byte-comparison against the
 *       Swift port's TreeSerializer output.
 *
 *   node probes/expected-tree.mjs --steps <steps.json>
 *       steps.json is a JSON array of strings. All steps are fed to ONE
 *       streaming parser in order (each string is the full accumulated text,
 *       exactly like the Renderer's store-flush contract, spec §10). Each
 *       step's tree is printed preceded by an "=== step N ===" marker line.
 *
 *   Add --raw with --steps to print only the LAST step's tree, raw (no
 *   markers), for byte-comparison.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { loadRuntime, buildLibrary } from "../lib/build-library.mjs";
import { serializeExpected, stableStringify } from "../lib/serialize.mjs";

/** Unwrap { value, componentType } wrappers exactly like useOpenUIState does. */
function unwrapFieldValue(v) {
  if (v && typeof v === "object" && !Array.isArray(v) && "value" in v) return v.value;
  return v;
}

/** Load the real lang-core + GenOS contract once. */
export async function createOracle() {
  const { langCore } = await loadRuntime();
  const library = await buildLibrary();
  return { langCore, library, schema: library.toJSONSchema() };
}

/**
 * Serialize one ParseResult through the steady-state runtime pipeline —
 * copied from generate.mjs step 3-5: fresh store initialized from the
 * result's state declarations, evaluateElementProps with the react-lang
 * EvaluationContext shape (no QueryManager), then serializeExpected.
 * Returns the stableStringify'd JSON document (trailing newline included).
 */
export function serializeResult(oracle, result) {
  const { langCore, library } = oracle;
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
  return stableStringify(serializeExpected(result, evaluatedRoot, errors));
}

/**
 * Feed `steps` (array of full-accumulated-text strings) to ONE fresh
 * streaming parser and return each step's serialized tree.
 */
export async function runSteps(steps, oracle = null) {
  const o = oracle ?? (await createOracle());
  const sp = o.langCore.createStreamingParser(o.schema, o.library.root);
  return steps.map((text) => serializeResult(o, sp.set(text)));
}

const invokedDirectly =
  process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  const args = process.argv.slice(2);
  const raw = args.includes("--raw");
  const stepsIdx = args.indexOf("--steps");
  try {
    if (stepsIdx !== -1) {
      const stepsPath = args[stepsIdx + 1];
      if (!stepsPath) throw new Error("--steps requires a JSON file path");
      const steps = JSON.parse(readFileSync(stepsPath, "utf8"));
      if (!Array.isArray(steps) || steps.some((s) => typeof s !== "string")) {
        throw new Error("--steps file must contain a JSON array of strings");
      }
      const trees = await runSteps(steps);
      if (raw) {
        process.stdout.write(trees[trees.length - 1]);
      } else {
        trees.forEach((tree, i) => {
          process.stdout.write(`=== step ${i} ===\n${tree}`);
        });
      }
    } else {
      const ouiPath = args.find((a) => !a.startsWith("--"));
      if (!ouiPath) {
        console.error(
          "usage: node probes/expected-tree.mjs <program.oui> | --steps <steps.json> [--raw]"
        );
        process.exit(2);
      }
      const source = readFileSync(ouiPath, "utf8"); // verbatim — no trimming
      const [tree] = await runSteps([source]);
      process.stdout.write(tree);
    }
  } catch (e) {
    console.error("[expected-tree] FAILED:", e);
    process.exit(1);
  }
}
