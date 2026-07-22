// lib/workflows/acceptance-verify.js
export const meta = {
  name: 'loop-spec-acceptance-verify',
  description: 'Verify acceptance criteria in parallel with adversarial refute panel',
  phases: [
    { title: 'Verify' },
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
  return {
    criteria: (args.criteria || []).map(c => ({
      id: c.id, verdict: 'PASS', repositoryEvidence: ['dry-run'], evidence: 'dry-run', testSuiteStatus: 'N/A', refutes: []
    })),
    allPass: true,
    dryRun: true,
  }
}

const params = expandParams()
const criteria = args.criteria || []  // [{id, verifyCommand, description}]
const requiredContext = ['baseSha', 'repositoryRoot', 'specPath', 'planPath']
const missingContext = requiredContext.filter(key => typeof args[key] !== 'string' || !args[key].trim())
if (missingContext.length || criteria.length === 0) {
  return {
    criteria: criteria.map(c => ({
      id: c.id,
      verdict: 'FAIL',
      repositoryEvidence: [],
      evidence: missingContext.length
        ? `missing workflow context: ${missingContext.join(', ')}`
        : 'no Good Enough criteria supplied',
      testSuiteStatus: 'N/A',
      refutes: [],
      upheld: false,
      groundingPass: false,
    })),
    allPass: false,
    contextError: missingContext,
  }
}

const results = await pipeline(
  criteria,
  c => agent(
    `Verify acceptance criterion ${c.id}: "${c.description}". Read ${args.specPath} and ${args.planPath}. Apply skills/shared/verification-grounding.md first: from repository ${args.repositoryRoot}, inspect git diff ${args.baseSha}..HEAD, re-read every changed file and the nearest caller/test/config/interface/contract, and populate repositoryEvidence with exactly "implementation: <repo-relative-file:line> - <what it proves>" and "integration: <repo-relative-file:line> - <what it proves>" entries. If no separate integration site exists, use "integration: none - <concrete reason>". Missing or mismatched repository evidence is FAIL. Then run the verify command \`${c.verifyCommand}\` via Bash from ${args.repositoryRoot}. Determine verdict (PASS/FAIL), capture command evidence, and set testSuiteStatus based on whether any pytest/jest/go-test output was observed (PASS=all green, FAIL=any failures, N/A=no test framework invoked).`,
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

const fileLine = /\b[^\s:]+:\d+\b/
const raw = results.filter(Boolean)
const expectedIds = criteria.map(c => c.id)
const unexpected = raw.filter(r => !expectedIds.includes(r.id))
const final = criteria.map(c => {
  const matches = raw.filter(r => r.id === c.id)
  if (matches.length !== 1) {
    return {
      id: c.id,
      verdict: 'FAIL',
      repositoryEvidence: [],
      evidence: matches.length ? 'duplicate verifier results' : 'missing verifier result',
      testSuiteStatus: 'N/A',
      refutes: [],
      upheld: false,
      groundingPass: false,
    }
  }
  const r = matches[0]
  const refs = Array.isArray(r.repositoryEvidence) ? r.repositoryEvidence : []
  const implementation = refs.find(e => /^implementation:\s*/i.test(e)) || ''
  const integration = refs.find(e => /^integration:\s*/i.test(e)) || ''
  const groundingPass = fileLine.test(implementation) &&
    (fileLine.test(integration) || /^integration:\s*none\s*-\s*.{10,}/i.test(integration))
  return groundingPass ? { ...r, groundingPass } : { ...r, verdict: 'FAIL', groundingPass }
})
const resultShapePass = raw.length === criteria.length && unexpected.length === 0 &&
  expectedIds.every(id => raw.filter(r => r.id === id).length === 1)
const allPass = resultShapePass &&
  final.every(r => r.verdict === 'PASS' && r.groundingPass && r.upheld !== false)
return { criteria: final, allPass }
