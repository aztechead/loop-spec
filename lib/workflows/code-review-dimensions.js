// lib/workflows/code-review-dimensions.js
export const meta = {
  name: 'loop-spec-code-review-dimensions',
  description: 'Multi-dimension code review with per-finding adversarial refute panel',
  phases: [
    { title: 'Review' },
    { title: 'Refute' },
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

if (args && args.dryRun) {
  return { findings: [], critical: 0, important: 0, dryRun: true }
}

const params = expandParams()
// Exactly the dimensions that get dispatched, listed rather than sliced. The previous
// form declared four and sliced to `dimensionReviewers` (fixed at 3), so `style` was
// silently never reviewed -- a dead entry that read like coverage.
//
// `style` stays out deliberately: the code-for-humans pass in agents/code-reviewer.md
// owns it and is probe-backed by lib/house-style.sh and lib/comment-tells.sh, which
// measures the house convention instead of asking a fourth agent's taste. The findings
// schema still accepts `style` because that pass emits it. The docs-for-humans pass
// (same file, 8.5) stays out for the same reason, probe-backed by lib/doc-tells.sh.
const dims = ['correctness', 'security', 'performance']
if (dims.length !== params.dimensionReviewers) {
  throw new Error(
    `dimension list (${dims.length}) and dimensionReviewers (${params.dimensionReviewers}) disagree; ` +
    'a dimension would go unreviewed or an agent would be dispatched without one'
  )
}
const diffBase = args.baseSha || 'main'

const reviewed = await pipeline(
  dims,
  d => agent(
    `Review the diff \`git diff ${diffBase}..HEAD\` along the ${d} dimension. Report findings as JSON. Be specific: file path, line number, severity, claim.`,
    { label: `review:${d}`, phase: 'Review', schema: FINDINGS_SCHEMA }
  ),
  (review, d) => parallel((review.findings || []).map(f => () =>
    parallel(Array.from({ length: params.refuteVoters }, (_, i) => () =>
      agent(
        `Try to REFUTE this ${d} finding: ${JSON.stringify(f)}. Inspect the code at ${f.file}:${f.line}. If you cannot reproduce the issue, set real=false. Default refuted when uncertain. Voter ${i + 1}/${params.refuteVoters}.`,
        { label: `refute:${d}:${f.file}:${i}`, phase: 'Refute', schema: VERDICT_SCHEMA }
      )
    )).then(votes => ({
      ...f, dimension: d,
      refuteVotes: votes.filter(Boolean),
      upheld: votes.filter(Boolean).filter(v => v.real).length > params.refuteVoters / 2,
    }))
  ))
)

const findings = reviewed.flat().filter(Boolean).filter(f => f.upheld)
const critical = findings.filter(f => f.severity === 'Critical').length
const important = findings.filter(f => f.severity === 'Important').length
return { findings, critical, important }
