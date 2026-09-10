#!/usr/bin/env bash
# Offline inventory grammar and revision regressions.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PYTHONPATH="$ROOT/lib" python3 - <<'TEST'
import json
import os
import subprocess
import tempfile
from pathlib import Path
from requirements import parse_spec, inventory_digest, load_inventory, initialize_contract
base = '\n'.join(['---', 'requirements_version: 1', 'requirements_owner: {"repository":"repo","feature":"feature"}', 'scenario_checks: {}', '---', '# Example', '### Good Enough', '- [ ] GE-001: Required outcome', '  - SC-001: Observed result', '    ```text', '    expected', '    ```', '- [ ] GE-002: Other outcome', '  - SC-001: Other result', '### Exceptional', '- [ ] optional'])
def inventory(text):
    return parse_spec(text, 'fixture.md', None)
def revisions(text):
    return {r['id']: r['revision'] for r in inventory(text)['requirements']}
original = revisions(base)
review_failures = []
for label, changed in [
    ('whitespace requirement', base.replace('Required outcome', '   ')),
    ('whitespace scenario', base.replace('Observed result', '   ')),
    ('malformed scenario_checks', base.replace('scenario_checks: {}', 'scenario_checks {"x":1,"x":2}')),
]:
    try:
        inventory(changed)
    except ValueError as exc:
        assert 'fixture.md:' in str(exc)
    else:
        review_failures.append(label + ' accepted')
try:
    continued = inventory(base.replace('Observed result', 'Observed result\n    requirements_version is unchanged.'))
    assert 'requirements_version is unchanged.' in continued['requirements'][0]['scenarios'][0]['text']
except ValueError as exc:
    review_failures.append('valid continuation rejected: ' + str(exc))
assert not review_failures, '; '.join(review_failures)

first, second = base.index('- [ ] GE-001'), base.index('- [ ] GE-002')
end = base.index('### Exceptional')
assert revisions(base[:first] + base[second:end] + base[first:second] + base[end:]) == original
scenarios = base.replace('  - SC-001: Other result', '  - SC-001: Other result\n  - SC-002: Additional result')
assert revisions(scenarios) == revisions(scenarios.replace('  - SC-001: Other result\n  - SC-002: Additional result', '  - SC-002: Additional result\n  - SC-001: Other result'))
decoy = base.replace('    expected', '    ### Good Enough\n    - [ ] GE-999: decoy\n      - SC-999: decoy')
assert len(inventory(decoy)['requirements']) == 2
assert len(inventory(decoy)['requirements'][0]['scenarios']) == 1
assert len(inventory(base.replace('```text', '~~~~text').replace('    ```', '    ~~~~~'))['requirements']) == 2
assert revisions(base.replace('```text', '```bash')) != original
assert revisions(base.replace('Required outcome', 'Required  outcome')) != original
assert revisions(base.replace('Required outcome', 'Required\n\n  outcome')) != original
assert inventory(base.replace('requirements_version: 1\n', '').replace('requirements_owner: {"repository":"repo","feature":"feature"}\n', ''))['version'] == 0

for changed in [base.replace('[ ]','[x]'), base.replace('\n','\r\n'), base.replace('Required outcome','Required\n  outcome'), base.replace('scenario_checks: {}','scenario_checks: {"command":"different"}')]:
    assert revisions(changed) == original
for changed in [base.replace('Observed result','Changed result'), base.replace('    expected','    changed')]:
    assert revisions(changed)['GE-001'] != original['GE-001']
for changed in [base.replace('GE-002','GE-001'), base.replace('- [ ] GE-002: Other outcome', '#### Hidden subsection\n- [ ] GE-002: Other outcome'), base.replace('GE-001','GE-01'), base.replace('SC-001: Observed result','SC-000: Observed result'), base.replace('  - SC-001: Other result',''), base.replace('requirements_version: 1','requirements_version: 2'), base.replace('requirements_version: 1','requirements_version: true'), base.replace('requirements_version: 1','requirements_version: 01'), base.replace('requirements_version: 1','requirements_version: 1\nrequirements_version: 1'), base.replace('scenario_checks: {}', 'scenario_checks: {"x":1,"x":2}'), base.replace('"repository":"repo"','"repository":"repo","repository":"other"'), base + '\n### Good Enough\n', base.replace('    ```text','    ~~~text'), base.replace('Other result',''), base.replace('  - SC-001: Other result',' - SC-001: Other result')]:
    try:
        inventory(changed)
    except ValueError as exc:
        assert 'fixture.md:' in str(exc), str(exc)
    else:
        raise AssertionError('accepted malformed fixture: ' + changed)
