/**
 * @process appless/phase1b-parser-closeout
 * @description Close the Phase 1 parser from 96 to >=99: check in the probe
 *   oracle scripts, close deviation #7 exactly (U+0085 whitespace), track the
 *   spec section-11 helpers for Phase 2, then re-judge with the same rubric.
 *   Non-interactive (yolo): breakpoints auto-approve.
 * @inputs { targetQuality: number, maxIterations: number }
 * @outputs { success: boolean, finalQuality: number }
 */

import { defineTask } from '@a5c-ai/babysitter-sdk';

const REPO = '/home/user/appless';
const PKG = `${REPO}/ios/Packages/OpenUILang`;
const SWIFT = 'export PATH=/opt/swift/usr/bin:$PATH';

export async function process(inputs, ctx) {
  const { targetQuality = 99, maxIterations = 2 } = inputs;

  let iteration = 0;
  let score = 0;
  let converged = false;
  let feedback = [
    'Check in the throwaway JS probe scripts (StreamingSemanticsTests expected-tree derivation + differential sweep driver) as regenerable utilities under spec/fixtures/generator/probes/ with a README',
    'Close deviation #7 exactly: build jsWhitespace/jsTrim + Number() StrWhiteSpace from explicit scalar sets matching the ECMAScript definitions (JS trim set excludes U+0085; Number() set per spec), update README KNOWN-DEVIATIONS (entry becomes a fixed former deviation), add regression tests with U+0085/U+2028/U+2029/NBSP cases',
    'Track spec section-11 app-level helpers for Phase 2: add a PHASE-2 HANDOFF section to ios/Packages/OpenUILang/README.md listing cleanLang/extractActions/parseOsCommand/parseGenosUrl/parseImgUrl as must-port-byte-exact with their spec anchors',
  ];
  const history = [];

  while (iteration < maxIterations && !converged) {
    iteration++;
    await ctx.task(closeoutTask, { feedback, iteration });
    const buildGate = await ctx.task(buildGateTask, { iteration });
    const testGate = await ctx.task(testGateTask, { iteration });
    const judged = await ctx.task(judgeTask, { iteration, targetQuality, gates: { build: buildGate, tests: testGate } });
    score = judged.overallScore;
    feedback = judged.recommendations;
    history.push({ iteration, score, criticalIssues: judged.criticalIssues || [] });
    converged = score >= targetQuality;
  }

  await ctx.task(commitPushTask, { score, iteration });
  return { success: converged, finalQuality: score, targetQuality, history };
}

export const closeoutTask = defineTask('closeout', (args, taskCtx) => ({
  kind: 'agent',
  title: `Close out parser findings (iteration ${args.iteration})`,
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'Swift engineer closing final review findings for convergence',
      task: 'Address every feedback item on ios/Packages/OpenUILang without regressing the 89-fixture suite',
      context: {
        packageDir: PKG,
        repo: REPO,
        feedback: args.feedback,
        swift: 'toolchain at /opt/swift/usr/bin',
        jsReference: `${REPO}/spec/fixtures/generator/node_modules/@openuidev/lang-core/dist`,
      },
      instructions: [
        'Fix EVERY feedback item in the actual files. For ECMAScript whitespace sets, verify against node empirically (which scalars does trim() strip? which does Number() accept?) and encode the exact sets.',
        'Re-run: swift build && swift test (all green, fixtures exercised: 89) and, if probe scripts are added under the generator, ensure they run (document usage in their README).',
        'Differentially verify any semantics change (U+0085 etc.) against the JS oracle before finishing.',
        'Return only the JSON summary.',
      ],
      outputFormat: 'JSON with addressed (array), filesModified (array), testsStillGreen (boolean), notes (array)',
    },
    outputSchema: {
      type: 'object',
      required: ['addressed', 'filesModified', 'testsStillGreen'],
      properties: {
        addressed: { type: 'array', items: { type: 'string' } },
        filesModified: { type: 'array', items: { type: 'string' } },
        testsStillGreen: { type: 'boolean' },
        notes: { type: 'array', items: { type: 'string' } },
      },
    },
  },
  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`,
  },
  labels: ['closeout', `iteration-${args.iteration}`],
}));

export const buildGateTask = defineTask('build-gate', (args, taskCtx) => ({
  kind: 'shell',
  title: `swift build clean (closeout ${args.iteration})`,
  shell: { command: `${SWIFT} && cd ${PKG} && swift build 2>&1 | tail -2`, expectedExitCode: 0, timeout: 600000 },
  labels: ['gate'],
}));

export const testGateTask = defineTask('test-gate', (args, taskCtx) => ({
  kind: 'shell',
  title: `swift test green, 89 fixtures (closeout ${args.iteration})`,
  shell: { command: `${SWIFT} && cd ${PKG} && swift test 2>&1 | grep -q 'fixtures exercised: 89' && cd ${PKG} && swift test 2>&1 | tail -2`, expectedExitCode: 0, timeout: 900000 },
  labels: ['gate'],
}));

export const judgeTask = defineTask('judge-closeout', (args, taskCtx) => ({
  kind: 'agent',
  title: `Judge closeout (iteration ${args.iteration})`,
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'principal Swift engineer; adversarial, evidence-based; same rubric as the Phase 1 run',
      task: 'Score ios/Packages/OpenUILang 0-100 (fidelity 35, architecture 25, testQuality 20, maintainability 20). The package last scored 96 with three recommendations; verify they are now closed and that nothing regressed, then score the artifact as it IS.',
      context: {
        packageDir: PKG,
        spec: `${REPO}/spec/openui-lang.md`,
        gates: args.gates,
        priorScore: 96,
        priorRecommendations: [
          'probe scripts checked in as regenerable utilities',
          'deviation #7 (U+0085 whitespace) closed exactly',
          'PHASE-2 HANDOFF section tracking spec section-11 helpers',
        ],
        hardCaps: ['any fixture failing <=60', 'any differential probe diverging <=90', 'a prior recommendation not actually closed <=97'],
      },
      instructions: [
        'Toolchain /opt/swift/usr/bin. Re-run swift test yourself. Verify each recommendation closure with real commands (run the checked-in probe scripts; empirically test the whitespace sets against node; read the README sections). Run at least 2 fresh differential probes exercising the changed whitespace semantics (U+0085 in trim position, in Number() position, U+2028/U+2029, NBSP).',
        'Score honestly; cite evidence per sub-score.',
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
  title: 'Commit and push closeout',
  shell: {
    command: `cd ${REPO} && git add -A && git commit -m "Close Phase 1 parser review findings (score ${args.score}/99)

Probe oracle scripts checked in as regenerable utilities; exact
ECMAScript whitespace sets (deviation #7 closed); Phase 2 handoff
section for the spec section-11 app helpers." && git push -u origin claude/repo-overview-xktv5r`,
    expectedExitCode: 0,
    timeout: 120000,
  },
  labels: ['git', 'finalize'],
}));
