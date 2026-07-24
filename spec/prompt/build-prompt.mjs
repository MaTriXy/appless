/**
 * Assemble the applessOS system prompt from spec-side sources of truth.
 *
 * Pipeline (mirrors the appless-os web repo's `openui generate` step followed
 * by scripts/embed-prompt.mjs's native adaptations):
 *   1. Build the REAL GenOS library from src/genos/ui/contract.tsx (same
 *      esbuild loader the fixture generator uses).
 *   2. Call library.prompt(...) — @openuidev/lang-core's generatePrompt() —
 *      with the stored preamble, examples, and additional rules. This
 *      generates every boilerplate section (Syntax Rules, Action, Hoisting &
 *      Streaming, Examples framing, Important Rules / Final Verification)
 *      from the real prompt-builder API.
 *   3. Splice in sections/component-signatures.txt verbatim over the
 *      generated "## Component Signatures" section (see README.md — the
 *      lang-core 0.1.2 signature builder predates the one that produced the
 *      shipped prompt, so that one section is stored, not generated).
 *   4. Apply the same adaptations scripts/embed-prompt.mjs applies when
 *      embedding: strip CheckBoxGroup/RadioGroup mentions, normalize em/en
 *      dashes to hyphens, trimEnd.
 *
 * Writes spec/prompt/system-prompt.generated.txt. check-prompt.mjs compares
 * the same assembled string byte-for-byte against the SYSTEM_PROMPT export in
 * src/genos/generated/system-prompt.ts.
 *
 * Usage: node spec/prompt/build-prompt.mjs
 */
import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { buildLibrary } from "../fixtures/generator/lib/build-library.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const SECTIONS = path.join(here, "sections");
export const GENERATED_OUT = path.join(here, "system-prompt.generated.txt");

/** Read a stored section file. Files end with a trailing \n added for POSIX
 *  hygiene; the prompt pieces themselves do not include it, so strip ONE. */
function readSection(rel) {
  return readFileSync(path.join(SECTIONS, rel), "utf8").replace(/\n$/, "");
}

/** Assemble the full prompt string (does not write anything). */
export async function buildPrompt() {
  const preamble = readSection("preamble.txt");
  const componentSignatures = readSection("component-signatures.txt");
  const additionalRules = readSection("additional-rules.txt").split("\n");
  const examples = readdirSync(path.join(SECTIONS, "examples"))
    .filter((f) => f.endsWith(".txt"))
    .sort()
    .map((f) => readSection(path.join("examples", f)));

  const library = await buildLibrary();
  let prompt = library.prompt({ preamble, examples, additionalRules });

  // Native adaptations — identical to scripts/embed-prompt.mjs.
  prompt = prompt.replace(/ \| CheckBoxGroup \| RadioGroup/g, "");
  prompt = prompt.replace(/[—–]/g, "-");

  // Splice the stored Component Signatures section over the generated one
  // (section runs up to the next H2 heading).
  const sigStart = prompt.indexOf("## Component Signatures");
  const sigEnd = prompt.indexOf("\n\n## ", sigStart);
  if (sigStart === -1 || sigEnd === -1) {
    throw new Error("[build-prompt] could not locate the Component Signatures section boundaries");
  }
  prompt = prompt.slice(0, sigStart) + componentSignatures + prompt.slice(sigEnd);

  return prompt.trimEnd();
}

const invokedDirectly = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  buildPrompt()
    .then((prompt) => {
      writeFileSync(GENERATED_OUT, prompt);
      console.log(`[build-prompt] wrote ${prompt.length} chars -> ${GENERATED_OUT}`);
    })
    .catch((e) => {
      console.error("[build-prompt] FAILED:", e);
      process.exit(1);
    });
}
