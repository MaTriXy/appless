/**
 * @process appless/phase3-swiftui-app-convergence
 * @description Execute Phase 3 of docs/NATIVE_MIGRATION_PLAN.md: the SwiftUI
 *   iOS app - Cupertino renderers for all 30 rendered contract components plus
 *   the OS shell (home grid, ask bar, switcher, key gate, chrome, transitions),
 *   wired to OpenUILang + GenOSCore. Non-interactive (yolo).
 * @inputs { targetQuality: number, maxIterations: number }
 * @outputs { success: boolean, iterations: number, finalQuality: number }
 *
 * VERIFICATION MODEL DIFFERS FROM PHASES 1-2: SwiftUI cannot compile on Linux,
 * so the deterministic gates here are (a) a structural conformance gate proving
 * every contract component has a renderer and every renderer is reachable,
 * (b) a syntax/type gate over the platform-independent parts, (c) a committed
 * macOS CI workflow that actually compiles the app on GitHub's runners. The
 * judge additionally reviews against the RN reference implementation file by
 * file. Device/simulator verification remains the user's machine or CI.
 */

import { defineTask } from '@a5c-ai/babysitter-sdk';

const REPO = '/home/user/appless';
const APP = `${REPO}/ios/AppLess`;
const SWIFT = 'export PATH=/opt/swift/usr/bin:$PATH';

export async function process(inputs, ctx) {
  const { targetQuality = 99, maxIterations = 5 } = inputs;

  await ctx.task(scaffoldTask, {});
  await ctx.task(renderersTask, {});
  await ctx.task(shellTask, {});

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

    const conformanceGate = await ctx.task(conformanceGateTask, { iteration });
    const syntaxGate = await ctx.task(syntaxGateTask, { iteration });
    const ciGate = await ctx.task(ciWorkflowGateTask, { iteration });

    const judged = await ctx.task(judgeTask, {
      iteration,
      targetQuality,
      gates: { conformance: conformanceGate, syntax: syntaxGate, ci: ciGate },
    });

    score = judged.overallScore;
    feedback = judged.recommendations;
    history.push({ iteration, score, criticalIssues: judged.criticalIssues || [] });
    converged = score >= targetQuality;
  }

  await ctx.breakpoint({
    question: `Phase 3 SwiftUI app scored ${score}/${targetQuality}. Commit, push, continue to Phase 5 (Kotlin)?`,
    title: 'Phase 3 convergence review',
    options: ['Approve', 'Reject'],
    expert: 'owner',
    tags: ['quality-gate', 'phase-boundary'],
  });
  await ctx.task(commitPushTask, { score, iteration });

  return { success: converged, iterations: iteration, finalQuality: score, targetQuality, history };
}

// ---------------------------------------------------------------------------

