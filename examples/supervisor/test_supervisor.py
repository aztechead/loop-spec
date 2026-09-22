"""StepQueue through its interface. Each case is a launcher output order a live
run produced. Run with `python3 -m unittest examples/supervisor/test_supervisor.py`;
loop-spec's own suite does not run it. claude-agent-sdk is not needed."""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from supervisor import StepQueue  # noqa: E402


def next_lines(*paths, kind="step"):
    return "\n".join("LOOP_SPEC_NEXT " + json.dumps({"kind": kind, "path": p, "slug": "x"}) for p in paths)


class StepQueueTests(unittest.TestCase):
    def test_a_wave_is_taken_in_order(self):
        queue = StepQueue()
        queue.add("[EXECUTE] issued\n" + next_lines("a", "b"))
        self.assertEqual([queue.take()["path"], queue.take()["path"]], ["a", "b"])

    def test_a_reannounced_open_step_is_taken_once(self):
        # sdk1: submitting one step of a wave re-announced its still-open sibling,
        # which was then submitted twice and refused.
        queue = StepQueue()
        queue.add(next_lines("a", "b"))
        queue.take()
        queue.add(next_lines("b", "c"))
        self.assertEqual([queue.take()["path"], queue.take()["path"]], ["b", "c"])
        queue.add(next_lines("b", "c"))
        with self.assertRaises(RuntimeError):
            queue.take()

    def test_wait_output_leaves_held_steps_queued(self):
        queue = StepQueue()
        queue.add(next_lines("a", "b"))
        queue.take()
        queue.add('LOOP_SPEC_WAIT {"open": ["b"]}')
        self.assertEqual(queue.take()["path"], "b")

    def test_result_is_returned(self):
        queue = StepQueue()
        queue.add(next_lines("/r/result.json", kind="result"))
        self.assertEqual(queue.take()["kind"], "result")


if __name__ == "__main__":
    unittest.main()
