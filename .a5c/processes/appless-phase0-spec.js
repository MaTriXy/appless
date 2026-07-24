/**
 * @process appless/phase0-spec-convergence
 * @description Execute Phase 0 of docs/NATIVE_MIGRATION_PLAN.md (platform-neutral
 *   openui-lang spec + golden fixture corpus + contract JSON schema) with an
 *   iterative quality-convergence loop: agent authoring, deterministic shell
 *   gates, agent judge scoring, refine until score >= targetQuality.
 * @inputs { targetQuality: number, maxIterations: number }
 * @outputs { success: boolean, iterations: number, finalQuality: number, history: array }
 *
 * Pattern source: library tdd-quality-convergence.js (agent scoring convergence
 * loop) adapted for spec-extraction work. Reuse audit: scripts/embed-prompt.mjs
 * already regenerates the system prompt from the appless-os web repo; the spec
 * artifacts produced here must treat src/genos/generated/system-prompt.ts as
 * the current source of truth, not replace the embed pipeline yet.
 */

import { defineTask } from '@a5c-ai/babysitter-sdk';

const REPO = '/home/user/appless';
const PLAN = `${REPO}/docs/NATIVE_MIGRATION_PLAN.md`;

export async function process(inputs, ctx) {
  const { targetQuality = 99, maxIterations = 4 } = inputs;

  let iteration = 0;
  let score = 0;
  let converged = false;
  let feedback = null;
  const history = [];

  while (iteration < maxIterations && !converged) {
    iteration++;

    if (iteration === 1) {
      await ctx.task(authorSpecTask, {});
      await ctx.task(authorHarnessTask, {});
    } else {
      await ctx.task(refineTask, { feedback, iteration });
    }

    // Deterministic gates: the generator must run clean, every fixture must
    // have a valid expected tree, and the schema export must match zod.
    const generatorGate = await ctx.task(generatorGateTask, { iteration });
    const fixtureGate = await ctx.task(fixtureGateTask, { iteration });
    const schemaGate = await ctx.task(schemaGateTask, { iteration });

    const judged = await ctx.task(judgeTask, {
      iteration,
      targetQuality,
      gates: {
        generator: generatorGate,
        fixtures: fixtureGate,
        schema: schemaGate,
      },
    });

    score = judged.overallScore;
    feedback = judged.recommendations;
    history.push({
      iteration,
      score,
      criticalIssues: judged.criticalIssues || [],
      feedback,
    });

    converged = score >= targetQuality;
  }

  const approval = await ctx.breakpoint({
    question: `Phase 0 spec package scored ${score}/${targetQuality} after ${iteration} iteration(s). Commit and push to claude/repo-overview-xktv5r, and continue to Phase 1 (Swift parser)?`,
    title: 'Phase 0 convergence review',
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
    continueToPhase1: approval.approved && /continue/i.test(approval.response || ''),
    history,
    artifacts: {
      grammar: 'spec/openui-lang.md',
      capabilities: 'spec/capabilities.md',
      schema: 'spec/contract/genos.schema.json',
      fixtures: 'spec/fixtures/',
      generator: 'spec/fixtures/generator/',
    },
  };
}

// ---------------------------------------------------------------------------
// Authoring tasks
// ---------------------------------------------------------------------------

export const authorSpecTask = defineTask('author-spec', (args, taskCtx) => ({
  kind: 'agent',
  title: 'Author openui-lang grammar spec + capability map',
  description: 'Write spec/openui-lang.md, spec/capabilities.md, spec/icon-map.md',
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'language-runtime engineer writing a normative spec for reimplementation in Swift and Kotlin',
      task: 'Author the platform-neutral Layer-0 spec documents for the AppLess native migration',
      context: {
        repo: REPO,
        plan: PLAN,
        sources: [
          `${REPO}/src/genos/generated/system-prompt.ts (the DSL rules the model is told)`,
          `${REPO}/node_or_scratch: @openuidev/react-lang 0.1.5 package source (install it to read the real parser)`,
          `${REPO}/patches/@openuidev+react-lang+0.1.5.patch (behavioral deviations - MUST be reflected)`,
          `${REPO}/src/genos/store.ts (cleanLang, extractActions, parseOsCommand)`,
          `${REPO}/src/genos/GenOS.tsx (parseGenosUrl, action event shape)`,
          `${REPO}/src/genos/tools/images.ts (parseImgUrl)`,
          `${REPO}/src/genos/ui/contract.tsx (the 33-component contract)`,
          `${REPO}/src/genos/ui/icons.tsx (icon name handling, Lucide set)`,
        ],
      },
      instructions: [
        'Read the plan file section 3 (Layer 0) verbatim first: cat ' + PLAN,
        'npm-install @openuidev/react-lang@0.1.5 into a scratch dir under /tmp/appless-spec-research/ and READ ITS ACTUAL PARSER SOURCE - the spec must describe real behavior, not the prompt\'s idealized rules. Apply the repo patch file to the scratch copy first.',
        'Write spec/openui-lang.md: complete normative grammar (statements, expression forms, string escaping, positional args, references and reference-graph resolution, unreferenced-variable dropping, Action expressions, $bindings, @OS command form) PLUS a dedicated "Streaming semantics" section describing partial-program rendering behavior observed in the real parser, PLUS the cleanLang fence-stripping algorithm and the parseOsCommand / extractActions / parseGenosUrl / parseImgUrl helper behaviors with their exact regexes.',
        'Write spec/capabilities.md: the capability map from plan section 6, corrected against the code you read (do not copy blindly - verify each row).',
        'Write spec/icon-map.md: every icon name referenced in the RN codebase and prompt guidance, with proposed SF Symbols and Material Symbols equivalents in a table.',
        'Every normative claim in openui-lang.md must be traceable: where behavior comes from the patch or from parser source rather than the prompt, say so in a "Source:" footnote.',
        'Work fully; create the files under ' + REPO + '/spec/. Return only the JSON summary.',
      ],
      outputFormat: 'JSON with filesCreated (array of paths), parserFindings (array of strings: real-parser behaviors that differ from or refine the prompt rules), patchFindings (array of strings), openQuestions (array)',
    },
    outputSchema: {
      type: 'object',
      required: ['filesCreated', 'parserFindings', 'patchFindings'],
      properties: {
        filesCreated: { type: 'array', items: { type: 'string' } },
        parserFindings: { type: 'array', items: { type: 'string' } },
        patchFindings: { type: 'array', items: { type: 'string' } },
        openQuestions: { type: 'array', items: { type: 'string' } },
      },
    },
  },
  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`,
  },
  labels: ['authoring', 'spec'],
}));

export const authorHarnessTask = defineTask('author-harness', (args, taskCtx) => ({
  kind: 'agent',
  title: 'Author golden-fixture corpus + generator harness + schema export',
  description: 'spec/fixtures/*.oui, generator that derives expected trees from the REAL react-lang parser, zod JSON-schema export',
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'test-infrastructure engineer building a golden-fixture oracle',
      task: 'Build the fixture corpus and the generator that produces expected outputs from the actual @openuidev/react-lang 0.1.5 parser (with the repo patch applied), so future Swift/Kotlin parsers can be verified against real behavior',
      context: {
        repo: REPO,
        plan: PLAN,
        contract: `${REPO}/src/genos/ui/contract.tsx`,
        patch: `${REPO}/patches/@openuidev+react-lang+0.1.5.patch`,
        designHint: [
          'Self-contained npm package at spec/fixtures/generator/ with its own package.json depending ONLY on @openuidev/react-lang@0.1.5, react, react-test-renderer, zod, tsx/esbuild as needed - NOT the full Expo app.',
          'Apply the repo patch to the installed react-lang copy in a postinstall step (patch -p1 or patch-package).',
          'To capture expected trees headlessly: build the genos library from src/genos/ui/contract.tsx buildGenosLibrary() with stub renderers that RECORD (component name, resolved props, rendered children) into a serializable tree, render each fixture with the react-lang Renderer under react-test-renderer, and serialize the recorded tree deterministically (sorted keys, stable ordering) to NNN-name.expected.json.',
          'Partial/streaming fixtures: for each entry in spec/fixtures/partial/, the input is a prefix of a complete program; generate expected partial trees the same way with isStreaming=true.',
        ],
      },
      instructions: [
        'Read plan sections 3.1-3.3 verbatim first: cat ' + PLAN,
        'Author 60-80 fixtures under ' + REPO + '/spec/fixtures/: every one of the 33 contract components exercised at least once, nesting, multi-reference programs, out-of-order references, unreferenced-variable dropping, all Action forms (@ToAssistant, @OpenUrl, genos:// urls), $bindings in every form input, string escapes, unicode/emoji, markdown fences, malformed programs (unterminated string, unknown component, bad arity), @OS command responses, and a partial/ subdirectory of prefix-truncated streaming snapshots (at least 12, cutting mid-string, mid-call, mid-array, before root).',
        'Build the generator package at spec/fixtures/generator/ per designHint; entry point must be: npm install && npm run generate (regenerates all *.expected.json) and npm test (verifies generator output is deterministic across two runs).',
        'Also write spec/contract/export-schema.mjs: loads buildGenosLibrary with stub renderers, exports the full component contract via zod JSON-schema conversion to spec/contract/genos.schema.json, and run it to produce the file.',
        'A fixture README (spec/fixtures/README.md) documenting the corpus taxonomy and the coverage matrix (component x fixture table).',
        'Run everything yourself and make it pass before returning. Return only the JSON summary.',
      ],
      outputFormat: 'JSON with filesCreated (array), fixtureCount (number), partialFixtureCount (number), componentsCovered (array of the contract component names exercised), generatorRunClean (boolean), notes (array)',
    },
    outputSchema: {
      type: 'object',
      required: ['filesCreated', 'fixtureCount', 'partialFixtureCount', 'componentsCovered', 'generatorRunClean'],
      properties: {
        filesCreated: { type: 'array', items: { type: 'string' } },
        fixtureCount: { type: 'number' },
        partialFixtureCount: { type: 'number' },
        componentsCovered: { type: 'array', items: { type: 'string' } },
        generatorRunClean: { type: 'boolean' },
        notes: { type: 'array', items: { type: 'string' } },
      },
    },
  },
  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`,
  },
  labels: ['authoring', 'fixtures'],
}));

