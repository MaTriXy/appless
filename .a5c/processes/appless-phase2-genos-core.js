/**
 * @process appless/phase2-genos-core-convergence
 * @description Execute Phase 2 of docs/NATIVE_MIGRATION_PLAN.md: the GenOSCore
 *   Swift package - data models, ScreenStore + controller, SSE streaming client
 *   with the tool-calling loop, tools (Exa search, image URL resolution), key
 *   store abstraction, telemetry - ported 1:1 from the RN reference (stream.ts,
 *   store.ts, config.ts, tools/, telemetry.ts) with behavioral constants
 *   preserved, unit-tested with mocked streams, quality convergence to
 *   targetQuality. Designed for non-interactive (yolo) runs: breakpoints
 *   auto-approve at the runtime level.
 * @inputs { targetQuality: number, maxIterations: number }
 * @outputs { success: boolean, iterations: number, finalQuality: number, history: array }
 *
 * Pattern source: .a5c/processes/appless-phase1-swift-parser.js (converged; see
 * run history). Tests-first: behavioral test suite is authored before the
 * implementation, derived from the RN sources as the spec.
 */

import { defineTask } from '@a5c-ai/babysitter-sdk';

const REPO = '/home/user/appless';
const PKG = `${REPO}/ios/Packages/GenOSCore`;
const SWIFT = 'export PATH=/opt/swift/usr/bin:$PATH';

export async function process(inputs, ctx) {
  const { targetQuality = 99, maxIterations = 5 } = inputs;

  await ctx.task(authorTestsTask, {});
  await ctx.task(authorCoreTask, {});

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
    const constantsGate = await ctx.task(constantsGateTask, { iteration });

    const judged = await ctx.task(judgeTask, {
      iteration,
      targetQuality,
      gates: { build: buildGate, tests: testGate, constants: constantsGate },
    });

    score = judged.overallScore;
    feedback = judged.recommendations;
    history.push({ iteration, score, criticalIssues: judged.criticalIssues || [], feedback });
    converged = score >= targetQuality;
  }

  await ctx.breakpoint({
    question: `Phase 2 GenOSCore scored ${score}/${targetQuality} after ${iteration} iteration(s). Commit and push, continue to Phase 3?`,
    title: 'Phase 2 convergence review',
    options: ['Approve: commit, push, continue', 'Reject'],
    expert: 'owner',
    tags: ['quality-gate', 'phase-boundary'],
  });

  await ctx.task(commitPushTask, { score, iteration });

  return {
    success: converged,
    iterations: iteration,
    finalQuality: score,
    targetQuality,
    converged,
    history,
    artifacts: { package: 'ios/Packages/GenOSCore' },
  };
}

// ---------------------------------------------------------------------------

