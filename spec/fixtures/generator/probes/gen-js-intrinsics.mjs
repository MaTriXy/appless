/**
 * Dump V8's intrinsic prototype own-property tables — the ground truth the two
 * ports' hand-written `JsObject.kt` / `JSObject.swift` tables copy.
 *
 * Those ~500-line tables were transcribed from V8 by hand, once, in each
 * language. Nothing proved they agreed with V8 or with each other. This script
 * regenerates the authority; `probes/js-intrinsics.json` is its committed
 * output, and BOTH ports assert their tables against that one file
 * (`JsObjectModelTest.kt` / `JSObjectModelTests.swift`), which makes it a
 * cross-port equality gate as well as a V8 conformance gate.
 *
 *   node probes/gen-js-intrinsics.mjs                 # print JSON
 *   node probes/gen-js-intrinsics.mjs --out FILE      # write it
 *   node probes/gen-js-intrinsics.mjs --check FILE    # non-zero on drift
 *
 * Shape (own names in V8's `Object.getOwnPropertyNames` order — the order the
 * ports' `linkedMapOf` / `jsTable` literals preserve):
 *
 * ```jsonc
 * { "node": "v22.x", "intrinsics": {
 *     "Object": [ { "key": "constructor", "kind": "function",
 *                   "name": "Object", "arity": 1 },
 *                 { "key": "__proto__",   "kind": "accessor" },
 *                 … ],
 *     "Array": [ { "key": "length", "kind": "data", "value": 0 }, … ] } }
 * ```
 *
 * Only what the port's value model can observe is recorded: a member is a
 * `function` (rendered `function <name>() { [native code] }`, with `.name` and
 * `.length`), a `data` property (`Array.prototype.length`,
 * `Function.prototype.name`), or an `accessor` (`Object.prototype.__proto__`'s
 * getter/setter pair, `Function.prototype.arguments`/`.caller`'s poison pills).
 * Enumerability is not recorded because NONE of them is enumerable — asserted
 * below, since that is exactly what makes `Object.keys(Array.prototype)` `[]`.
 */
import { readFileSync, writeFileSync } from "node:fs";

const INTRINSICS = {
  Object: Object.prototype,
  Array: Array.prototype,
  Number: Number.prototype,
  String: String.prototype,
  Boolean: Boolean.prototype,
  Function: Function.prototype,
};

function describe(proto, key) {
  const d = Object.getOwnPropertyDescriptor(proto, key);
  if (d.get || d.set) return { key, kind: "accessor" };
  const v = d.value;
  if (typeof v === "function") {
    return { key, kind: "function", name: v.name, arity: v.length };
  }
  return { key, kind: "data", value: v };
}

export function dumpIntrinsics() {
  const intrinsics = {};
  for (const [label, proto] of Object.entries(INTRINSICS)) {
    const rows = [];
    for (const key of Object.getOwnPropertyNames(proto)) {
      const d = Object.getOwnPropertyDescriptor(proto, key);
      if (d.enumerable) {
        throw new Error(`${label}.prototype.${key} is enumerable — the port's Object.keys model assumes none are`);
      }
      rows.push(describe(proto, key));
    }
    intrinsics[label] = rows;
  }
  return { node: process.version, intrinsics };
}

const args = process.argv.slice(2);
const flag = (name) => {
  const i = args.indexOf(name);
  return i === -1 ? null : args[i + 1];
};

const dump = dumpIntrinsics();
const text = JSON.stringify(dump, null, 2) + "\n";
const check = flag("--check");
const out = flag("--out");
if (check) {
  const have = readFileSync(check, "utf8");
  // The node version line is informational — compare the tables only.
  const strip = (s) => JSON.stringify(JSON.parse(s).intrinsics);
  if (strip(have) !== strip(text)) {
    console.error(`[js-intrinsics] DRIFT: ${check} does not match this V8 (${process.version})`);
    process.exit(1);
  }
  console.log(`[js-intrinsics] ${check} matches V8 ${process.version}`);
} else if (out) {
  writeFileSync(out, text);
  console.log(`[js-intrinsics] wrote ${out}`);
} else {
  process.stdout.write(text);
}
