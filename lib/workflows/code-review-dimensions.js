// lib/workflows/code-review-dimensions.js
export const meta = {
  name: 'super-spec-code-review-dimensions',
  description: 'Multi-dimension code review with per-finding adversarial refute panel',
  phases: [
    { title: 'Review' },
    { title: 'Refute' },
  ],
}

// @inject:tier-params
// lib/workflows/templates/tier-params.snippet.js
function expandTierParams(tier) {
  const matrix = {
    quality:  { refuteVoters: 5, planAngles: 5, dimensionReviewers: 4, completenessCritic: true },
    balanced: { refuteVoters: 3, planAngles: 3, dimensionReviewers: 3, completenessCritic: true },
    quick:    { refuteVoters: 1, planAngles: 1, dimensionReviewers: 1, completenessCritic: false },
  }
  return matrix[tier] || matrix.balanced
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

if (args && args.dryRun) {
  return { findings: [], critical: 0, important: 0, dryRun: true }
}

const params = expandTierParams(args.tier || 'balanced')
const allDims = ['correctness', 'security', 'performance', 'style']
const dims = allDims.slice(0, params.dimensionReviewers)
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
return { findings, critical, important, tier: args.tier || 'balanced' }
