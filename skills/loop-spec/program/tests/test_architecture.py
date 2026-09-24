"""D4 guard: the core reads a plug-in's product, never its state bucket, and reaches a
plug-in only through the registry (docs/loop-spec/architecture.md, "Core and plug-ins")."""
import ast
import unittest
from pathlib import Path

_PACKAGE = Path(__file__).resolve().parents[1] / "loop_spec"
# The plug-in modules (architecture.md); every other module in loop_spec is core.
PLUGINS = {"execute", "verify", "iterate", "debug", "revise", "route", "deliver", "sdk_runner"}
# The state buckets a phase plug-in owns, one per phase module.
BUCKETS = PLUGINS - {"sdk_runner"}


def _is_state(node: ast.AST) -> bool:
    # `state[...]` or `<anything>.state[...]`; a nested key such as
    # state["products"]["execute"] has a subscript as its receiver and is legal.
    return (isinstance(node, ast.Name) and node.id == "state") or (isinstance(node, ast.Attribute) and node.attr == "state")


def _bucket_keys(tree: ast.AST) -> list[tuple[int, str]]:
    found = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Subscript) and _is_state(node.value):
            key = node.slice
        elif (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
              and node.func.attr in ("get", "setdefault", "pop") and _is_state(node.func.value) and node.args):
            key = node.args[0]
        else:
            continue
        if isinstance(key, ast.Constant) and key.value in BUCKETS:
            found.append((node.lineno, key.value))
    return found


def _plugin_imports(tree: ast.AST) -> list[tuple[int, str]]:
    found = []
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module == "loop_spec":
            found += [(node.lineno, a.name) for a in node.names if a.name in PLUGINS]
        elif isinstance(node, ast.ImportFrom) and (node.module or "").startswith("loop_spec."):
            name = node.module.split(".")[1]
            if name in PLUGINS:
                found.append((node.lineno, name))
        elif isinstance(node, ast.Import):
            found += [(node.lineno, a.name.split(".")[1]) for a in node.names
                      if a.name.startswith("loop_spec.") and a.name.split(".")[1] in PLUGINS]
    return found


class MicrokernelBoundaryTests(unittest.TestCase):
    def test_core_imports_no_plugin_and_reads_no_plugin_bucket(self):
        for path in sorted(_PACKAGE.glob("*.py")):
            if path.stem in PLUGINS:
                continue
            tree = ast.parse(path.read_text(encoding="utf-8"))
            with self.subTest(module=path.stem):
                self.assertEqual(_plugin_imports(tree), [])
                self.assertEqual(_bucket_keys(tree), [])

    def test_a_plugin_touches_only_its_own_bucket(self):
        for name in sorted(PLUGINS):
            tree = ast.parse((_PACKAGE / f"{name}.py").read_text(encoding="utf-8"))
            with self.subTest(module=name):
                self.assertEqual([(line, key) for line, key in _bucket_keys(tree) if key != name], [])


if __name__ == "__main__":
    unittest.main()
