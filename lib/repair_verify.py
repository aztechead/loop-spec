"""Repair a generated remediation check without changing its acceptance criteria."""
import json
from pathlib import Path
import sys

from feature_write import publish
from verify_command import validate


def repair(feature_dir, task_id, request):
    root = Path(feature_dir)
    for key in ('expectedCommand', 'verifyCommand', 'reason', 'evidence'):
        if not isinstance(request.get(key), str) or not request[key].strip():
            raise ValueError('command repair requires a non-empty ' + key)
    validate(request['verifyCommand'])
    if request['verifyCommand'] == request['expectedCommand']:
        raise ValueError('command repair must change the faulty command')
    paths = [root / 'tasks.json', root / 'dispatch/tasks-collapsed.json', root / 'dispatch/prepare.json']
    documents = [json.loads(path.read_text()) for path in paths]
    rows = []
    for document in documents:
        tasks = document.get('tasks') if isinstance(document, dict) else document
        matches = [task for task in tasks if task.get('id') == task_id]
        if len(matches) != 1:
            raise ValueError('task must occur exactly once in every prepared task list')
        rows.append(matches[0])
    original = rows[0]
    if not original.get('remediationReceipt'):
        raise ValueError('only generated remediation commands can be repaired here; revise PLAN for authored plan tasks')
    if original.get('userGate') or (original.get('metadata') or {}).get('userGate'):
        raise ValueError('a user gate cannot be replaced by remediation command repair')
    if original.get('status') in ('done', 'merged', 'completed'):
        raise ValueError('an integrated task cannot have its verification replaced')
    record = {key: request[key] for key in ('expectedCommand', 'verifyCommand', 'reason', 'evidence')}
    history = original.get('verifyCommandRepairs', [])
    if history and history != [record]:
        raise ValueError('command already repaired; return the remaining contract problem to VERIFY')
    # Validate every copy first. A replay after interruption can finish publishing
    # the same repair, but cannot silently replace a concurrent task edit.
    for task in rows:
        if task.get('memberIds', [task_id]) != [task_id]:
            raise ValueError('repair requires an unbatched remediation task')
        current = task.get('verifyCommand')
        if current != request['expectedCommand'] and not (
                current == request['verifyCommand'] and task.get('verifyCommandRepairs') == [record]):
            raise ValueError('command changed since diagnosis; read the current task before repair')
    if all(task.get('verifyCommandRepairs') == [record] for task in rows):
        return {'task': task_id, 'verifyCommand': request['verifyCommand'], 'updated': [], 'replayed': True}
    state_path = root / 'dispatch' / (task_id + '.json')
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    state['verificationRepairPending'] = True
    state.pop('package', None)
    publish(state_path, (json.dumps(state) + '\n').encode())
    for path, document, task in zip(paths, documents, rows):
        task['verifyCommand'] = request['verifyCommand']
        task['verifyCommandRepairs'] = [record]
        publish(path, (json.dumps(document, indent=2) + '\n').encode())
    return {'task': task_id, 'verifyCommand': request['verifyCommand'],
            'updated': [str(path) for path in paths], 'reviewRequired': True}


if __name__ == '__main__':
    try:
        print(json.dumps(repair(sys.argv[1], sys.argv[2], json.loads(Path(sys.argv[3]).read_text()))))
    except (ValueError, OSError, KeyError, TypeError) as exc:
        print(json.dumps({'error': str(exc)}))
        sys.exit(1)
