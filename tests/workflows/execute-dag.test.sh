#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
command -v node >/dev/null 2>&1 || { echo "SKIP: node unavailable"; exit 0; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
{
  echo 'async function __workflow__(args, phase, agent, parallel, output) {'
  sed 's/^export //' "$ROOT/lib/workflows/execute-dag.js"
  echo '}'
} > "$TMP/workflow.js"
cat >> "$TMP/workflow.js" <<'JS'

const tasks = [
  { id: 'task-001', subject: 'one', files: [], blockedBy: [], verifyCommand: 'true' },
  { id: 'task-002', subject: 'two', files: [], blockedBy: [], verifyCommand: 'true' },
]
let active = 0
let peak = 0
const agent = async (prompt, options) => {
  if (options.label === 'merge-agent') {
    const merged = [...prompt.matchAll(/### Task \d+ of \d+: (task-\d+)/g)].map(m => m[1])
    return { merged, zeroCommit: [], conflict: null, integrationFailure: null }
  }
  active += 1
  peak = Math.max(peak, active)
  await new Promise(resolve => setTimeout(resolve, 5))
  active -= 1
  return { taskId: prompt.match(/task (task-\d+)/)?.[1] || 'task-001', committed: true, verdict: 'pass' }
}
const parallel = async fns => Promise.all(fns.map(fn => fn()))
async function run(args) {
  return await __workflow__(args, null, agent, parallel, null)
}
const base = {
  slug: 'resource-test', featureWorktreeRoot: '/tmp', featureBranch: 'feat/test',
  models: { implementer: 'inherit', specComplianceReviewer: 'inherit' },
  maxRetriesPerTask: 1, reviewersEnabled: false, commands: {}, skillDir: '/tmp',
  tasks, taskWorktreeBase: '/tmp', doneTaskIds: [],
}
const two = await run({ ...base, maxParallelImplementers: 2 })
if (peak !== 2 || two.merged.length !== 2) throw new Error(`explicit cap failed: peak=${peak}`)
peak = 0
const one = await run({ ...base })
if (peak !== 1 || one.merged.length !== 2) throw new Error(`default fallback failed: peak=${peak}`)
let invalid = false
try { await run({ ...base, maxParallelImplementers: 0 }) } catch { invalid = true }
if (!invalid) throw new Error('invalid cap was accepted')
console.log('workflow wave cap passed')
JS
cat > "$TMP/runner.mjs" <<'JS'
import fs from 'node:fs'
const source = fs.readFileSync(process.argv[2], 'utf8')
const fn = new Function('return (async () => {' + source + '\n})()')
await fn()
JS
node "$TMP/runner.mjs" "$TMP/workflow.js"
