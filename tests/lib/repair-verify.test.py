import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'lib'))
import repair_verify


class RepairCommand(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / 'dispatch').mkdir()
        self.task = {'id': 'repair', 'remediationReceipt': 'receipt', 'verifyCommand': 'python3 old_check.py',
                     'acceptanceCriteria': ['declared fields remain typed'], 'files': ['manifest.py'], 'retries': 2}
        self.paths = [self.root / 'tasks.json', self.root / 'dispatch/tasks-collapsed.json', self.root / 'dispatch/prepare.json']
        self.write_task()
        self.state = self.root / 'dispatch/repair.json'
        self.state.write_text(json.dumps({'attempt': 2, 'package': 'old-review.md'}))
        self.request = {'expectedCommand': self.task['verifyCommand'], 'verifyCommand': 'python3 contract_check.py',
                        'reason': 'old check rejects an equivalent representation',
                        'evidence': 'contract permits indirect values; corrected check resolves them before checking types'}

    def write_task(self):
        for index, path in enumerate(self.paths):
            path.write_text(json.dumps({'tasks': [self.task]} if index == 2 else [self.task]))

    def test_updates_copies_preserves_contract_and_requires_review(self):
        self.assertTrue(repair_verify.repair(self.root, 'repair', self.request)['reviewRequired'])
        for index, path in enumerate(self.paths):
            doc = json.loads(path.read_text())
            task = doc['tasks'][0] if index == 2 else doc[0]
            self.assertEqual(task['verifyCommand'], self.request['verifyCommand'])
            for key in ('acceptanceCriteria', 'files', 'retries'):
                self.assertEqual(task[key], self.task[key])
        state = json.loads(self.state.read_text())
        self.assertEqual(state['attempt'], 2)
        self.assertTrue(state['verificationRepairPending'])
        self.assertNotIn('package', state)
        self.assertTrue(repair_verify.repair(self.root, 'repair', self.request)['replayed'])

    def test_refusals_preserve_every_file(self):
        for update in [{'status': 'done'}, {'remediationReceipt': None}, {'userGate': True}, {'memberIds': ['repair', 'other']}]:
            saved = dict(self.task)
            self.task.update(update)
            self.write_task()
            before = [p.read_bytes() for p in self.paths + [self.state]]
            with self.assertRaises(ValueError):
                repair_verify.repair(self.root, 'repair', self.request)
            self.assertEqual(before, [p.read_bytes() for p in self.paths + [self.state]])
            self.task = saved

    def test_stale_diagnosis_and_second_repair_refused(self):
        with self.assertRaisesRegex(ValueError, 'changed since'):
            repair_verify.repair(self.root, 'repair', dict(self.request, expectedCommand='stale'))
        repair_verify.repair(self.root, 'repair', self.request)
        with self.assertRaisesRegex(ValueError, 'already repaired'):
            repair_verify.repair(self.root, 'repair', dict(self.request, expectedCommand='python3 contract_check.py', verifyCommand='true'))

    def test_interrupted_publication_replays_without_spending_attempts(self):
        publish = repair_verify.publish
        def fail_cache(path, content):
            if path == self.paths[1]:
                raise OSError('interrupted cache publication')
            publish(path, content)
        with patch.object(repair_verify, 'publish', side_effect=fail_cache), self.assertRaises(OSError):
            repair_verify.repair(self.root, 'repair', self.request)
        repair_verify.repair(self.root, 'repair', self.request)
        self.assertEqual(json.loads(self.state.read_text())['attempt'], 2)
        self.assertEqual(json.loads(self.paths[2].read_text())['tasks'][0]['verifyCommand'], self.request['verifyCommand'])


if __name__ == '__main__':
    unittest.main()
