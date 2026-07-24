/**
 * postinstall: apply the repo patch `patches/@openuidev+react-lang+0.1.5.patch`
 * to THIS package's installed copy of @openuidev/react-lang, then verify all
 * three hunks actually landed. Fails loudly (exit 1) if anything is off.
 *
 * The patch touches only react-lang/dist/Renderer.js (React error-boundary
 * recovery, DOM spinner removal, div->Fragment). It does not affect
 * @openuidev/lang-core (tokenizer/parser/materializer), which is what the
 * fixture generator actually drives — see README.md "Why the patch cannot
 * affect fixtures". We still apply + verify it here so this package's
 * node_modules is byte-identical to the RN app's runtime dependency set.
 */
import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const patchDir = path.resolve(here, "../../../patches");
const patchFile = path.join(patchDir, "@openuidev+react-lang+0.1.5.patch");
const rendererJs = path.join(here, "node_modules/@openuidev/react-lang/dist/Renderer.js");

function fail(msg) {
  console.error(`[apply-patch] FAILED: ${msg}`);
  process.exit(1);
}

if (!existsSync(patchFile)) fail(`repo patch not found at ${patchFile}`);
if (!existsSync(rendererJs)) fail(`react-lang not installed at ${rendererJs}`);

// Markers proving each of the three hunks is present in Renderer.js:
//   hunk 1: error-boundary recovery keyed on the parsed node
//   hunk 2: DefaultQueryLoader spinner removed
//   hunk 3: wrapper <div>s replaced with Fragments
const HUNK_MARKERS = [
  ["hunk 1 (error-boundary node-keyed recovery)", "this.recoveredNode = node;"],
  ["hunk 2 (DefaultQueryLoader removed)", "const DefaultQueryLoader = () => null;"],
  ["hunk 3 (div -> Fragment)", "children: _jsxs(Fragment, { children: [isQueryLoading"],
];

function verifyHunks() {
  const src = readFileSync(rendererJs, "utf8");
  return HUNK_MARKERS.filter(([, marker]) => !src.includes(marker));
}

if (verifyHunks().length === 0) {
  console.log("[apply-patch] patch already applied; all 3 hunks verified.");
  process.exit(0);
}

// Apply via patch-package against the repo's patches/ directory.
const patchPackageBin = path.join(here, "node_modules/.bin/patch-package");
try {
  execFileSync(patchPackageBin, ["--patch-dir", path.relative(here, patchDir), "--error-on-fail"], {
    cwd: here,
    stdio: "inherit",
  });
} catch {
  fail("patch-package could not apply patches/@openuidev+react-lang+0.1.5.patch (hunks no longer apply?)");
}

const missing = verifyHunks();
if (missing.length > 0) {
  fail(
    `patch-package reported success but these hunks are missing from dist/Renderer.js:\n` +
      missing.map(([name]) => `  - ${name}`).join("\n"),
  );
}
console.log("[apply-patch] applied and verified all 3 hunks in @openuidev/react-lang/dist/Renderer.js.");
