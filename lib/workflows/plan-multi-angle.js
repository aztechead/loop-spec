// lib/workflows/plan-multi-angle.js
export const meta = {
  name: 'loop-spec-plan-multi-angle',
  description: 'Draft plans from N angles, judge-panel score, synthesize winner',
  phases: [
    { title: 'Draft' },
    { title: 'Judge' },
    { title: 'Synthesize' },
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
  return { plan: '# Dry-run plan', angles: [], dryRun: true }
}

const params = expandParams()
const allAngles = ['MVP-first', 'risk-first', 'dep-order-first', 'TDD-strict', 'user-first']
const angles = allAngles.slice(0, params.planAngles)
const specPath = args.specPath
const patternsPath = args.patternsPath

phase('Draft')
const drafts = await parallel(angles.map(angle => () =>
  agent(
    `Read ${specPath} and ${patternsPath}. Draft a PLAN.md from the ${angle} angle. Return JSON with {angle, plan, rationale}.`,
    { label: `draft:${angle}`, phase: 'Draft', schema: PLAN_DRAFT_SCHEMA }
  )
))

phase('Judge')
const validDrafts = drafts.filter(Boolean)
const scored = await parallel(validDrafts.map(d => () =>
  agent(
    `Score this plan draft (0-100) on completeness, feasibility, dependency clarity, risk-handling. Plan: ${JSON.stringify(d)}.`,
    { label: `judge:${d.angle}`,
      schema: { type: 'object', required: ['score', 'rationale'],
                properties: { score: { type: 'integer' }, rationale: { type: 'string' } } } }
  ).then(s => ({ ...d, score: s ? s.score : 0, judgeRationale: s ? s.rationale : '' }))
))

const ranked = scored.sort((a, b) => b.score - a.score)
const winner = ranked[0]
const runners = ranked.slice(1, 3)

phase('Synthesize')
const synth = await agent(
  `Synthesize the final PLAN.md. Start from the winner (angle=${winner.angle}, score=${winner.score}). Graft the best ideas from runners-up: ${JSON.stringify(runners.map(r => ({ angle: r.angle, score: r.score })))}. Return JSON with {plan: <markdown>}.`,
  { label: 'synthesize', schema: { type: 'object', required: ['plan'], properties: { plan: { type: 'string' } } } }
)

return {
  plan: synth.plan,
  angles: ranked.map(r => ({ name: r.angle, score: r.score, rationale: r.judgeRationale })),
  winner: winner.angle,
}
