// lib/workflows/map-codebase.js
export const meta = {
  name: 'loop-spec-map-codebase',
  description: 'Map codebase domains in parallel with optional completeness critic',
  phases: [
    { title: 'Map domains' },
    { title: 'Completeness critic' },
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
    domains: (args.staleDomains || ['arch']).map(d => ({
      name: d, mdPath: `docs/loop-spec/codebase/${d}.md`, coverage: 0.9, weakSpots: []
    })),
    dryRun: true,
  }
}

const params = expandParams()
const stale = args.staleDomains || ['tech', 'arch', 'quality', 'concerns', 'domain']

phase('Map domains')
const mapped = await parallel(stale.map(d => () =>
  agent(
    `Refresh the ${d} domain map. Read docs/loop-spec/codebase/${d}.md, refresh from current repo state, write the updated markdown back to that file, then return the structured summary.`,
    { label: `mapper:${d}`, phase: 'Map domains', schema: MAP_DOMAIN_SCHEMA }
  )
))

let domains = mapped.filter(Boolean)

if (params.completenessCritic) {
  phase('Completeness critic')
  const critic = await agent(
    `Given these mapped domains: ${JSON.stringify(domains)}, identify any with coverage < 0.7 or non-empty weakSpots. Return a list of domain names that need a second pass.`,
    { label: 'critic', phase: 'Completeness critic',
      schema: { type: 'object', required: ['remap'], properties: { remap: { type: 'array', items: { type: 'string' } } } } }
  )
  if (critic && critic.remap && critic.remap.length) {
    const remapped = await parallel(critic.remap.map(d => () =>
      agent(
        `Re-map the ${d} domain with extra attention to weak coverage areas. Update docs/loop-spec/codebase/${d}.md and return the updated summary.`,
        { label: `remap:${d}`, phase: 'Completeness critic', schema: MAP_DOMAIN_SCHEMA }
      )
    ))
    const byName = Object.fromEntries(domains.map(x => [x.name, x]))
    remapped.filter(Boolean).forEach(x => byName[x.name] = x)
    domains = Object.values(byName)
  }
}

return { domains, staleDomainsRequested: stale }
