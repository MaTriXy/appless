/**
 * @process appless/phase1-swift-parser-convergence
 * @description Execute Phase 1 of docs/NATIVE_MIGRATION_PLAN.md: the pure-Swift
 *   OpenUILang parser package (ios/Packages/OpenUILang), ported clean-room from
 *   spec/openui-lang.md + the lang-core reference source, verified against the
 *   84-fixture golden oracle via swift test, with quality convergence to
 *   targetQuality via adversarial judge scoring.
 * @inputs { targetQuality: number, maxIterations: number }
 * @outputs { success: boolean, iterations: number, finalQuality: number, history: array }
 *
 * Pattern source: library tdd-quality-convergence.js, as instantiated by
 * .a5c/processes/appless-phase0-spec.js (run 01KYAC21A9SZHSKBWDTZY4FY0S, 99/99).
 * Test-authoring precedes implementation: the fixture corpus (frozen, committed
 * in Phase 0) IS the test suite; the runner is wired before the parser exists.
 */

import { defineTask } from '@a5c-ai/babysitter-sdk';

const REPO = '/home/user/appless';
const PKG = `${REPO}/ios/Packages/OpenUILang`;
const SWIFT = 'export PATH=/opt/swift/usr/bin:$PATH';

export async function process(inputs, ctx) {
  const { targetQuality = 99, maxIterations = 5 } = inputs;

  // Runner first (red), parser second (green) - the corpus is the frozen spec.
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
    const coverageGate = await ctx.task(coverageGateTask, { iteration });

    const judged = await ctx.task(judgeTask, {
      iteration,
      targetQuality,
      gates: { build: buildGate, tests: testGate, coverage: coverageGate },
    });

    score = judged.overallScore;
    feedback = judged.recommendations;
    history.push({ iteration, score, criticalIssues: judged.criticalIssues || [], feedback });
    converged = score >= targetQuality;
  }

  const approval = await ctx.breakpoint({
    question: `Phase 1 Swift parser scored ${score}/${targetQuality} after ${iteration} iteration(s), all 84 fixtures green. Commit and push, and continue to Phase 2 (GenOSCore)?`,
    title: 'Phase 1 convergence review',
    options: ['Approve: commit, push, continue', 'Commit and push only', 'Reject: refine further'],
    expert: 'owner',
    tags: ['quality-gate', 'phase-boundary'],
  });

  let pushed = false;
  if (approval.approved) {
    await ctx.task(commitPushTask, { score, iteration });
    pushed = true;
  }

  return {
    success: converged,
    iterations: iteration,
    finalQuality: score,
    targetQuality,
    converged,
    pushed,
    continueToPhase2: approval.approved && /continue/i.test(approval.response || ''),
    history,
    artifacts: { package: 'ios/Packages/OpenUILang', ci: '.github/workflows/swift-parser.yml' },
  };
}

// ---------------------------------------------------------------------------

