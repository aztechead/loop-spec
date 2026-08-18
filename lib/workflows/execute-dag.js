// lib/workflows/execute-dag.js
export const meta = {
  name: 'loop-spec-execute-dag',
  description: 'Deterministic DAG-wave EXECUTE: per-task worktrees, spec-compliance gate, transactional integration',
  phases: [
    { title: 'Implement' },
  ],
}

// @inject:tier-params
// lib/workflows/templates/tier-params.snippet.js
// Single-tier operation (v2.5.0 hard cutover): fixed fan-out parameters.
// The `tier` argument is gone; callers use expandParams() with no arguments.
function expandParams() {
  return { refuteVoters: 3, planAngles: 3, dimensionReviewers: 3, completenessCritic: true }
}
// @inject:end

// @inject:schemas
// lib/workflows/templates/schemas.snippet.js
const FINDINGS_SCHEMA = {
  type: 'object',
  required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['file', 'line', 'severity', 'claim'],
        properties: {
          file: { type: 'string' },
          line: { type: 'integer' },
          severity: { enum: ['Critical', 'Important', 'Minor'] },
          claim: { type: 'string' },
          dimension: { enum: ['correctness', 'security', 'performance', 'style'] },
        },
      },
    },
  },
}

const VERDICT_SCHEMA = {
  type: 'object',
  required: ['real', 'rationale'],
  properties: {
    real: { type: 'boolean' },
    rationale: { type: 'string' },
  },
}

const ACCEPTANCE_SCHEMA = {
  type: 'object',
  required: ['id', 'verdict', 'repositoryEvidence', 'evidence', 'testSuiteStatus'],
  properties: {
    id: { type: 'string' },
    verdict: { enum: ['PASS', 'FAIL'] },
    repositoryEvidence: { type: 'array', items: { type: 'string' } },
    evidence: { type: 'string' },
    testSuiteStatus: { enum: ['PASS', 'FAIL', 'N/A'] },
  },
}

const MAP_DOMAIN_SCHEMA = {
  type: 'object',
  required: ['name', 'mdPath', 'coverage'],
  properties: {
    name: { enum: ['tech', 'arch', 'quality', 'concerns', 'domain'] },
    mdPath: { type: 'string' },
    coverage: { type: 'number', minimum: 0, maximum: 1 },
    weakSpots: { type: 'array', items: { type: 'string' } },
  },
}

const PLAN_DRAFT_SCHEMA = {
  type: 'object',
  required: ['angle', 'plan'],
  properties: {
    angle: { type: 'string' },
    plan: { type: 'string' },
    rationale: { type: 'string' },
  },
}
// @inject:end

// EXECUTE-specific schemas (plain consts; NOT inside @inject:schemas)

// Ponytail laziness-ladder directive (canonical: skills/shared/laziness-ladder.md).
// Named in every implementer prompt because a SessionStart hook does not reach a
// Workflow-dispatched agent. MUST stay outside the @inject blocks above.
// Probe paths are built from the injected skillDir; when it is absent the sentence
// naming the probe drops out and the rung stands on its own.
const lazinessLadder = (libDir) =>
  'SIMPLICITY (ponytail laziness ladder — on by default). Read ' +
  (libDir ? libDir + '/../skills/shared/laziness-ladder.md' : 'skills/shared/laziness-ladder.md') +
  ' before writing code — do not paste it. YAGNI, then DRY: reuse what is already here. ' +
  (libDir
    ? 'Before DONE run `bash ' + libDir + '/indirection-scan.sh scan <files you touched>` ' +
      'and `bash ' + libDir + '/duplication-scan.sh scan <files you touched>` (`duplicate=` same lines, `similar=` names-changed; both count).'
    : 'Grep the tree for the distinctive line of anything you wrote from scratch before ' +
      'you call it new.')

// Design-for-change directive (canonical: skills/shared/design-for-change.md). Travels
// with the ladder for the same reason: a Workflow-dispatched agent sees only its prompt.
const designForChange = (libDir) =>
  'DESIGN FOR CHANGE (seams, not speculation — on by default). Read ' +
  (libDir ? libDir + '/../skills/shared/design-for-change.md' : 'skills/shared/design-for-change.md') +
  ' — do not paste it. Design to an interface; one unit, ' +
  'one reason to change; receive collaborators.'

