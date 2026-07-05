// lib/workflows/execute-dag.js
export const meta = {
  name: 'loop-spec-execute-dag',
  description: 'Deterministic DAG-wave EXECUTE: per-task raw worktrees, spec-compliance gate, dedicated ff-merge agent',
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
  required: ['id', 'verdict', 'evidence', 'testSuiteStatus'],
  properties: {
    id: { type: 'string' },
    verdict: { enum: ['PASS', 'FAIL'] },
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
// Inlined into every implementer prompt because a SessionStart hook does not reach a
// Workflow-dispatched agent, so the simplicity discipline must travel in the prompt.
// MUST stay outside the @inject blocks above (those are regenerated from snippets).
const LAZINESS_LADDER =
  'SIMPLICITY (ponytail laziness ladder — on by default). Write the shortest solution that ' +
  'actually works; the best code is the code never written. BEFORE writing code, stop at the ' +
  'first rung that holds: (1) does it need to exist at all? speculative = skip it (YAGNI); ' +
  '(2) already in this codebase? reuse the existing helper/util/type/pattern, do not ' +
  're-implement it; (3) stdlib does it? use it; (4) native platform feature covers it? use it; ' +
  '(5) an already-installed dependency solves it? use it, never add a new one for what a few ' +
  'lines do; (6) can it be one line? one line; (7) only then, the minimum code that works. The ' +
  'ladder runs AFTER you understand the problem. Bug fix = root cause, not symptom. NEVER cut ' +
  'input validation at trust boundaries, error handling that prevents data loss, security, ' +
  'accessibility, or anything the spec requires. Non-trivial logic leaves ONE runnable check ' +
  'behind. Mark deliberate shortcuts with a simplicity: comment.'

// Design-for-change directive (canonical: skills/shared/design-for-change.md). Travels
// with the ladder for the same reason: a Workflow-dispatched agent sees only its prompt.
const DESIGN_FOR_CHANGE =
  'DESIGN FOR CHANGE (seams, not speculation — on by default). Design to the task\'s stated ' +
  'interface, not an implementation detail; one unit, one reason to change. New units receive ' +
  'their collaborators (params/args/env), never construct them deep inside. Never cut a seam ' +
  'to save lines, and never build speculation behind one (YAGNI cuts artifacts, not seams). ' +
  'Bug-fix tasks: after the root cause is fixed, sweep callers, copy-pasted patterns, and ' +
  'parallel paths for the same mechanism; fix same-cause siblings within the task files ' +
  'scope, report the rest.'

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
  required: ['merged', 'zeroCommit'],
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
  },
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
} = args


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
const mergedSet = new Set()
const mergedOrder = []
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
    const taskWorktreePath = `${featureWorktreeRoot}/.loop-spec/worktrees/${slug}/task-${taskId}`

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

${LAZINESS_LADDER}

${DESIGN_FOR_CHANGE}

Step 1 - Create the task worktree (only on first attempt; skip if it already exists):
  git -C "${featureWorktreeRoot}" worktree add "${taskWorktreePath}" -b "${taskBranch}" "${featureBranch}"
If the worktree already exists, skip worktree creation and proceed.

Step 2 - ${readFirstClause ? readFirstClause + ' Then r' : 'R'}ead the assigned files: ${(task.files || []).join(', ') || '(see brief)'}.

${specPathClause}

Step 3 - Implement the task in the task worktree at ${taskWorktreePath}.
Task subject: ${task.subject}
Brief: ${task.brief}
${acceptanceCriteriaClause}
${findingsClause}

Touch ONLY the files listed in the task (${(task.files || []).join(', ') || 'as described in the brief'}). Do NOT edit unrelated files. Do NOT use em-dashes.

Step 4 - Run the configured quality commands INSIDE the task worktree (${taskWorktreePath}). Skip any that are blank:
${[['Lint', commands.lint], ['Test', commands.test], ['Typecheck', commands.typecheck]].filter(([, c]) => c && String(c).trim()).map(([k, c]) => `  ${k}: ${c}`).join('\n') || '  (no commands configured; skip this step)'}

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

  // Dedicated merge agent: merges passed tasks sequentially into featureBranch.
  // Each task block below is fully interpolated (concrete branch + absolute
  // worktree path) so the agent never has to reconstruct any path itself.
  const mergeSteps = passed.map((p, i) => `### Task ${i + 1} of ${passed.length}: ${p.taskId}
1. Guard - verify the branch has commits over the base:
   bash "${skillDir}/../../lib/worktree-commit-check.sh" "${featureBranch}" "${p.branch}"
   If it exits non-zero (zero commits), add "${p.taskId}" to zeroCommit and SKIP to the next task.
2. Checkout the feature branch (no-op inside the feature worktree):
   git -C "${featureWorktreeRoot}" checkout ${featureBranch}
3. Attempt the fast-forward merge:
   git -C "${featureWorktreeRoot}" merge --ff-only ${p.branch}
4. If step 3 fails (diverged):
   a. Rebase the task worktree onto the feature branch:
      git -C "${p.worktreePath}" rebase ${featureBranch}
   b. If the rebase succeeds, retry: git -C "${featureWorktreeRoot}" merge --ff-only ${p.branch}
   c. If the rebase CONFLICTS: STOP immediately, do not touch later tasks, set
      conflict = { taskId: "${p.taskId}", detail: "<conflict summary>" } and return.
On success, add "${p.taskId}" to merged.`).join('\n\n')

  const mergeResult = await agent(
    `You are the merge agent for the EXECUTE workflow. ff-merge each passed task branch
INTO "${featureBranch}" sequentially. All paths below are absolute and concrete; run
them exactly as written. Process the tasks strictly in the given order.

${mergeSteps}

Return JSON:
{
  "merged": ["<taskId merged successfully>", ...],
  "conflict": null | { "taskId": "<id>", "detail": "<description>" },
  "zeroCommit": ["<taskId skipped for zero commits>", ...]
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
  }
}

return {
  merged: mergedOrder,
  blocked,
  escalation,
}
