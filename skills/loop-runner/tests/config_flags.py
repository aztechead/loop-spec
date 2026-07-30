#!/usr/bin/env python3
"""Fast parser-level coverage for every public loop.py flag."""
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from loop import build_config  # noqa: E402


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        prompt = root / "prompt.md"
        prompt.write_text("prompt from file")
        cfg_file = root / "config.json"
        cfg_file.write_text(json.dumps({"task": "config task", "max_iterations": 4}))

        cfg = build_config([
            "positional task",
            "--task-id", "task-id",
            "--verify", "make test",
            "--protected", "a",
            "--protected", "b",
            "--max-iterations", "7",
            "--max-turns", "8",
            "--timeout", "90",
            "--no-progress", "2",
            "--verify-timeout", "45",
            "--mode", "continue",
            "--permission-mode", "acceptEdits",
            "--max-budget-usd", "1.25",
            "--allowed-tools", "Read,Bash",
            "--model", "sonnet",
            "--effort", "high",
            "--fallback-model", "haiku",
            "--retry-watchdog", "5",
            "--judge",
            "--judge-model", "opus",
            "--state-dir", ".state",
            "--commit",
            "--claude-bin", "custom-agent",
            "--agent-cli", "claude",
            "--reset",
            "--", "--custom-agent-flag", "value",
        ])
        expected = {
            "task": "positional task",
            "task_id": "task-id",
            "verify": "make test",
            "protected": ["a", "b"],
            "max_iterations": 7,
            "max_turns": 8,
            "timeout_s": 90,
            "no_progress": 2,
            "verify_timeout_s": 45,
            "mode": "continue",
            "permission_mode": "acceptEdits",
            "max_budget_usd": 1.25,
            "allowed_tools": "Read,Bash",
            "model": "sonnet",
            "effort": "high",
            "fallback_model": "haiku",
            "retry_watchdog": "5",
            "judge": True,
            "judge_model": "opus",
            "state_dir": ".state",
            "commit": True,
            "claude_bin": "custom-agent",
            "agent_cli": "claude",
            "reset": True,
            "extra_args": ["--custom-agent-flag", "value"],
        }
        for field, value in expected.items():
            assert getattr(cfg, field) == value, (field, getattr(cfg, field), value)

        from_prompt = build_config(["--prompt-file", str(prompt)])
        assert from_prompt.task == "prompt from file"

        from_config = build_config(["--config", str(cfg_file), "--max-iterations", "9"])
        assert from_config.task == "config task"
        assert from_config.max_iterations == 9

    print("PASS: every loop.py flag maps to its runtime configuration field")
    print("PASS: prompt-file and config precedence")
    print("PASS: explicit agent pass-through arguments")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