// Code-for-humans directive (canonical: skills/shared/human-code.md). Travels with the
// ladder for the same reason: a Workflow-dispatched agent sees only its prompt.
//
// The probe paths are built from the injected skillDir; when it is absent the sentences
// that name them drop out and the directive degrades to reading the neighbors by hand.
const codeForHumans = (libDir) =>
  'CODE FOR HUMANS (house style over habit — on by default). Read ' +
  (libDir ? libDir + '/../skills/shared/human-code.md' : 'skills/shared/human-code.md') +
  ' before writing code — do not paste it. Read the neighbors. Comments carry WHY, never ' +
  'what. NEVER cut simplicity: markers. ' +
  (libDir
    ? 'Before DONE run `bash ' + libDir + '/house-style.sh probe <files>`; `bash ' +
      libDir + '/house-style.sh compare <files you touched>`; `bash ' + libDir +
      '/comment-tells.sh scan <files>`; `bash ' + libDir +
      '/failure-tells.sh scan <files you touched>`. '
    : 'Where the convention is unclear, read three neighboring files end to end before ' +
      'writing, and follow what they do. ') +
  'CODE A HUMAN CAN OPERATE: fail loudly, or say why you did not.'

// Docs-for-humans directive (canonical: skills/shared/human-docs.md). The markdown a task
// leaves behind is maintained and operated by a person, and it takes the probe directory on
// the same terms as codeForHumans: without skillDir the sentence naming the probe drops out
// and the agent checks its own documents by hand.
const docsForHumans = (libDir) =>
  'DOCS FOR HUMANS (the markdown is a deliverable too — on by default). Read ' +
  (libDir ? libDir + '/../skills/shared/human-docs.md' : 'skills/shared/human-docs.md') +
  ' — do not paste it. One job per document. Cite, never copy. If your change makes a ' +
  'document false, fix it IN THIS DIFF; a follow-up documentation task is deferred scope. ' +
  (libDir
    ? 'Before DONE run `bash ' + libDir + '/doc-tells.sh scan <the markdown you touched>`. '
    : 'Before DONE, open every document you touched and follow its links and paths ' +
      'yourself. ') +
  'NEVER cut frontmatter, machine-read contract sections, required artifact headings, EVID ' +
  'citation lines, or license blocks.'


// Execution-discipline directive (canonical: skills/shared/execution-discipline.md).
// Travels with the ladder for the same reason: a Workflow-dispatched agent sees only
// its prompt.
const EXECUTION_DISCIPLINE =
  'EXECUTION DISCIPLINE (evidence over recall — on by default). You execute a brief a ' +
  'stronger reasoning pass produced; your job is fidelity, not improvisation. Verify, do ' +
  'not recall: never assert what a file/command does from memory — read it, run it, paste ' +
  'the actual output. Surprise is signal: output contradicting expectation means stop and ' +
  'revise, never explain away. Re-read the acceptance criteria before DONE and check each ' +
  'against actual output. "Should work" / "probably fine" / "tests likely pass" each mean ' +
  'run it now. Scope is closed: the acceptance criteria are the whole job — never skip, ' +
  'trim, or defer an item, and never write follow-up/deferred/future-work notes; a ' +
  'criterion you cannot meet is a loud failure with evidence, never a note.'

const IMPLEMENTER_RESULT_SCHEMA = {
  type: 'object',
  required: ['taskId', 'branch', 'committed'],
  properties: {
    taskId: { type: 'string' },
    branch: { type: 'string' },
    committed: { type: 'boolean' },
    sha: { type: 'string' },
    notes: { type: 'string' },
  },
}

const REVIEW_VERDICT_SCHEMA = {
  type: 'object',
  required: ['verdict', 'findings'],
  properties: {
    verdict: { enum: ['pass', 'rework', 'block'] },
    findings: { type: 'array', items: { type: 'string' } },
  },
}

const MERGE_RESULT_SCHEMA = {
  type: 'object',
  required: ['merged', 'zeroCommit', 'integrationFailure'],
  properties: {
    merged: { type: 'array', items: { type: 'string' } },
    conflict: {
      type: ['object', 'null'],
      properties: {
        taskId: { type: 'string' },
        detail: { type: 'string' },
      },
    },
    zeroCommit: { type: 'array', items: { type: 'string' } },
    integrationFailure: {
      type: ['object', 'null'],
      properties: {
        taskId: { type: 'string' },
        reason: { type: 'string' },
        detail: { type: 'string' },
      },
    },
  },
}