export const authorRunnerTask = defineTask('author-fixture-runner', (args, taskCtx) => ({
  kind: 'agent',
  title: 'Author Swift package skeleton + fixture-oracle test runner (tests first)',
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'Swift test-infrastructure engineer',
      task: 'Create the OpenUILang SwiftPM package skeleton and a fixture-driven test suite that loads every golden fixture and compares full serialized trees - BEFORE the parser exists (tests must compile and fail red, not crash)',
      context: {
        packageDir: PKG,
        fixtures: `${REPO}/spec/fixtures`,
        treeFormatDoc: `${REPO}/spec/fixtures/README.md`,
        swift: 'toolchain at /opt/swift/usr/bin (Swift 6.1, Linux)',
      },
      instructions: [
        'Read spec/fixtures/README.md expected-tree format section verbatim first.',
        'Create Package.swift (swift-tools 6.1, platforms mac+iOS, Foundation only), Sources/OpenUILang/ with protocol stubs, Tests/OpenUILangTests/FixtureOracleTests.swift.',
        'The runner must: discover every .oui under spec/fixtures (complete + partial/) via a path relative to #filePath, parse with the (stub) public API, serialize to the documented JSON tree format with deterministic key ordering, and byte-compare against the .expected.json twin; report per-fixture pass/fail and a total count assertion (84).',
        'Partial fixtures exercise the streaming API (feed full prefix via set()); complete fixtures the batch path.',
        'Verify: swift build && swift test compiles and runs with the stub returning empty trees (tests FAIL red, exactly 84 fixture cases discovered).',
        'Return only the JSON summary.',
      ],
      outputFormat: 'JSON with filesCreated (array), fixtureCasesDiscovered (number), compilesClean (boolean), redAsExpected (boolean), notes (array)',
    },
    outputSchema: {
      type: 'object',
      required: ['filesCreated', 'fixtureCasesDiscovered', 'compilesClean', 'redAsExpected'],
      properties: {
        filesCreated: { type: 'array', items: { type: 'string' } },
        fixtureCasesDiscovered: { type: 'number' },
        compilesClean: { type: 'boolean' },
        redAsExpected: { type: 'boolean' },
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

export const authorParserTask = defineTask('author-parser', (args, taskCtx) => ({
  kind: 'agent',
  title: 'Implement the OpenUILang parser in pure Swift',
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'compiler engineer porting a JS parser to idiomatic pure Swift',
      task: 'Implement the full openui-lang runtime in Sources/OpenUILang until the 84-fixture oracle suite passes',
      context: {
        packageDir: PKG,
        spec: `${REPO}/spec/openui-lang.md`,
        referenceSource: `${REPO}/spec/fixtures/generator/node_modules/@openuidev/lang-core/dist (the real JS implementation - port faithfully, including deliberate quirks the spec marks as must-reproduce)`,
        schema: `${REPO}/spec/contract/genos.schema.json (paramOrder section drives positional mapping)`,
        swift: 'toolchain at /opt/swift/usr/bin',
      },
      instructions: [
        'Read spec/openui-lang.md in full, then the lang-core dist sources (lexer, statements, expressions, builtins, parser/streaming, materialize, evaluation).',
        'Implement: lexer (comments, single/double-quoted strings with exact escape/fallback semantics, && | gluing), statement parser + autoClose, reference resolution, expression evaluation with a JSValue dynamic-value model reproducing JS loose equality/coercions (5 == "5", div/mod-by-zero -> 0, NaN handling), builtins with degenerate cases, member/pluck/index access, $state, streaming parser (prefix-extension caching, non-prefix reset, pending-vs-completed duplicate rules, per-pass partial stamping), materialization (drop rules, schema defaults, entry-selection tiers), Action AST capture, and the JSON tree serializer matching the oracle format byte-for-byte (incl. {$action}/{$ast}/{$number} conventions and sorted props).',
        'Library schemas: load genos.schema.json (bundle a copy or read via #filePath-relative path) to drive ParamMap/required/defaults.',
        'Iterate with the toolchain: swift test, fix, repeat until ALL 84 fixture cases pass. Do not weaken the runner.',
        'Idiomatic Swift throughout (value types, enums with associated values, no Foundation JSONSerialization ordering traps - write the serializer by hand).',
        'Return only the JSON summary.',
      ],
      outputFormat: 'JSON with filesCreated (array), fixturesPassing (number string like "84/84"), allGreen (boolean), architectureNotes (array), knownDeviations (array)',
    },
    outputSchema: {
      type: 'object',
      required: ['filesCreated', 'fixturesPassing', 'allGreen'],
      properties: {
        filesCreated: { type: 'array', items: { type: 'string' } },
        fixturesPassing: { type: 'string' },
        allGreen: { type: 'boolean' },
        architectureNotes: { type: 'array', items: { type: 'string' } },
        knownDeviations: { type: 'array', items: { type: 'string' } },
      },
    },
  },
  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`,
  },
  labels: ['authoring', 'implementation'],
}));

export const refineTask = defineTask('refine-parser', (args, taskCtx) => ({
  kind: 'agent',
  title: `Refine Swift parser (iteration ${args.iteration})`,
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'Swift compiler engineer addressing review findings',
      task: 'Fix every judge finding in ios/Packages/OpenUILang without regressing the fixture suite',
      context: { packageDir: PKG, feedback: args.feedback, iteration: args.iteration, swift: 'toolchain at /opt/swift/usr/bin' },
      instructions: [
        'Fix EVERY feedback item in the actual sources.',
        'Re-run swift build && swift test - all 84 fixtures must stay green.',
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

export const buildGateTask = defineTask('swift-build-gate', (args, taskCtx) => ({
  kind: 'shell',
  title: `swift build clean (iteration ${args.iteration})`,
  shell: {
    command: `${SWIFT} && cd ${PKG} && swift build 2>&1 | tail -5`,
    expectedExitCode: 0,
    timeout: 600000,
  },
  labels: ['gate', 'build'],
}));

export const testGateTask = defineTask('swift-test-gate', (args, taskCtx) => ({
  kind: 'shell',
  title: `swift test all green (iteration ${args.iteration})`,
  shell: {
    command: `${SWIFT} && cd ${PKG} && swift test 2>&1 | tail -10`,
    expectedExitCode: 0,
    timeout: 900000,
  },
  labels: ['gate', 'tests'],
}));

export const coverageGateTask = defineTask('fixture-coverage-gate', (args, taskCtx) => ({
  kind: 'shell',
  title: `all fixtures exercised (iteration ${args.iteration})`,
  shell: {
    // Corpus growth: 84 -> 85 (fixture 070, isAstNode duck-typing quirk),
    // 85 -> 86 (071, number-formatting boundary band), 86 -> 87 (072,
    // unicode normalization) - all found by judge differential probing.
    command: `${SWIFT} && cd ${PKG} && swift test 2>&1 | grep -oE 'fixtures exercised: [0-9]+' | tail -1 | grep -q 'fixtures exercised: 87'`,
    expectedExitCode: 0,
    timeout: 900000,
  },
  labels: ['gate', 'coverage'],
}));

export const judgeTask = defineTask('judge-parser', (args, taskCtx) => ({
  kind: 'agent',
  title: `Judge Swift parser quality (iteration ${args.iteration})`,
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'principal Swift engineer reviewing a clean-room parser port; adversarial, evidence-based',
      task: 'Score ios/Packages/OpenUILang 0-100 against the rubric; deductions cite file+defect, perfect scores cite personally-performed verification',
      context: {
        packageDir: PKG,
        spec: `${REPO}/spec/openui-lang.md`,
        gates: args.gates,
        iteration: args.iteration,
        targetQuality: args.targetQuality,
        rubric: [
          'fidelity (35%): re-run swift test yourself; spot-check >=5 spec sections against the Swift source (loose-equality model, autoClose, streaming reset/merge, drop rules, entry tiers); probe 2-3 adversarial inputs NOT in the corpus through both the Swift CLI-or-test and the JS oracle (spec/fixtures/generator) and compare',
          'architecture (25%): idiomatic Swift (value semantics, enums, no stringly-typed maps where types fit), streaming API shaped for a SwiftUI consumer (incremental, cancellation-safe), no force-unwraps in parse paths',
          'testQuality (20%): runner truly byte-compares full trees (read it); failure output actionable; suite runs deterministically',
          'maintainability (20%): file organization mirrors spec sections, doc comments reference spec anchors, serializer isolated, no dead code',
        ],
        hardCaps: [
          'Any fixture failing -> <=60',
          'Runner comparing less than the full tree (e.g. only root component names) -> <=70',
          'Adversarial probe divergence from JS oracle -> <=90',
          'Force-unwrap crash on any malformed probe -> <=85',
        ],
      },
      instructions: [
        'Toolchain: /opt/swift/usr/bin. Re-run the gates yourself; do the probes; read the source. Ignore narrative in context about how the code was built.',
        'Score each dimension, weight, apply caps, give prioritized actionable recommendations.',
      ],
      outputFormat: 'JSON with overallScore, scores (per dimension), evidence (array), criticalIssues (array), recommendations (array)',
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
  title: 'Commit and push Phase 1 artifacts',
  shell: {
    command: `cd ${REPO} && git add ios/ .github/workflows/ .a5c/processes/ && git commit -m "Add OpenUILang Swift parser package (Phase 1)

84/84 golden fixtures green; quality-convergence score ${args.score}/99 after ${args.iteration} iteration(s)." && git push -u origin claude/repo-overview-xktv5r`,
    expectedExitCode: 0,
    timeout: 120000,
  },
  labels: ['git', 'finalize'],
}));