export const refineTask = defineTask('refine-spec', (args, taskCtx) => ({
  kind: 'agent',
  title: `Refine spec package (iteration ${args.iteration})`,
  description: 'Address judge feedback on the Phase 0 artifacts',
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'language-runtime engineer addressing review findings',
      task: 'Fix every judge finding in the Phase 0 spec package (spec/ directory) without regressing the deterministic gates',
      context: {
        repo: REPO,
        feedback: args.feedback,
        iteration: args.iteration,
      },
      instructions: [
        'Read the judge feedback in context; fix EVERY item, in the actual files under ' + REPO + '/spec/.',
        'Re-run spec/fixtures/generator (npm run generate && npm test) and spec/contract/export-schema.mjs after changes.',
        'Return only the JSON summary.',
      ],
      outputFormat: 'JSON with addressed (array: one entry per feedback item, what was done), filesModified (array), gatesRerunClean (boolean)',
    },
    outputSchema: {
      type: 'object',
      required: ['addressed', 'filesModified', 'gatesRerunClean'],
      properties: {
        addressed: { type: 'array', items: { type: 'string' } },
        filesModified: { type: 'array', items: { type: 'string' } },
        gatesRerunClean: { type: 'boolean' },
      },
    },
  },
  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`,
  },
  labels: ['refine', `iteration-${args.iteration}`],
}));

// ---------------------------------------------------------------------------
// Deterministic shell gates
// ---------------------------------------------------------------------------

export const generatorGateTask = defineTask('generator-gate', (args, taskCtx) => ({
  kind: 'shell',
  title: `Fixture generator runs clean (iteration ${args.iteration})`,
  description: 'npm install + generate + determinism test in spec/fixtures/generator',
  shell: {
    command: `cd ${REPO}/spec/fixtures/generator && npm install --no-audit --no-fund && npm run generate && npm test`,
    expectedExitCode: 0,
    timeout: 600000,
  },
  labels: ['gate', 'fixtures'],
}));

export const fixtureGateTask = defineTask('fixture-gate', (args, taskCtx) => ({
  kind: 'shell',
  title: `Every fixture has a valid expected tree (iteration ${args.iteration})`,
  description: 'Pair-check .oui inputs with parseable .expected.json outputs; fail on orphans',
  shell: {
    command: `cd ${REPO}/spec/fixtures && fail=0; count=0; for f in $(find . -name '*.oui'); do count=$((count+1)); exp="\${f%.oui}.expected.json"; if [ ! -f "$exp" ]; then echo "MISSING: $exp"; fail=1; elif ! jq empty "$exp" 2>/dev/null; then echo "INVALID JSON: $exp"; fail=1; fi; done; echo "fixtures=$count"; [ $count -ge 60 ] || { echo "FAIL: need >= 60 fixtures"; fail=1; }; [ $(find ./partial -name '*.oui' 2>/dev/null | wc -l) -ge 12 ] || { echo "FAIL: need >= 12 partial fixtures"; fail=1; }; exit $fail`,
    expectedExitCode: 0,
    timeout: 120000,
  },
  labels: ['gate', 'fixtures'],
}));

export const schemaGateTask = defineTask('schema-gate', (args, taskCtx) => ({
  kind: 'shell',
  title: `Contract JSON schema exports and parses (iteration ${args.iteration})`,
  description: 'Run export-schema.mjs and validate the emitted schema mentions every contract component',
  shell: {
    command: `cd ${REPO} && node spec/contract/export-schema.mjs && jq empty spec/contract/genos.schema.json && for c in Card CardHeader TextContent TextCallout ListItem Toggle ListBlock KVList HeroStat StatTiles ImageBlock PhotoGrid Bubbles Chips TabItem Tabs MapView BarChart LineChart AreaChart PieChart HorizontalBarChart Series Form FormControl Input TextArea Select SelectItem DatePicker Slider Buttons Button; do grep -q "\\"$c\\"" spec/contract/genos.schema.json || { echo "MISSING COMPONENT: $c"; exit 1; }; done`,
    expectedExitCode: 0,
    timeout: 300000,
  },
  labels: ['gate', 'schema'],
}));

// ---------------------------------------------------------------------------
// Judge + finalization
// ---------------------------------------------------------------------------

export const judgeTask = defineTask('judge-spec', (args, taskCtx) => ({
  kind: 'agent',
  title: `Judge Phase 0 quality (iteration ${args.iteration})`,
  description: 'Adversarial scoring of the spec package against the plan exit criteria',
  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'principal engineer reviewing a language spec + fixture oracle for cross-platform reimplementation; adversarial, evidence-based, does not award benefit of the doubt',
      task: 'Score the Phase 0 spec package 0-100 against the rubric; every deduction must cite a file and a concrete defect, every perfect sub-score must cite verification evidence',
      context: {
        repo: REPO,
        iteration: args.iteration,
        targetQuality: args.targetQuality,
        deterministicGates: args.gates,
        rubric: [
          'grammarSpec (25%): spec/openui-lang.md complete and ACCURATE against the real patched react-lang parser - spot-check at least 5 normative claims by reading parser source or running the generator on probe inputs; streaming semantics section must be concrete enough to implement from',
          'fixtureCoverage (30%): all 33 contract components exercised; coverage matrix in README truthful (verify by grep); partial/ corpus cuts at genuinely tricky boundaries; malformed-input fixtures present',
          'oracleFidelity (20%): expected trees come from the real patched parser via the generator (verify the patch is actually applied in the generator install; verify determinism test is real, not a stub)',
          'schemaFidelity (15%): genos.schema.json faithfully mirrors contract.tsx zod schemas including optionality/nullability and enum values - spot-check at least 5 components field-by-field',
          'docsQuality (10%): capabilities.md and icon-map.md correct against code; Source: footnotes present where spec relies on patch/parser behavior',
        ],
        hardCaps: [
          'Any contract component with zero fixture coverage: overallScore <= 90',
          'Patch not actually applied in generator: overallScore <= 70',
          'Any deterministic gate in context failed: overallScore <= 60',
          'Any normative claim you spot-check and find false: overallScore <= 92',
        ],
      },
      instructions: [
        'FIRST read the plan exit criterion verbatim: cat ' + PLAN + ' | sed -n "/## 9/,/## 10/p"',
        'Then inspect the ACTUAL artifacts under ' + REPO + '/spec/ - do the spot-checks in the rubric yourself with real commands; do not trust summaries in your context about how the artifacts were built.',
        'Compare PLAN exit criteria to ARTIFACTS directly. Ignore any narrative about how artifacts were produced.',
        'Score each rubric dimension 0-100, compute the weighted overall, apply hard caps, and give prioritized, actionable recommendations for anything below perfect.',
      ],
      outputFormat: 'JSON with overallScore (number), scores (object keyed by rubric dimension), evidence (array: spot-checks performed and outcomes), criticalIssues (array), recommendations (array, prioritized)',
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
  labels: ['judge', 'quality-scoring', `iteration-${args.iteration}`],
}));

export const commitPushTask = defineTask('commit-push', (args, taskCtx) => ({
  kind: 'shell',
  title: 'Commit and push Phase 0 artifacts',
  description: `Commit spec/ (+ .a5c process) at score ${args.score} and push to the designated branch`,
  shell: {
    command: `cd ${REPO} && git add spec/ .a5c/processes/ && git commit -m "Add Phase 0 spec package: openui-lang grammar, golden fixtures, contract schema

Quality-convergence run (babysitter): score ${args.score}/99 after ${args.iteration} iteration(s).
Fixture oracle derives expected trees from the real patched react-lang 0.1.5 parser." && git push -u origin claude/repo-overview-xktv5r`,
    expectedExitCode: 0,
    timeout: 120000,
  },
  labels: ['git', 'finalize'],
}));
