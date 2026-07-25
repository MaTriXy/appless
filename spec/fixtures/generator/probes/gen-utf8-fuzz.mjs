/**
 * UTF-8 streaming-decode fuzz corpus generator.
 *
 * GenOSCore's UTF8StreamDecoder is a port of the WHATWG utf-8 decoder state
 * machine - the algorithm `new TextDecoder()` runs with {stream: true}. This
 * script generates a deterministic corpus of byte sequences (valid, malformed,
 * and adversarial) split at random chunk boundaries, decodes each through the
 * REAL TextDecoder, and emits the per-chunk expectations the Swift test asserts.
 *
 * Deterministic: mulberry32 PRNG with a fixed seed, so re-running reproduces the
 * committed expectations byte-identically (that is the CI freshness guarantee).
 *
 *   node probes/gen-utf8-fuzz.mjs            # print JSON to stdout
 *   node probes/gen-utf8-fuzz.mjs --out FILE # write JSON to FILE
 *
 * Output shape: { seed, generatedBy, cases: [{ chunks: [[byte...]...],
 *                 perChunk: ["decoded", ...] }] }
 */

const SEED = 0x5eed1234;
const CASE_COUNT = 220;

function mulberry32(a) {
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const rand = mulberry32(SEED);
const pick = (arr) => arr[Math.floor(rand() * arr.length)];
const randInt = (lo, hi) => lo + Math.floor(rand() * (hi - lo + 1));

/** Byte-sequence generators, mixing valid scalars with targeted malformations. */
function validScalarBytes() {
  const kind = randInt(0, 3);
  let cp;
  if (kind === 0) cp = randInt(0x00, 0x7f); // ASCII
  else if (kind === 1) cp = randInt(0x80, 0x7ff); // 2-byte
  else if (kind === 2) {
    // 3-byte, skipping the surrogate range
    cp = randInt(0x800, 0xffff);
    if (cp >= 0xd800 && cp <= 0xdfff) cp = 0x2028;
  } else cp = randInt(0x10000, 0x10ffff); // 4-byte
  return [...Buffer.from(String.fromCodePoint(cp), "utf8")];
}

/** Malformations that historically diverged from tail-scan decoders. */
const MALFORMED = [
  [0xc0, 0x80], // overlong 2-byte
  [0xc1, 0xbf], // overlong 2-byte
  [0xe0, 0x80], // out-of-range continuation (lowerBoundary 0xA0)
  [0xed, 0xa0], // surrogate lead (upperBoundary 0x9F)
  [0xf0, 0x80], // out-of-range continuation (lowerBoundary 0x90)
  [0xf4, 0x90], // beyond U+10FFFF (upperBoundary 0x8F)
  [0xf5], // invalid lead
  [0xff], // invalid lead
  [0xfe], // invalid lead
  [0x80], // stray continuation
  [0xbf], // stray continuation
  [0xe2, 0x82], // truncated 3-byte
  [0xf0, 0x9f], // truncated 4-byte
  [0xf0, 0x9f, 0x8c], // truncated 4-byte (2 seen)
  [0xc2], // truncated 2-byte
  [0xed, 0xa0, 0x80], // full surrogate encoding
];

function makeBytes() {
  const bytes = [];
  const parts = randInt(0, 8);
  for (let i = 0; i < parts; i++) {
    if (rand() < 0.45) bytes.push(...pick(MALFORMED));
    else bytes.push(...validScalarBytes());
  }
  return bytes.slice(0, 64);
}

function splitIntoChunks(bytes) {
  const chunkCount = randInt(1, 5);
  if (bytes.length === 0) return [[]];
  const cuts = new Set();
  for (let i = 0; i < chunkCount - 1; i++) cuts.add(randInt(0, bytes.length));
  const points = [0, ...[...cuts].sort((a, b) => a - b), bytes.length];
  const chunks = [];
  for (let i = 0; i < points.length - 1; i++) {
    chunks.push(bytes.slice(points[i], points[i + 1]));
  }
  return chunks;
}

const cases = [];
// Pinned counterexamples first: each broke a previous tail-scan decoder.
const PINNED = [
  [[0x61, 0xe0, 0x80], [0x62]],
  [[0x61, 0xed, 0xa0], [0x62]],
  [[0x61, 0xf4, 0x90], [0x62]],
  [[0x61, 0xf0, 0x80], [0x62]],
  [[0x61, 0xf5], [0x62]],
  [[0x61, 0xe2, 0x82], [0xac, 0x62]],
  [[0xf0, 0x9f], [0x8c], [0x8d]],
  [[0x61, 0xc2], [0xa9]],
];
for (const chunks of PINNED) cases.push(chunks);
while (cases.length < CASE_COUNT) cases.push(splitIntoChunks(makeBytes()));

const out = {
  seed: SEED,
  generatedBy: "spec/fixtures/generator/probes/gen-utf8-fuzz.mjs (node TextDecoder oracle)",
  cases: cases.map((chunks) => {
    // One decoder per case, stream:true throughout - exactly how
    // UTF8StreamDecoder is used by StreamClient across SSE chunks.
    const dec = new TextDecoder("utf-8");
    const perChunk = chunks.map((c) => dec.decode(Uint8Array.from(c), { stream: true }));
    return { chunks, perChunk };
  }),
};

const json = JSON.stringify(out, null, 2) + "\n";
const outIdx = process.argv.indexOf("--out");
if (outIdx !== -1 && process.argv[outIdx + 1]) {
  const { writeFileSync } = await import("node:fs");
  writeFileSync(process.argv[outIdx + 1], json);
  console.error(`[gen-utf8-fuzz] wrote ${out.cases.length} cases to ${process.argv[outIdx + 1]}`);
} else {
  process.stdout.write(json);
}