function shellQuote(value) {
  return `'${String(value ?? '').replace(/'/g, `'"'"'`)}'`
}

if (args && args.dryRun) {
  return { merged: [], blocked: [], escalation: null, dryRun: true }
}

const {
  slug,
  featureWorktreeRoot,
  featureBranch,
  models,
  maxParallelImplementers,
  maxRetriesPerTask,
  reviewersEnabled,
  commands,
  skillDir,
  tasks,
  taskWorktreeBase,
  doneTaskIds: doneTaskIdsArg,
} = args

// Where per-task worktrees live is injected, not assumed: lib/worktree-base.sh resolves
// it for the caller and relocates it outside the repository when the in-repo base cannot
// hold a checkout. Fall back to the historical location when the caller omits it.
const worktreeBase = taskWorktreeBase || `${featureWorktreeRoot}/.loop-spec/worktrees/${slug}`


// Build task lookup and tracking state
const byId = {}
for (const t of tasks) {
  byId[t.id] = t
}

// Stable reason vocabulary (returned in blocked[].reason and escalation.reason).
// Consumers display these; none are pattern-matched, but keep the set fixed so a
// human reading a paused EXECUTE always sees a known value:
//   blocked[].reason:    "spec-compliance-block" (reviewer verdict block),
//                        "retry-exhausted" (committed but never passed review),
//                        "commit-missing" (implementer produced no commit),
//                        "zero-commit" (merge guard found no commits over base)
//   escalation.reason:   "deadlock" (no ready tasks but work remains),
//                        "rebase-conflict" (merge agent hit an unresolved rebase)
const mergedSet = new Set(Array.isArray(doneTaskIdsArg) ? doneTaskIdsArg : [])
const mergedOrder = [...mergedSet]
const blocked = []
let escalation = null

