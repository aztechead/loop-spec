// lib/workflows/acceptance-verify.js
export const meta = {
  name: 'super-spec-acceptance-verify',
  description: 'Verify acceptance criteria in parallel with adversarial refute panel',
  phases: [
    { title: 'Verify' },
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
  return {
    criteria: (args.criteria || []).map(c => ({
      id: c.id, verdict: 'PASS', evidence: 'dry-run', testSuiteStatus: 'N/A', refutes: []
    })),
    allPass: true,
    dryRun: true,
  }
}

const params = expandTierParams(args.tier || 'balanced')
const criteria = args.criteria || []  // [{id, verifyCommand, description}]

const results = await pipeline(
  criteria,
  c => agent(
    `Verify acceptance criterion ${c.id}: "${c.description}". Run the verify command \`${c.verifyCommand}\` via Bash. Determine verdict (PASS/FAIL), capture evidence, and set testSuiteStatus based on whether any pytest/jest/go-test output was observed (PASS=all green, FAIL=any failures, N/A=no test framework invoked).`,
    { label: `verify:${c.id}`, phase: 'Verify', schema: ACCEPTANCE_SCHEMA }
  ),
  (verdict, c) => parallel(
    Array.from({ length: params.refuteVoters }, (_, i) => () =>
      agent(
        `Try to REFUTE this acceptance verdict for criterion ${c.id}: ${JSON.stringify(verdict)}. Inspect the evidence; if you find ANY hole, set real=false. Default to refuted (real=false) when uncertain. Voter ${i + 1}/${params.refuteVoters}.`,
        { label: `refute:${c.id}:${i}`, phase: 'Refute', schema: VERDICT_SCHEMA }
      )
    )
  ).then(votes => ({
    ...verdict,
    refutes: votes.filter(Boolean).map(v => ({ real: v.real, rationale: v.rationale })),
    upheld: votes.filter(Boolean).filter(v => v.real).length > params.refuteVoters / 2,
  }))
)

const final = results.filter(Boolean)
const allPass = final.every(r => r.verdict === 'PASS' && r.upheld !== false)
return { criteria: final, allPass, tier: args.tier || 'balanced' }
