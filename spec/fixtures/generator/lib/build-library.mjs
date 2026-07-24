/**
 * Load the REAL parser (@openuidev/lang-core) and the REAL GenOS component
 * contract (src/genos/ui/contract.tsx) into one runtime module.
 *
 * Why a bundle step (documented in ../README.md):
 *  - lang-core 0.1.2 ships ESM with extensionless relative imports
 *    ("./library"), which Metro resolves but Node's native ESM loader rejects,
 *    so lang-core cannot be `import`ed directly under Node. esbuild resolves
 *    those imports and bundles lang-core's dist verbatim (no transformation of
 *    behavior — it is the same code the RN app executes).
 *  - contract.tsx is TypeScript/JSX; esbuild strips types (`import type
 *    { ReactNode } from "react"` is erased, so React is not needed).
 *  - contract.tsx's value imports `createLibrary, defineComponent` from
 *    "@openuidev/react-lang" are aliased to "@openuidev/lang-core":
 *    react-lang's dist/library.js re-exports them from lang-core verbatim
 *    (pure pass-through functions), and aliasing avoids pulling in React (a
 *    react-lang peer dep the generator does not need — nothing renders here).
 *  - Everything is bundled into ONE module so there is exactly one lang-core
 *    and (via `external: ["zod"]`, deduped by npm) one zod instance — this
 *    matters because defineComponent registers each schema in zod's global
 *    registry by name, and library.toJSONSchema() reads that registry.
 *
 * The bundle is rebuilt fresh from the repo's contract.tsx on every generator
 * run, so contract edits are always picked up.
 */
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import { mkdirSync } from "node:fs";
import * as esbuild from "esbuild";

const here = path.dirname(fileURLToPath(import.meta.url));
const generatorRoot = path.resolve(here, "..");
const repoRoot = path.resolve(generatorRoot, "../../..");
export const CONTRACT_PATH = path.join(repoRoot, "src/genos/ui/contract.tsx");

let cachedRuntime = null;

/**
 * Bundle lang-core + contract.tsx into .build/runtime.mjs and import it.
 * Returns { langCore, buildGenosLibrary }.
 */
export async function loadRuntime() {
  if (cachedRuntime) return cachedRuntime;
  const outfile = path.join(generatorRoot, ".build/runtime.mjs");
  mkdirSync(path.dirname(outfile), { recursive: true });
  const entry = [
    `export * as langCore from "@openuidev/lang-core";`,
    `export { buildGenosLibrary } from ${JSON.stringify(CONTRACT_PATH)};`,
  ].join("\n");
  await esbuild.build({
    stdin: { contents: entry, resolveDir: generatorRoot, sourcefile: "runtime-entry.mjs", loader: "js" },
    outfile,
    bundle: true,
    format: "esm",
    platform: "node",
    // Aliased bare imports resolve from the working directory — pin it to the
    // generator package so `node spec/contract/export-schema.mjs` works from
    // the repo root (which has no node_modules of its own).
    absWorkingDir: generatorRoot,
    // zod stays external so the bundle shares this package's single zod
    // instance (global schema registry correctness).
    external: ["zod"],
    alias: { "@openuidev/react-lang": "@openuidev/lang-core" },
    logLevel: "silent",
  });
  // Cache-bust the URL so a fresh process/build always wins over Node's cache.
  cachedRuntime = await import(pathToFileURL(outfile).href + `?t=${Date.now()}`);
  return cachedRuntime;
}

/**
 * Build the GenOS library exactly like the app does, but with stub renderers.
 * buildGenosLibrary reads one renderer per contract component; a Proxy
 * satisfies any key so this stays maintenance-free when components are added.
 * Renderers are opaque to lang-core (never called during parse/materialize).
 */
export async function buildLibrary() {
  const { buildGenosLibrary } = await loadRuntime();
  const stub = () => null;
  const stubRenderers = new Proxy({}, { get: () => stub });
  return buildGenosLibrary(stubRenderers);
}
