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
for (const permanent of [false, true]) {
  let implementations = 0
  let integrations = 0
  let repairPrompt = ''
  const retryAgent = async (prompt, options) => {
    if (options.label === 'merge-agent') {
      integrations++
      return integrations === 1 || permanent
        ? {merged: [], integrationFailure: {taskId: 'task-001', reason: 'verify-failed', detail: 'assertion mismatch'}}
        : {merged: ['task-001']}
    }
    implementations++
    if (implementations === 2) repairPrompt = prompt
    return {taskId: 'task-001', committed: true, verdict: 'pass'}
  }
  const result = await __workflow__({...base, tasks: [tasks[0]], maxRetriesPerTask: 3}, null, retryAgent, parallel, null)
  if (!repairPrompt.includes('assertion mismatch')) throw new Error('integration evidence lost on retry')
  if (permanent) {
    if (implementations !== 3 || result.blocked[0]?.reason !== 'retry-exhausted') throw new Error('integration retry budget not enforced')
  } else if (implementations !== 2 || result.merged[0] !== 'task-001') throw new Error('fixable integration failure did not recover')
}
console.log('workflow integration recovery passed')
const counts = {}
let merges = 0
const siblingAgent = async (prompt, options) => {
  if (options.label === 'merge-agent') {
    merges++
    return merges === 1
      ? {merged: [], integrationFailure: {taskId: 'task-001', reason: 'verify-failed', detail: 'repair first candidate'}}
      : {merged: ['task-001', 'task-002']}
  }
  const id = prompt.match(/task (task-\d+)/)[1]
  counts[id] = (counts[id] || 0) + 1
  return {taskId: id, committed: true, verdict: 'pass'}
}
const siblings = await __workflow__({...base, maxParallelImplementers: 2, maxRetriesPerTask: 2}, null, siblingAgent, parallel, null)
if (counts['task-001'] !== 2 || counts['task-002'] !== 1 || siblings.merged.length !== 2) throw new Error('integration retry discarded an approved sibling')
console.log('workflow preserves approved siblings during recovery')
JS
cat > "$TMP/runner.mjs" <<'JS'
import fs from 'node:fs'
const source = fs.readFileSync(process.argv[2], 'utf8')
const fn = new Function('return (async () => {' + source + '\n})()')
await fn()
JS
node "$TMP/runner.mjs" "$TMP/workflow.js"