try:
    parse_spec(base.replace('requirements_version: 1\n',''), 'fixture.md', {'version':1,'format':'v1','owner':{'repository':'repo','feature':'feature'}})
except ValueError:
    pass
else:
    raise AssertionError('metadata removal downgraded v1')
assert inventory_digest(inventory(base)) == inventory_digest(inventory(base.replace('[ ]', '[x]')))
with tempfile.TemporaryDirectory() as directory:
    spec = Path(directory) / 'SPEC.md'
    state = Path(directory) / 'feature.json'
    contract = initialize_contract({'repository': 'repo', 'feature': 'feature'}, 'v1')
    state.write_text(json.dumps({'requirementsContract': contract}))
    spec.write_text(base)
    command = ['bash', str(Path(os.environ['PYTHONPATH']) / 'requirements.sh'), 'inventory', '--spec', str(spec), '--feature-dir', directory]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)['requirements'][0]['id'] == 'GE-001'
    spec.write_text(base.replace('GE-001', 'GE-000'))
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert result.returncode == 1 and str(spec) + ':8:' in result.stderr, result.stderr
    spec.write_text(base.replace('requirements_version: 1\n', ''))
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert result.returncode == 1 and 'missing requirements_version' in result.stderr
    spec.write_bytes(b'x' * (16 * 1024 * 1024 + 1))
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert result.returncode == 1 and '16 MiB' in result.stderr
print('PASS: inventory grammar, revisions, CLI diagnostics and size bound')
TEST
PYTHONPATH="$ROOT/lib" python3 - <<'PY'
from requirements import initialize_contract, reconcile_inventory, validate_state, validate_transition
owner = {'repository': 'repo', 'feature': 'feature'}
c = initialize_contract(owner, 'v1')
i = {'version': 1, 'owner': owner, 'requirements': [{'id': 'GE-001', 'revision': 'a'*64, 'scenarios': [{'id': 'SC-001'}]}], 'obligations': []}
c = reconcile_inventory(c, i)
assert c['nextRequirementId'] == 2
assert c['issued']['GE-001']['nextScenarioId'] == 2
empty = dict(i, requirements=[])
retired = reconcile_inventory(c, empty)
assert retired['retired'] == ['GE-001']
try:
    reconcile_inventory(retired, i)
except ValueError:
    pass
else:
    raise AssertionError('retired requirement reused')
validate_state({'requirementsContract': retired})
two = dict(i, requirements=[dict(i['requirements'][0], scenarios=[{'id':'SC-001'}, {'id':'SC-002'}])])
expanded = reconcile_inventory(c, two)
removed = reconcile_inventory(expanded, i)
try:
    reconcile_inventory(removed, two)
except ValueError:
    pass
else:
    raise AssertionError('retired scenario reused')
for old, candidate in [({'requirementsContract':retired}, {'requirementsContract':c}),
                       ({'artifactPublication':{'version':1,'generation':2,'evidenceEpoch':1,'migration':None,'participantsVersion':1}},
                        {'artifactPublication':{'version':1,'generation':1,'evidenceEpoch':1,'migration':None,'participantsVersion':1}})]:
    try:
        validate_transition(old, candidate)
    except ValueError:
        pass
    else:
        raise AssertionError('accepted history rollback')
assert expanded['retiredScenarios']['GE-001'] == []
assert removed['retiredScenarios']['GE-001'] == ['SC-002']
import copy
publication = {'version':1,'generation':0,'evidenceEpoch':0,'migration':None,'participantsVersion':1}
for field, value in [('version',True), ('generation',True), ('evidenceEpoch',-1), ('participantsVersion',2), ('migration',{}), ('unknown',None)]:
    bad = dict(publication, **{field:value})
    try:
        validate_state({'artifactPublication':bad})
    except ValueError:
        pass
    else:
        raise AssertionError('invalid publication accepted: '+field)
for mutate in [lambda x: x['issued']['GE-001'].update(nextScenarioId=True),
               lambda x: x.update(retired=['GE-999']),
               lambda x: x['issued']['GE-001'].update(revision='A'*64),
               lambda x: x.update(retiredScenarios={'GE-001':['SC-999']}),
               lambda x: x['owner'].update(unknown='x')]:
    bad = copy.deepcopy(c)
    mutate(bad)
    try:
        validate_state({'requirementsContract':bad})
    except ValueError:
        pass
    else:
        raise AssertionError('malformed nested ledger accepted')
print('PASS: identity reconciliation retains retired histories')
PY
