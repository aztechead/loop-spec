import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'lib'))
from verify_command import validate
from execute_remediation import normalize_queue


class CommandIntegrity(unittest.TestCase):
    def test_literal_programs_and_dynamic_arguments(self):
        for command in [
            "python3 -c 'print(\"$field\")'",
            r'''python3 -c "print('\$field')"''',
            "node -e 'console.log(`hello ${name}`)'",
            '''python3 -c 'import sys; print(sys.argv[1])' "$VALUE"''',
            '''test "$MODE" = test && python3 check.py''',
            "python3 - <<'PY'\nprint('python -c \"$value\"')\nPY\n",
            'python3 check.py\nnode -e "console.log(3)"',
            'python3 -c "print(1)" # node -e "$value"',
        ]:
            with self.subTest(command=command):
                validate(command)

    def test_shell_expansion_cannot_change_program(self):
        for command in [
            '''python3 -c "print('$field')"''',
            '''/env/bin/python3.14 -c "print('${key}')"''',
            '''uv run python -c 'print('"$value"')' ''',
            '''node --eval="console.log('${value}')"''',
            '''ruby -e"puts '$value'"''',
            '''perl -e "print `whoami`"''',
        ]:
            with self.subTest(command=command), self.assertRaisesRegex(ValueError, 'shell-expands'):
                validate(command)

    def test_never_executes_substitutions(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / 'executed'
            with self.assertRaises(ValueError):
                validate('python3 -c "print(\'$(touch ' + str(marker) + ')\')"')
            self.assertFalse(marker.exists())

    def test_malformed_command_rejected_at_intake(self):
        for command in ['python3 -c "', '''python3 -c "print('$key')"''']:
            queue = [{'id': 'repair', 'subject': 'Repair the contract', 'verifyCommand': command}]
            with self.assertRaises(ValueError):
                normalize_queue(queue, 'true')
            self.assertEqual(queue[0]['verifyCommand'], command)
            self.assertNotIn('retries', queue[0])


if __name__ == '__main__':
    unittest.main()
