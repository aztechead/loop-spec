#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="$ROOT/lib/workflows/acceptance-verify.js"
NODE="node"
if ! command -v node >/dev/null 2>&1 || ! node --version >/dev/null 2>&1; then
  NODE="$HOME/.nvm/versions/node/v22.14.0/bin/node"
  if [[ ! -x "$NODE" ]]; then
    echo "SKIP: acceptance workflow behavioral tests require node"
    exit 0
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MODULE="$TMP/acceptance-verify.mjs"

python3 - "$SOURCE" "$MODULE" <<'PY'
import sys
source = open(sys.argv[1]).read().replace('export const meta', 'const meta')
tests = r'''

const validArgs = {
  criteria: [{ id: 'GE-001', description: 'works', verifyCommand: 'true' }],
  baseSha: 'abc123',
  repositoryRoot: '/repo',
  specPath: '/repo/SPEC.md',
  planPath: '/repo/PLAN.md',
}
const validResult = {
  id: 'GE-001', verdict: 'PASS',
  repositoryEvidence: [
    'implementation: src/app.js:1 - behavior',
    'integration: tests/app.test.js:1 - coverage',
  ],
  evidence: 'command passed', testSuiteStatus: 'PASS',
}

async function execute(args, results) {
  let dispatches = 0
  const agent = async (prompt, options) => {
    dispatches += 1
    if (options.label.startsWith('verify:')) {
      const id = options.label.split(':')[1]
      return Object.prototype.hasOwnProperty.call(results, id) ? results[id] : null
    }
    return { real: true, rationale: 'upheld' }
  }
  const parallel = async fns => Promise.all(fns.map(fn => fn()))
  const pipeline = async (items, mapper, reducer) => {
    const out = []
    for (const item of items) {
      const mapped = await mapper(item)
      if (mapped == null) continue
      out.push(await reducer(mapped, item))
    }
    return out
  }
  const value = await __workflow__(args, null, agent, parallel, null, pipeline)
  return { value, dispatches }
}

let pass = 0
let fail = 0
function check(name, condition) {
  if (condition) { pass += 1; console.log(`PASS: ${name}`) }
  else { fail += 1; console.log(`FAIL: ${name}`) }
}

let run = await execute(validArgs, { 'GE-001': validResult })
check('valid grounded result passes', run.value.allPass === true)
check('valid result preserves groundingPass', run.value.criteria[0].groundingPass === true)

run = await execute(validArgs, {})
check('missing verifier result fails closed', run.value.allPass === false)
check('missing verifier result remains represented', run.value.criteria.length === 1 && run.value.criteria[0].id === 'GE-001')

run = await execute(validArgs, { 'GE-001': { ...validResult, id: 'OTHER' } })
check('unexpected criterion id fails closed', run.value.allPass === false)

run = await execute(validArgs, { 'GE-001': { ...validResult, repositoryEvidence: ['implementation: fake:1 - invented'] } })
check('malformed grounding fails closed', run.value.allPass === false)

run = await execute({ ...validArgs, baseSha: '' }, { 'GE-001': validResult })
check('missing workflow diff context fails closed', run.value.allPass === false)
check('missing context dispatches no verifier', run.dispatches === 0)

console.log(`Results: ${pass} passed, ${fail} failed`)
if (fail) process.exit(1)
'''
wrapped = 'async function __workflow__(args, phase, agent, parallel, output, pipeline) {\n' + source + '\n}\n' + tests
open(sys.argv[2], 'w').write(wrapped)
PY

"$NODE" "$MODULE"