// Main DAG loop
while (true) {
  const unmergedIds = tasks.map(t => t.id).filter(id => !mergedSet.has(id) && !blocked.find(b => b.taskId === id))
  if (unmergedIds.length === 0) break

  // Find ready tasks: all blockedBy resolved
  const ready = unmergedIds.filter(id => {
    const t = byId[id]
    return (t.blockedBy || []).every(dep => mergedSet.has(dep))
  })

  if (ready.length === 0) {
    escalation = {
      reason: 'deadlock',
      detail: 'unmergeable dependency cycle or all remaining blocked',
    }
    break
  }

  const wave = ready.slice(0, maxParallelImplementers)

  // Run wave tasks in parallel; each is an implement+review chain
  const waveResults = await parallel(wave.map((taskId, waveIdx) => async () => {
    const task = byId[taskId]
    const taskBranch = `task/${taskId}-${slug}`
    const taskWorktreePath = `${worktreeBase}/task-${taskId}`

    const specPathClause = task.specPath
      ? `The spec for this task is at ${task.specPath}. Read it before implementing.`
      : 'No per-task spec path is available; use the brief and acceptance criteria below.'

    const readFirstClause = (task.readFirst || []).length > 0
      ? `Read these files before implementing: ${task.readFirst.join(', ')}.`
      : ''

    const acceptanceCriteriaClause = (task.acceptanceCriteria || []).length > 0
      ? `Acceptance criteria:\n${task.acceptanceCriteria.map((c, i) => `  ${i + 1}. ${c}`).join('\n')}`
      : ''

    // Implementer with retry loop
    let implResult = null
    let reviewVerdict = null
    let priorFindings = []

    for (let attempt = 0; attempt < maxRetriesPerTask; attempt++) {
      const findingsClause = priorFindings.length > 0
        ? `\n\nPrevious review found the following issues that must be fixed:\n${priorFindings.map((f, i) => `  ${i + 1}. ${f}`).join('\n')}`
        : ''

      const attemptLabel = `implement:${taskId}:attempt-${attempt + 1}`

      implResult = await agent(
        `You are an implementer agent for task ${taskId} (wave index ${waveIdx}).

IMPORTANT: All paths must be ABSOLUTE. Do not use relative paths.

${lazinessLadder(skillDir ? `${skillDir}/../../lib` : '')}

${designForChange(skillDir ? `${skillDir}/../../lib` : '')}

${codeForHumans(skillDir ? `${skillDir}/../../lib` : '')}

${docsForHumans(skillDir ? `${skillDir}/../../lib` : '')}

${EXECUTION_DISCIPLINE}

Step 1 - Create the task worktree (only on first attempt; skip if it already exists):
  git -C "${featureWorktreeRoot}" worktree add "${taskWorktreePath}" -b "${taskBranch}" "${featureBranch}"
If the worktree already exists, skip worktree creation and proceed.

Step 1.5 - Prepare declared dev/test dependencies in the task worktree:
  bash ${shellQuote(`${skillDir}/../../lib/prepare-environment.sh`)} run --root ${shellQuote(taskWorktreePath)} --command ${shellQuote(commands.prepare || '')} --reuse-from ${shellQuote(featureWorktreeRoot)}
If preparation fails, do not edit product code to mask the environment failure.

Step 2 - ${readFirstClause ? readFirstClause + ' Then r' : 'R'}ead the assigned files: ${(task.files || []).join(', ') || '(see brief)'}.

${specPathClause}

Step 3 - Implement the task in the task worktree at ${taskWorktreePath}.
Task subject: ${task.subject}
Brief: ${task.brief}
${acceptanceCriteriaClause}
${findingsClause}

Touch ONLY the files listed in the task (${(task.files || []).join(', ') || 'as described in the brief'}). Do NOT edit unrelated files. Do NOT use em-dashes.

Step 4 - Run the task-specific verify command inside the task worktree:
  ${task.verifyCommand || 'true'}
Repository-wide quality commands run later through the exact-base comparison against the
rebased candidate; unchanged pre-existing failures must not block this task.

Step 5 - Stage and commit all changes inside the task worktree:
  git -C "${taskWorktreePath}" add <files>
  git -C "${taskWorktreePath}" commit -m "feat: NO_JIRA ${task.subject}"
Do NOT push. Do NOT run any other git commands outside the task worktree.

Return JSON: { taskId: "${taskId}", branch: "${taskBranch}", committed: <true|false>, sha: "<commit sha or empty>", notes: "<any relevant notes>" }`,
        { label: attemptLabel, phase: 'Implement', schema: IMPLEMENTER_RESULT_SCHEMA }
      )

      if (!implResult || !implResult.committed) {
        reviewVerdict = { verdict: 'block', findings: ['Implementer did not produce a commit'] }
        break
      }

      if (!reviewersEnabled) {
        reviewVerdict = { verdict: 'pass', findings: [] }
        break
      }

      // Spec-compliance review
      const reviewResult = await agent(
        `You are a spec-compliance reviewer for task ${taskId} (attempt ${attempt + 1}).

Review the diff of branch "${taskBranch}" against "${featureBranch}" in the worktree at "${taskWorktreePath}":
  git -C "${taskWorktreePath}" diff "${featureBranch}"..HEAD

${specPathClause}

${acceptanceCriteriaClause}

Determine whether the implementation satisfies all acceptance criteria and matches the spec.

Over-engineering pass (ponytail): scan the diff for complexity it does not need and flag each as a rework finding -- delete (dead/speculative code), stdlib (hand-rolled thing the standard library ships), yagni (abstraction with one implementation / config nobody sets), shrink (same logic, fewer lines). Do not flag the ponytail minimum (a single smoke/assert check or an accepted simplicity:-marked shortcut).

Return one of:
  - verdict "pass"  if everything is satisfied
  - verdict "rework" with specific findings if fixable issues exist (including over-engineering)
  - verdict "block"  if the implementation is fundamentally wrong or unrecoverable

Return JSON: { verdict: "pass"|"rework"|"block", findings: ["<finding 1>", ...] }`,
        { label: `review:${taskId}:attempt-${attempt + 1}`, phase: 'Implement', schema: REVIEW_VERDICT_SCHEMA }
      )

      reviewVerdict = reviewResult || { verdict: 'block', findings: ['Reviewer returned no result'] }

      if (reviewVerdict.verdict === 'pass') break
      if (reviewVerdict.verdict === 'block') break

      // rework: feed findings into next attempt
      priorFindings = reviewVerdict.findings || []
    }

    const finalVerdict = reviewVerdict ? reviewVerdict.verdict : 'block'
    const committed = implResult ? implResult.committed : false

    return {
      taskId,
      branch: taskBranch,
      worktreePath: taskWorktreePath,
      verdict: finalVerdict,
      committed,
    }
  }))

  // Partition wave results
  const passed = waveResults.filter(r => r && r.verdict === 'pass' && r.committed)
  const blockedThisWave = waveResults.filter(r => !r || r.verdict !== 'pass' || !r.committed)

  for (const b of blockedThisWave) {
    if (b) {
      // reason: block = unrecoverable; rework (with a commit) = retries exhausted;
      // otherwise the implementer never produced a commit.
      const reason = b.verdict === 'block'
        ? 'spec-compliance-block'
        : (b.committed ? 'retry-exhausted' : 'commit-missing')
      blocked.push({ taskId: b.taskId, reason })
    }
  }

  if (passed.length === 0) {
    // No tasks merged this wave; continue to find if more are ready (or deadlock)
    continue
  }

  // Dedicated integration agent: invokes the deterministic helper sequentially.
  // Each task block below is fully interpolated (concrete branch + absolute
  // worktree path) so the agent never has to reconstruct any path itself.
  const mergeSteps = passed.map((p, i) => {
    const candidateVerify = byId[p.taskId].verifyCommand || 'true'
    return `### Task ${i + 1} of ${passed.length}: ${p.taskId}
1. Run exactly this command and capture stdout plus its exit code:
   integration_json=$(bash ${shellQuote(`${skillDir}/../../lib/integrate-task.sh`)} --feature-root ${shellQuote(featureWorktreeRoot)} --feature-branch ${shellQuote(featureBranch)} --task-worktree ${shellQuote(p.worktreePath)} --task-branch ${shellQuote(p.branch)} --verify ${shellQuote(candidateVerify)} --cleanup); integration_rc=$?
2. Parse integration_json with jq. Never infer repository state from prose or integration_rc.
3. If .published is true, add "${p.taskId}" to merged and persist that fact with:
   bash ${shellQuote(`${skillDir}/../../lib/task-progress.sh`)} mark-done ${shellQuote(`${featureWorktreeRoot}/.loop-spec/features/${slug}/tasks.json`)} ${shellQuote(p.taskId)}
   A non-zero mark-done exit is a warning (sidecar missing or unknown id), not an integration failure. If .status is failed too, set integrationFailure from .reason/.detail and STOP because publication succeeded but cleanup did not.
4. If .published is false and .reason is "zero-commit", add "${p.taskId}" to zeroCommit and continue.
5. For every other failure, set integrationFailure = { taskId: "${p.taskId}", reason: .reason, detail: .detail } and STOP. Do not run git cleanup, stash, reset, merge, or rebase yourself.`
  }).join('\n\n')

  const mergeResult = await agent(
    `You are the integration agent for the EXECUTE workflow. Integrate each passed task
branch into "${featureBranch}" sequentially through integrate-task.sh. All paths below
are absolute and concrete; run them exactly as written. Process tasks strictly in order.

${mergeSteps}

Run NO repository-wide suite here. Each task's focused verify command above already ran
after any rebase, and that is the only command this wave executes. The
test/lint/typecheck comparison runs exactly once per cycle, at VERIFY Step 1.75, against
the fully integrated candidate.

Return JSON:
{
  "merged": ["<taskId merged successfully>", ...],
  "conflict": null,
  "zeroCommit": ["<taskId skipped for zero commits>", ...],
  "integrationFailure": null | { "taskId": "<id>", "reason": "<helper reason>", "detail": "<helper detail>" }
}`,
    { label: 'merge-agent', phase: 'Implement', schema: MERGE_RESULT_SCHEMA }
  )

  if (mergeResult) {
    for (const id of mergeResult.merged || []) {
      mergedSet.add(id)
      mergedOrder.push(id)
    }
    for (const id of mergeResult.zeroCommit || []) {
      blocked.push({ taskId: id, reason: 'zero-commit' })
    }
    if (mergeResult.conflict) {
      escalation = {
        taskId: mergeResult.conflict.taskId,
        reason: 'rebase-conflict',
        detail: mergeResult.conflict.detail,
      }
      break
    }
    if (mergeResult.integrationFailure) {
      const failure = mergeResult.integrationFailure
      if (failure.reason === 'verify-failed' || failure.reason === 'prepare-failed') {
        blocked.push({ taskId: failure.taskId, reason: 'retry-exhausted' })
      } else {
        escalation = {
          taskId: failure.taskId,
          reason: 'rebase-conflict',
          detail: `${failure.reason}: ${failure.detail}`,
        }
        break
      }
    }
  }
}

return {
  merged: mergedOrder,
  blocked,
  escalation,
}