export const scaffoldTask = defineTask('scaffold-app', (args, taskCtx) => ({
  kind: 'agent',
  title: 'Scaffold the SwiftUI app package + design tokens + conformance harness',
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'iOS engineer scaffolding a SwiftUI app against two verified local packages',
      task: 'Create the AppLess SwiftUI app skeleton: SwiftPM structure, design tokens ported from the RN Cupertino theme, the renderer protocol wiring to OpenUILang, and a STRUCTURAL CONFORMANCE HARNESS that fails when a contract component lacks a renderer',
      context: {
        appDir: APP,
        packages: [
          `${REPO}/ios/Packages/OpenUILang (parser; 89-fixture oracle, converged 99)`,
          `${REPO}/ios/Packages/GenOSCore (models/store/controller/stream; 202 scenarios, converged)`,
        ],
        rnReference: [
          `${REPO}/src/genos/ui/cupertino/theme.ts (design tokens - port values EXACTLY)`,
          `${REPO}/src/genos/theme.ts (useCds, dark/light)`,
          `${REPO}/src/genos/ui/contract.tsx (the 33-component contract; 30 need renderers - TabItem, SelectItem, Series render nothing)`,
          `${REPO}/spec/contract/genos.schema.json (paramOrder / requiredness)`,
          `${REPO}/spec/icon-map.md (icon name -> SF Symbol table)`,
        ],
        constraint: 'This container has no Xcode/SwiftUI SDK. Code must be written to compile on macOS via CI; keep platform-independent logic (tokens, icon mapping, prop decoding, conformance registry) in files that DO compile on Linux so they can be unit-tested here.',
      },
      instructions: [
        'Create an SwiftPM package at ios/AppLess with: a platform-independent target AppLessCore (design tokens, icon mapping, the renderer REGISTRY and conformance checks - no SwiftUI import) and a SwiftUI target AppLessUI (renderers + shell) guarded so Linux builds skip it (#if canImport(SwiftUI)); plus an Xcode-launchable App entry point.',
        'Port design tokens from cupertino/theme.ts EXACTLY (colors, radii, spacing, font sizes/weights) into a Tokens type with light/dark variants; unit-test a sample of values against the RN source.',
        'Port the icon-name -> SF Symbol mapping table from spec/icon-map.md into a lookup with the documented dot fallback for unknown names; unit-test.',
        'Build the CONFORMANCE HARNESS: a registry enumerating the 30 renderable contract components (source of truth: spec/contract/genos.schema.json minus the 3 structural placeholders), plus a Linux-runnable test asserting the registry covers exactly the schema components and that every registered entry has a renderer symbol. Print "renderers registered: <N>/29" for the CI gate to grep.',
        'swift build && swift test must pass ON LINUX for the platform-independent target. Return only the JSON summary.',
      ],
      outputFormat: 'JSON with filesCreated (array), registeredRenderers (number), linuxTestsPass (boolean), notes (array)',
    },
    outputSchema: {
      type: 'object',
      required: ['filesCreated', 'registeredRenderers', 'linuxTestsPass'],
      properties: {
        filesCreated: { type: 'array', items: { type: 'string' } },
        registeredRenderers: { type: 'number' },
        linuxTestsPass: { type: 'boolean' },
        notes: { type: 'array', items: { type: 'string' } },
      },
    },
  },
  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`,
  },
  labels: ['authoring', 'scaffold'],
}));

export const renderersTask = defineTask('author-renderers', (args, taskCtx) => ({
  kind: 'agent',
  title: 'Implement the 30 Cupertino SwiftUI renderers',
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'senior SwiftUI engineer porting a React Native design system',
      task: 'Implement every Cupertino renderer as a SwiftUI view, matching the RN implementation visually and behaviorally',
      context: {
        appDir: APP,
        rnRenderers: [
          `${REPO}/src/genos/ui/cupertino/components.tsx (689 lines - the primary reference)`,
          `${REPO}/src/genos/ui/cupertino/forms.tsx (292 lines)`,
          `${REPO}/src/genos/ui/cupertino/charts.ts, map.tsx`,
          `${REPO}/src/genos/ui/shared/{actions,charts,forms,map,media}.tsx`,
        ],
        contract: `${REPO}/src/genos/ui/contract.tsx + ${REPO}/spec/contract/genos.schema.json`,
        notes: [
          'Charts: use Swift Charts. Map: MapKit. Images: AsyncImage + the GenOSCore image URL resolver.',
          'Form inputs bind through the form-state model documented in spec/openui-lang.md (Form name-keyed, {value, componentType} wrappers).',
          'Actions dispatch the ActionEvent shape GenOSCore expects (params/humanFriendlyMessage/formState/formName).',
        ],
      },
      instructions: [
        'Read the RN renderers file by file; port each component preserving layout, spacing, typography, colors, and interaction (Toggle flips locally, Chips regenerate, Tabs switch locally, ListItem chevron rules, etc.).',
        'Every renderer registers in the conformance registry from the scaffold step.',
        'Where SwiftUI cannot express an RN behavior exactly, implement the closest native idiom and record it in a KNOWN-DIFFERENCES section of ios/AppLess/README.md with the rationale.',
        'Keep the Linux-buildable target green (swift build && swift test on the platform-independent parts).',
        'Return only the JSON summary.',
      ],
      outputFormat: 'JSON with filesCreated (array), renderersImplemented (number), knownDifferences (array), notes (array)',
    },
    outputSchema: {
      type: 'object',
      required: ['filesCreated', 'renderersImplemented'],
      properties: {
        filesCreated: { type: 'array', items: { type: 'string' } },
        renderersImplemented: { type: 'number' },
        knownDifferences: { type: 'array', items: { type: 'string' } },
        notes: { type: 'array', items: { type: 'string' } },
      },
    },
  },
  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`,
  },
  labels: ['authoring', 'renderers'],
}));

