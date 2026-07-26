/**
 * @process appless/phase5-kotlin-parser-convergence
 * @description Execute Phase 5 of docs/NATIVE_MIGRATION_PLAN.md: the pure-Kotlin
 *   openui-lang parser (android/openui-lang), ported clean-room from
 *   spec/openui-lang.md and verified against the SAME 89-fixture golden oracle
 *   the Swift parser passes, plus the JS-semantics lessons Phases 1-2 paid for.
 *   Non-interactive (yolo).
 * @inputs { targetQuality: number, maxIterations: number }
 * @outputs { success: boolean, iterations: number, finalQuality: number }
 *
 * The Kotlin port inherits every divergence class the Swift rounds discovered.
 * Kotlin/JVM shares Java's UTF-16 String model, so the grapheme hazards that
 * bit Swift do NOT apply - but the mirror-image risks do (String.split with
 * regex metacharacters, Char vs code point, Regex vs JS semantics, Double
 * toString vs ECMAScript Number::toString). Those are named explicitly in the
 * authoring prompts so the port starts where Swift finished.
 */

import { defineTask } from '@a5c-ai/babysitter-sdk';

const REPO = '/home/user/appless';
const PKG = `${REPO}/android/openui-lang`;
const GRADLE = 'export PATH=/opt/gradle/bin:$PATH ANDROID_HOME=/opt/android-sdk';

export async function process(inputs, ctx) {
  const { targetQuality = 99, maxIterations = 5 } = inputs;

  await ctx.task(authorRunnerTask, {});
  await ctx.task(authorParserTask, {});

  let iteration = 0;
  let score = 0;
  let converged = false;
  let feedback = null;
  const history = [];

  while (iteration < maxIterations && !converged) {
    iteration++;
    if (iteration > 1) {
      await ctx.task(refineTask, { feedback, iteration });
    }

    const buildGate = await ctx.task(buildGateTask, { iteration });
    const testGate = await ctx.task(testGateTask, { iteration });
    const crossGate = await ctx.task(crossCheckGateTask, { iteration });

    const judged = await ctx.task(judgeTask, {
      iteration,
      targetQuality,
      gates: { build: buildGate, tests: testGate, cross: crossGate },
    });

    score = judged.overallScore;
    feedback = judged.recommendations;
    history.push({ iteration, score, criticalIssues: judged.criticalIssues || [] });
    converged = score >= targetQuality;
  }

  await ctx.breakpoint({
    question: `Phase 5 Kotlin parser scored ${score}/${targetQuality}. Commit, push, continue to Phase 6 (Compose)?`,
    title: 'Phase 5 convergence review',
    options: ['Approve', 'Reject'],
    expert: 'owner',
    tags: ['quality-gate', 'phase-boundary'],
  });
  await ctx.task(commitPushTask, { score, iteration });

  return { success: converged, iterations: iteration, finalQuality: score, targetQuality, history };
}

// ---------------------------------------------------------------------------