export const authorTestsTask = defineTask('author-core-tests', (args, taskCtx) => ({
  kind: 'agent',
  title: 'Author GenOSCore behavioral test suite (tests first)',
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'Swift test engineer deriving a behavioral spec from reference sources',
      task: 'Create the GenOSCore SwiftPM package skeleton and a tests-first behavioral suite derived from the RN reference implementation - compiling against a stub API, failing red',
      context: {
        packageDir: PKG,
        references: [
          `${REPO}/src/genos/stream.ts (SSE + tool loop: MAX_TOOL_ROUNDS 3, temperature 0.8, max_completion_tokens 3072, tool-call delta accumulation by index, [DONE]/finish_reason handling, dropped-stream detection, 401/403 -> key rejection)`,
          `${REPO}/src/genos/store.ts (Screen model, ScreenStore with STREAM_FLUSH_MS 50 coalescing, controller: openApp/openDeepLink/resolveAction/retryScreen/setActiveScreen/maybePrefetch, MAX_PREFETCH 6, CONTEXT_DEPTH 2, STALE_MS 30000, actionIndex/appHomeIndex/deepLinkIndex, buildMessages ancestor replay, cleanLang/extractActions/parseOsCommand)`,
          `${REPO}/src/config.ts (KeyStore states loading/missing/present/rejected, env override, markRejected stale-key guard)`,
          `${REPO}/src/genos/tools/search.ts (Exa web_search: TOOL_DEFS shape, prompt section, ERROR-string degradation, numResults 5 maxCharacters 400)`,
          `${REPO}/src/genos/tools/images.ts (parseImgUrl - NOTE: already spec'd in spec/openui-lang.md section 11.5 and implemented in OpenUILang? No - it belongs here in core; port it with clamps/defaults)`,
          `${REPO}/src/genos/apps.ts (AppDef, APPS, summonApp, SUGGESTIONS)`,
          `${REPO}/src/genos/telemetry.ts (single launch event, opt-out)`,
          `${REPO}/spec/capabilities.md (verified constant table)`,
        ],
        design: [
          'Pure Swift, Foundation only, Linux-buildable; Swift 6 strict concurrency clean.',
          'Networking behind a protocol (HTTPStreaming/HTTPClient) so tests inject scripted SSE byte streams - no real network in tests.',
          'Key persistence behind a protocol (SecureStore) with in-memory test impl; Keychain impl arrives in Phase 3 behind #if canImport.',
          'Time/clock behind a protocol for STALE_MS/flush tests; deterministic test scheduling.',
        ],
      },
      instructions: [
        'Read every reference file fully; the RN code IS the spec - port its behavior, including edge-case guards and code comments describing intent.',
        'Create Package.swift + Sources/GenOSCore stub API + Tests/GenOSCoreTests covering AT MINIMUM: SSE line parsing across chunk boundaries (incl. multi-byte UTF-8 splits), tool-call delta accumulation (whole-call and split-arguments styles), the full tool loop (rounds, MAX_TOOL_ROUNDS cutoff, onToolRound abort -> NEEDS_LIVE_DATA), dropped-stream detection (no [DONE], no finish_reason), truncation flag, 401 -> markRejected with stale-key guard, ScreenStore flush coalescing (50ms) + immediate bump on patch, controller caching (action/appHome/deepLink indexes), reusable() staleness, speculative prefetch refusal of tools + regeneration on tap, buildMessages CONTEXT_DEPTH ancestor replay with cleanLang, retryScreen state reset, parseOsCommand/extractActions/cleanLang parity (reuse spec/openui-lang.md section 11 as the source of truth; port the exact regex semantics), parseImgUrl clamps/defaults, summonApp slug/rename rules, Exa tool formatting + error degradation.',
        'Suite must compile against stubs and fail red; print a summary line "core scenarios: <N>" (N >= 40).',
        'swift build && swift test to verify compile + red. Return only the JSON summary.',
      ],
      outputFormat: 'JSON with filesCreated (array), scenarioCount (number), compilesClean (boolean), redAsExpected (boolean), notes (array)',
    },
    outputSchema: {
      type: 'object',
      required: ['filesCreated', 'scenarioCount', 'compilesClean', 'redAsExpected'],
      properties: {
        filesCreated: { type: 'array', items: { type: 'string' } },
        scenarioCount: { type: 'number' },
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

export const authorCoreTask = defineTask('author-core', (args, taskCtx) => ({
  kind: 'agent',
  title: 'Implement GenOSCore until the behavioral suite passes',
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'senior Swift engineer porting reference TypeScript to idiomatic concurrent Swift',
      task: 'Implement Sources/GenOSCore until the behavioral test suite is fully green',
      context: {
        packageDir: PKG,
        references: 'same RN sources as the test-authoring task; read them yourself',
        swift: 'toolchain at /opt/swift/usr/bin; Swift 6 strict concurrency must be clean',
      },
      instructions: [
        'Implement models (Screen, ChatMessage, ToolCall, StreamEndInfo, AppDef, Suggestion, KeyStatus, SearchResult, ImgQuery), ScreenStore (@MainActor observable, 50ms coalescing), the controller, the SSE client + tool loop over the injected HTTPStreaming protocol, KeyStore over SecureStore protocol, Exa tool, image URL resolution, telemetry (fire-and-forget, opt-out), and the pure helpers (port regex semantics exactly - reuse patterns from spec/openui-lang.md section 11).',
        'Preserve the constants verbatim: MAX_TOOL_ROUNDS 3, temperature 0.8, max_completion_tokens 3072, MAX_PREFETCH 6, CONTEXT_DEPTH 2, STALE_MS 30000, STREAM_FLUSH_MS 50, Exa numResults 5 / maxCharacters 400, toast/etc. per capabilities.md.',
        'Run swift test; iterate until green. Do not weaken tests - if a test misreads the RN reference, fix the test to match the reference and note it.',
        'Return only the JSON summary.',
      ],
      outputFormat: 'JSON with filesCreated (array), scenariosPassing (string like "42/42"), allGreen (boolean), architectureNotes (array), testCorrections (array)',
    },
    outputSchema: {
      type: 'object',
      required: ['filesCreated', 'scenariosPassing', 'allGreen'],
      properties: {
        filesCreated: { type: 'array', items: { type: 'string' } },
        scenariosPassing: { type: 'string' },
        allGreen: { type: 'boolean' },
        architectureNotes: { type: 'array', items: { type: 'string' } },
        testCorrections: { type: 'array', items: { type: 'string' } },
      },
    },
  },
  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`,
  },
  labels: ['authoring', 'implementation'],
}));

export const refineTask = defineTask('refine-core', (args, taskCtx) => ({
  kind: 'agent',
  title: `Refine GenOSCore (iteration ${args.iteration})`,
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'senior Swift engineer addressing review findings',
      task: 'Fix every judge finding in ios/Packages/GenOSCore without regressing the suite',
      context: { packageDir: PKG, feedback: args.feedback, iteration: args.iteration },
      instructions: [
        'Fix EVERY feedback item in the actual sources; re-run swift build && swift test until green.',
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

export const buildGateTask = defineTask('core-build-gate', (args, taskCtx) => ({
  kind: 'shell',
  title: `swift build clean (iteration ${args.iteration})`,
  shell: {
    command: `${SWIFT} && cd ${PKG} && swift build 2>&1 | tail -3`,
    expectedExitCode: 0,
    timeout: 600000,
  },
  labels: ['gate', 'build'],
}));

export const testGateTask = defineTask('core-test-gate', (args, taskCtx) => ({
  kind: 'shell',
  title: `swift test all green (iteration ${args.iteration})`,
  shell: {
    command: `${SWIFT} && cd ${PKG} && swift test 2>&1 | tail -5`,
    expectedExitCode: 0,
    timeout: 900000,
  },
  labels: ['gate', 'tests'],
}));

export const constantsGateTask = defineTask('constants-gate', (args, taskCtx) => ({
  kind: 'shell',
  title: `behavioral constants preserved (iteration ${args.iteration})`,
  shell: {
    // The RN reference's load-bearing constants must appear verbatim in core
    // sources - cheap tripwire against silent drift during refactors.
    command: `cd ${PKG}/Sources && grep -rq 'maxToolRounds\\|MAX_TOOL_ROUNDS\\|= 3' . && grep -rq '3072' . && grep -rq '0.8' . && grep -rq '50' . && grep -rq '30' . && grep -rq '6' . && grep -rq '2' .`,
    expectedExitCode: 0,
    timeout: 60000,
  },
  labels: ['gate', 'constants'],
}));

export const judgeTask = defineTask('judge-core', (args, taskCtx) => ({
  kind: 'agent',
  title: `Judge GenOSCore quality (iteration ${args.iteration})`,
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'principal Swift engineer reviewing a behavioral port; adversarial, evidence-based',
      task: 'Score ios/Packages/GenOSCore 0-100; deductions cite file+defect; perfect sub-scores cite personally-performed verification',
      context: {
        packageDir: PKG,
        rnReference: `${REPO}/src/genos + ${REPO}/src/config.ts (the spec)`,
        gates: args.gates,
        iteration: args.iteration,
        targetQuality: args.targetQuality,
        rubric: [
          'fidelity (35%): line-by-line diff of >=5 behavioral clusters against the RN source (tool loop, flush coalescing, prefetch refusal, key rejection guard, buildMessages replay, staleness) - the RN comments describe intent; the Swift port must honor the same edge cases; verify constants against spec/capabilities.md',
          'concurrency (25%): Swift 6 strict concurrency soundness - actor isolation choices defensible, no data races, cancellation propagates like the RN AbortController paths (superseded-stream staleness guard!), no blocking on the main actor',
          'testQuality (20%): scripted-SSE tests genuinely exercise chunk boundaries/multi-byte splits; deterministic (no real sleeps/flaky timing); failure output actionable',
          'apiDesign (20%): surface ready for the Phase 3 SwiftUI shell (observable store, async streams, DI seams for Keychain/URLSession), no RN-isms leaking through',
        ],
        hardCaps: [
          'Any test failing -> <=60',
          'A behavioral cluster diverging from the RN reference in an externally observable way -> <=90',
          'Data race / unsound isolation found by inspection or -strict-concurrency diagnostics -> <=85',
        ],
      },
      instructions: [
        'Toolchain /opt/swift/usr/bin. Re-run gates yourself. Read the RN sources AND the Swift port side by side for the clusters you audit. Ignore narrative about how the code was built.',
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
  title: 'Commit and push Phase 2 artifacts',
  shell: {
    command: `cd ${REPO} && git add ios/ .a5c/processes/ && git commit -m "Add GenOSCore Swift package (Phase 2)

Models, ScreenStore + controller, SSE client with tool loop, tools, key
store, telemetry - ported from the RN reference with behavioral constants
preserved. Quality-convergence score ${args.score}/99 after ${args.iteration} iteration(s)." && git push -u origin claude/repo-overview-xktv5r`,
    expectedExitCode: 0,
    timeout: 120000,
  },
  labels: ['git', 'finalize'],
}));