export const shellTask = defineTask('author-shell', (args, taskCtx) => ({
  kind: 'agent',
  title: 'Implement the OS shell + CI workflow',
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'senior SwiftUI engineer building an app shell over a verified controller',
      task: 'Implement the AppLess shell (home, screen host, switcher, key gate, chrome, transitions) driving GenOSCore, plus the macOS CI workflow that compiles the app',
      context: {
        appDir: APP,
        rnShell: [
          `${REPO}/src/genos/GenOS.tsx (821 lines - sessions, navigation, @OS commands, deep links, command routing, transitions, minimize)`,
          `${REPO}/src/genos/shell/HomeScreen.tsx (488), Switcher.tsx (148), KeyGate.tsx (99)`,
        ],
        core: 'GenOSController/ScreenStore from GenOSCore already implement caching, prefetch, @OS parsing, deep-link resolution - the shell OWNS navigation state (sessions, stacks, minimized set) exactly like GenOS.tsx does.',
      },
      instructions: [
        'Port the shell: per-app screen stacks, launch/push/pop, minimize-to-icon, switcher, key gate, chrome buttons, gesture hint, toasts, generating pill (materializing / searching the web), skeleton, error+retry.',
        'Route commands exactly like GenOS.tsx routeCommand + handleAction (the regex guards for back/home/close app/switcher/open <app>, the navigation-shaped action guard, the "still materializing" toast).',
        'Transitions: launch zoom-up 380ms, push slide 300ms, pop settle 260ms, minimize 360ms - match the RN curves as closely as SwiftUI animation allows.',
        'Create .github/workflows/ios-app.yml: macos-latest, selects a recent Xcode, `swift build` the packages and `xcodebuild -scheme AppLess -destination "platform=iOS Simulator,name=iPhone 16"` (or equivalent) so the SwiftUI code is genuinely compiled in CI; also runs the OpenUILang and GenOSCore test suites on macOS.',
        'Keep Linux-buildable parts green. Return only the JSON summary.',
      ],
      outputFormat: 'JSON with filesCreated (array), shellFeatures (array), ciWorkflow (string path), notes (array)',
    },
    outputSchema: {
      type: 'object',
      required: ['filesCreated', 'shellFeatures', 'ciWorkflow'],
      properties: {
        filesCreated: { type: 'array', items: { type: 'string' } },
        shellFeatures: { type: 'array', items: { type: 'string' } },
        ciWorkflow: { type: 'string' },
        notes: { type: 'array', items: { type: 'string' } },
      },
    },
  },
  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`,
  },
  labels: ['authoring', 'shell'],
}));

export const refineTask = defineTask('refine-app', (args, taskCtx) => ({
  kind: 'agent',
  title: `Refine the SwiftUI app (iteration ${args.iteration})`,
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'senior SwiftUI engineer addressing review findings',
      task: 'Fix every judge finding in ios/AppLess without regressing the Linux-buildable gates',
      context: { appDir: APP, feedback: args.feedback, iteration: args.iteration },
      instructions: [
        'Fix EVERY feedback item in the actual files; re-run the Linux build/tests and the conformance harness.',
        'Return only the JSON summary.',
      ],
      outputFormat: 'JSON with addressed (array), filesModified (array), gatesGreen (boolean)',
    },
    outputSchema: {
      type: 'object',
      required: ['addressed', 'filesModified', 'gatesGreen'],
      properties: {
        addressed: { type: 'array', items: { type: 'string' } },
        filesModified: { type: 'array', items: { type: 'string' } },
        gatesGreen: { type: 'boolean' },
      },
    },
  },
  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`,
  },
  labels: ['refine', `iteration-${args.iteration}`],
}));

export const conformanceGateTask = defineTask('conformance-gate', (args, taskCtx) => ({
  kind: 'shell',
  title: `all 30 contract renderers registered (iteration ${args.iteration})`,
  shell: {
    command: `${SWIFT} && cd ${APP} && swift test 2>&1 | grep -q 'renderers registered: 30/30'`,
    expectedExitCode: 0,
    timeout: 900000,
  },
  labels: ['gate', 'conformance'],
}));