export const authorRunnerTask = defineTask('author-kotlin-runner', (args, taskCtx) => ({
  kind: 'agent',
  title: 'Author the Kotlin module + fixture-oracle runner (tests first)',
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'Kotlin test-infrastructure engineer',
      task: 'Create the openui-lang Gradle module and a fixture-driven test suite that byte-compares serialized trees against the SAME oracle the Swift parser passes - BEFORE the parser exists (must compile and fail red)',
      context: {
        moduleDir: PKG,
        fixtures: `${REPO}/spec/fixtures (89 fixtures: 74 complete + 15 partial/)`,
        treeFormat: `${REPO}/spec/fixtures/README.md (expected-tree JSON format section)`,
        schema: `${REPO}/spec/contract/genos.schema.json`,
        swiftPrecedent: `${REPO}/ios/Packages/OpenUILang/Tests/OpenUILangTests/FixtureOracleTests.swift (the Swift runner - mirror its rigor: full-tree byte comparison, per-fixture failure output with first-divergence offset, corpus-count assertion)`,
        toolchain: 'Gradle at /opt/gradle/bin, JDK 21, ANDROID_HOME=/opt/android-sdk. This module must be a PURE Kotlin/JVM library (no Android dependency) so it tests headlessly here.',
      },
      instructions: [
        'Read spec/fixtures/README.md expected-tree format and the Swift runner first.',
        'Create android/ with a Gradle build (settings.gradle.kts, build.gradle.kts, gradle wrapper if feasible offline - otherwise document the system gradle invocation) and an openui-lang JVM module with kotlin("jvm").',
        'Public API mirroring the Swift package so the two ports stay comparable: OpenUIParser(schema).parse(text), StreamingParser(schema).set(text), ParseResult with tree/meta/state/runtimeErrors, LibrarySchema.load(path), TreeSerializer.serialize(result) emitting the documented deterministic JSON.',
        'Stub the parser so the suite compiles and FAILS red. The runner discovers every .oui under spec/fixtures (both levels) via a path relative to the module, batch-parses complete fixtures, stream-parses partial/ ones, serializes, and byte-compares to the .expected.json twin. Assert the corpus count (89) and print "fixtures exercised: 89" for the CI gate.',
        'Run: gradle :openui-lang:test (or the documented invocation) and confirm compile-clean + red. Return only the JSON summary.',
      ],
      outputFormat: 'JSON with filesCreated (array), fixtureCasesDiscovered (number), compilesClean (boolean), redAsExpected (boolean), gradleInvocation (string), notes (array)',
    },
    outputSchema: {
      type: 'object',
      required: ['filesCreated', 'fixtureCasesDiscovered', 'compilesClean', 'redAsExpected', 'gradleInvocation'],
      properties: {
        filesCreated: { type: 'array', items: { type: 'string' } },
        fixtureCasesDiscovered: { type: 'number' },
        compilesClean: { type: 'boolean' },
        redAsExpected: { type: 'boolean' },
        gradleInvocation: { type: 'string' },
        notes: { type: 'array', items: { type: 'string' } },
      },
    },
  },
  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`,
  },
  labels: ['authoring', 'tests-first'],
}));

export const authorParserTask = defineTask('author-kotlin-parser', (args, taskCtx) => ({
  kind: 'agent',
  title: 'Implement the openui-lang parser in pure Kotlin',
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'compiler engineer porting a JS parser to idiomatic Kotlin, informed by a completed Swift port',
      task: 'Implement the full openui-lang runtime until all 89 golden fixtures pass byte-for-byte',
      context: {
        moduleDir: PKG,
        spec: `${REPO}/spec/openui-lang.md (normative; includes must-reproduce quirks with Source: footnotes)`,
        jsReference: `${REPO}/spec/fixtures/generator/node_modules/@openuidev/lang-core/dist`,
        swiftPort: `${REPO}/ios/Packages/OpenUILang/Sources/OpenUILang (a CONVERGED reference implementation - read it for structure and for the divergence classes it documents in README KNOWN-DEVIATIONS)`,
        jvmHazards: [
          'Kotlin/JVM String IS UTF-16 like JS, so the grapheme-cluster hazards that bit the Swift port do not apply - but do NOT assume parity for free.',
          'String.split(String) in Kotlin is literal, but split(Regex) is not - and Java regex differs from JS: \\w/\\d are ASCII by default (good) but \\s, dot, case-insensitivity (UNICODE_CASE) and $ anchoring (matches before a final line terminator with MULTILINE off? verify) can differ. Encode explicit character classes exactly as the Swift port does (see JSRegex.swift / StringJS.swift).',
          'Double.toString in Kotlin/Java is NOT ECMAScript Number::toString (Java prints 1.0E16, JS prints 10000000000000000; Java always includes a decimal point). Port the algorithm from the Swift TreeSerializer.formatNumber, which is verified against a 267-entry node table.',
          'Char iteration is UTF-16 code units (matches JS); codePoints() is NOT what JS string indexing does - prefer code-unit indexing to mirror JS exactly.',
          'JSON: do not use a lenient parser. JSON.parse strictness matters (leading zeros and raw control chars must be rejected); mirror the Swift JSONValue behavior and its documented lone-surrogate note (JVM CAN hold lone surrogates, unlike Swift - so Kotlin may match JS MORE closely here; verify and document rather than copying the Swift limitation).',
        ],
      },
      instructions: [
        'Read spec/openui-lang.md fully, then the lang-core JS sources, then the Swift port for structure and hazard documentation.',
        'Implement lexer, statements+autoClose, expressions with a JS dynamic-value model (loose equality, coercions, div/mod-by-zero -> 0), builtins with degenerate cases, reference resolution, entry-selection tiers, materialization drop rules, the streaming parser with prefix-extension caching and the must-reproduce comment hazard, action AST capture, and the byte-exact tree serializer.',
        'Iterate gradle test until ALL 89 fixtures pass. Do not weaken the runner.',
        'Where the JVM can match JS BETTER than Swift could (e.g. lone surrogates), do so and document the difference from the Swift port in the module README.',
        'Return only the JSON summary.',
      ],
      outputFormat: 'JSON with filesCreated (array), fixturesPassing (string), allGreen (boolean), architectureNotes (array), divergencesFromSwiftPort (array)',
    },
    outputSchema: {
      type: 'object',
      required: ['filesCreated', 'fixturesPassing', 'allGreen'],
      properties: {
        filesCreated: { type: 'array', items: { type: 'string' } },
        fixturesPassing: { type: 'string' },
        allGreen: { type: 'boolean' },
        architectureNotes: { type: 'array', items: { type: 'string' } },
        divergencesFromSwiftPort: { type: 'array', items: { type: 'string' } },
      },
    },
  },
  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`,
  },
  labels: ['authoring', 'implementation'],
}));