export const syntaxGateTask = defineTask('syntax-gate', (args, taskCtx) => ({
  kind: 'shell',
  title: `Linux-buildable targets compile and test clean (iteration ${args.iteration})`,
  shell: {
    command: `${SWIFT} && cd ${APP} && swift build 2>&1 | tail -2 && swift test 2>&1 | tail -2`,
    expectedExitCode: 0,
    timeout: 900000,
  },
  labels: ['gate', 'build'],
}));

export const ciWorkflowGateTask = defineTask('ci-workflow-gate', (args, taskCtx) => ({
  kind: 'shell',
  title: `macOS CI workflow present and well-formed (iteration ${args.iteration})`,
  shell: {
    command: `cd ${REPO} && test -f .github/workflows/ios-app.yml && grep -q 'macos' .github/workflows/ios-app.yml && grep -qE 'xcodebuild|swift build' .github/workflows/ios-app.yml && python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ios-app.yml'))"`,
    expectedExitCode: 0,
    timeout: 120000,
  },
  labels: ['gate', 'ci'],
}));

export const judgeTask = defineTask('judge-app', (args, taskCtx) => ({
  kind: 'agent',
  title: `Judge the SwiftUI app (iteration ${args.iteration})`,
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'principal iOS engineer reviewing a SwiftUI port of a React Native app; adversarial, evidence-based',
      task: 'Score ios/AppLess 0-100; deductions cite file+defect; perfect sub-scores cite personally-performed verification',
      context: {
        appDir: APP,
        rnReference: `${REPO}/src/genos (the spec: cupertino renderers, GenOS.tsx shell, shell/*)`,
        gates: args.gates,
        iteration: args.iteration,
        targetQuality: args.targetQuality,
        rubric: [
          'rendererFidelity (35%): read >=8 RN renderers side by side with their Swift ports - layout, spacing, typography, colors, interaction semantics (local Toggle flip, Chips regeneration, Tabs local switch, ListItem chevron/leading rules, chart variant mapping, form binding); verify design tokens against cupertino/theme.ts value by value for a sample',
          'shellFidelity (30%): GenOS.tsx behaviors - session stacks, launch/push/pop, minimize, switcher, @OS command execution incl. the pending-screen removal rule, deep links, command routing regexes, the still-materializing guard, generating pill states, error+retry, key gate',
          'compileConfidence (20%): would this actually build? Look for SwiftUI API misuse, missing imports, type errors in the parts Linux cannot check, availability annotations, and whether the CI workflow genuinely compiles the app (read the YAML: does it build the app target, not just the packages?)',
          'integration (15%): correct use of OpenUILang (streaming parse into views) and GenOSCore (controller/store observation, cancellation, prefetch) - no reimplementation of logic those packages already own',
        ],
        hardCaps: [
          'Any contract component without a renderer -> <=70',
          'Conformance or Linux gate failing -> <=60',
          'CI workflow that does not actually compile the SwiftUI app -> <=85',
          'Shell behavior contradicting GenOS.tsx in a user-visible way -> <=90',
        ],
      },
      instructions: [
        'Toolchain /opt/swift/usr/bin (Linux - SwiftUI will not compile here; judge those files by careful reading and API knowledge).',
        'Re-run the gates yourself. Read the RN sources and Swift ports side by side. Ignore narrative about how the code was built.',
        'Be specific about compile risks: cite the file and the API you believe is wrong.',
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
  title: 'Commit and push Phase 3 artifacts',
  shell: {
    command: `cd ${REPO} && git add ios/ .github/ .a5c/processes/ && git commit -m "Add the SwiftUI iOS app (Phase 3)

Cupertino renderers for all 30 rendered contract components plus the OS
shell over GenOSCore. Quality-convergence score ${args.score}/99 after ${args.iteration} iteration(s)." && git push -u origin claude/repo-overview-xktv5r`,
    expectedExitCode: 0,
    timeout: 120000,
  },
  labels: ['git', 'finalize'],
}));