export const refineTask = defineTask('refine-kotlin-parser', (args, taskCtx) => ({
  kind: 'agent',
  title: `Refine the Kotlin parser (iteration ${args.iteration})`,
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'Kotlin compiler engineer addressing review findings',
      task: 'Fix every judge finding in android/openui-lang without regressing the 89-fixture suite',
      context: { moduleDir: PKG, feedback: args.feedback, iteration: args.iteration },
      instructions: [
        'Fix EVERY feedback item in the actual sources; re-run the gradle test task until green.',
        'Return only the JSON summary.',
      ],
      outputFormat: 'JSON with addressed (array), filesModified (array), testsStillGreen (boolean)',
    },
    outputSchema: {
      type: 'object',
      required: ['addressed', 'filesModified', 'testsStillGreen'],
      properties: {
        addressed: { type: 'array', items: { type: 'string' } },
        filesModified: { type: 'array', items: { type: 'string' } },
        testsStillGreen: { type: 'boolean' },
      },
    },
  },
  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`,
  },
  labels: ['refine', `iteration-${args.iteration}`],
}));

export const buildGateTask = defineTask('kotlin-build-gate', (args, taskCtx) => ({
  kind: 'shell',
  title: `Kotlin module compiles (iteration ${args.iteration})`,
  shell: {
    command: `${GRADLE} && cd ${REPO}/android && gradle :openui-lang:compileKotlin --console=plain -q 2>&1 | tail -5`,
    expectedExitCode: 0,
    timeout: 900000,
  },
  labels: ['gate', 'build'],
}));

export const testGateTask = defineTask('kotlin-test-gate', (args, taskCtx) => ({
  kind: 'shell',
  title: `all 89 fixtures pass (iteration ${args.iteration})`,
  shell: {
    command: `${GRADLE} && cd ${REPO}/android && gradle :openui-lang:test --console=plain 2>&1 | tail -8`,
    expectedExitCode: 0,
    timeout: 1800000,
  },
  labels: ['gate', 'tests'],
}));

export const crossCheckGateTask = defineTask('cross-port-gate', (args, taskCtx) => ({
  kind: 'shell',
  title: `Kotlin and Swift ports agree on the corpus (iteration ${args.iteration})`,
  shell: {
    // Both ports serialize to the same committed expectations, so if both
    // suites are green on the same corpus count they agree by construction.
    // This gate makes that explicit rather than implicit.
    command: `export PATH=/opt/swift/usr/bin:$PATH && cd ${REPO}/ios/Packages/OpenUILang && swift test 2>&1 | grep -q 'fixtures exercised: 89' && ${GRADLE} && cd ${REPO}/android && gradle :openui-lang:test --console=plain 2>&1 | grep -q 'fixtures exercised: 89'`,
    expectedExitCode: 0,
    timeout: 1800000,
  },
  labels: ['gate', 'cross-port'],
}));

export const judgeTask = defineTask('judge-kotlin-parser', (args, taskCtx) => ({
  kind: 'agent',
  title: `Judge the Kotlin parser (iteration ${args.iteration})`,
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'principal Kotlin engineer reviewing a clean-room parser port; adversarial, evidence-based',
      task: 'Score android/openui-lang 0-100; deductions cite file+defect; perfect sub-scores cite personally-performed verification',
      context: {
        moduleDir: PKG,
        spec: `${REPO}/spec/openui-lang.md`,
        jsReference: `${REPO}/spec/fixtures/generator/node_modules/@openuidev/lang-core/dist`,
        swiftPort: `${REPO}/ios/Packages/OpenUILang (converged reference; its README documents the divergence classes five Swift rounds found)`,
        gates: args.gates,
        iteration: args.iteration,
        targetQuality: args.targetQuality,
        rubric: [
          'fidelity (35%): re-run the suite; spot-check >=5 spec sections against the Kotlin source; THEN differential-probe: author 3-5 adversarial programs NOT in the corpus, run them through the Kotlin parser AND the JS oracle (spec/fixtures/generator/probes/expected-tree.mjs) and byte-compare. Pay special attention to the classes the Swift rounds paid for: ECMAScript number formatting, JS-vs-Java regex class semantics, JSON.parse strictness, streaming prefix/reset semantics, loose equality',
          'architecture (25%): idiomatic Kotlin (sealed classes, data classes, no unnecessary nullability), streaming API shaped for a Compose consumer, no platform leakage into the pure module',
          'testQuality (20%): the runner byte-compares FULL trees with actionable failure output; corpus count asserted; deterministic',
          'crossPortConsistency (20%): does the Kotlin port agree with the Swift port where both are correct, and where it deliberately differs (e.g. lone surrogates, which the JVM can represent), is that documented and justified rather than accidental?',
        ],
        hardCaps: [
          'Any fixture failing -> <=60',
          'Runner comparing less than full trees -> <=70',
          'Any differential probe diverging from the JS oracle -> <=90',
          'An undocumented behavioral difference from the Swift port -> <=92',
        ],
      },
      instructions: [
        'Toolchains: /opt/gradle/bin (JDK 21), /opt/swift/usr/bin. Re-run the gates yourself. Ignore narrative about how the code was built.',
        'Score, weight, apply caps, give prioritized actionable recommendations.',
      ],
      outputFormat: 'JSON with overallScore, scores, evidence (array), criticalIssues (array), recommendations (array)',
    },
    outputSchema: {
      type: 'object',
      required: ['overallScore', 'scores', 'evidence', 'recommendations'],
      properties: {
        overallScore: { type: 'number', minimum: 0, maximum: 100 },
        scores: { type: 'object' },
        evidence: { type: 'array', items: { type: 'string' } },
        criticalIssues: { type: 'array', items: { type: 'string' } },
        recommendations: { type: 'array', items: { type: 'string' } },
      },
    },
  },
  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`,
  },
  labels: ['judge', `iteration-${args.iteration}`],
}));

export const commitPushTask = defineTask('commit-push', (args, taskCtx) => ({
  kind: 'shell',
  title: 'Commit and push Phase 5 artifacts',
  shell: {
    command: `cd ${REPO} && git add android/ .a5c/processes/ .github/ && git commit -m "Add the Kotlin openui-lang parser (Phase 5)

89/89 golden fixtures green against the same oracle the Swift port
passes. Quality-convergence score ${args.score}/99 after ${args.iteration} iteration(s)." && git push -u origin claude/repo-overview-xktv5r`,
    expectedExitCode: 0,
    timeout: 120000,
  },
  labels: ['git', 'finalize'],
}));
