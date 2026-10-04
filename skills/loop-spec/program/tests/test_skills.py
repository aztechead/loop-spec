"""The plugin's skills and agents meet the Agent Skills format: frontmatter limits, a
third-person description, a body under 500 lines, and links that resolve. See
https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices."""
import re
import unittest
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[4]
SKILLS = sorted(PLUGIN.glob("skills/*/SKILL.md"))
AGENTS = sorted(PLUGIN.glob("agents/*.md"))


def parse(path: Path) -> tuple[dict, str]:
    """Frontmatter as one `key: value` line per field. The program has no YAML parser, so a
    folded or multi-line value is a failure here rather than a field read wrong."""
    _, front, body = path.read_text().split("---", 2)
    fields = {}
    for line in front.strip().splitlines():
        match = re.fullmatch(r"([a-z][a-z-]*): (\S.*)", line)
        if not match:
            raise AssertionError(f"{path}: frontmatter line is not `key: value` on one line: {line!r}")
        fields[match[1]] = match[2].strip('"')
    return fields, body


class SkillFormatTests(unittest.TestCase):
    def test_there_are_skills_and_agents(self):
        self.assertGreaterEqual(len(SKILLS), 6)
        self.assertGreaterEqual(len(AGENTS), 3)

    def test_names_and_descriptions_meet_the_frontmatter_rules(self):
        for path in SKILLS + AGENTS:
            with self.subTest(path=path.relative_to(PLUGIN)):
                fields, _ = parse(path)
                self.assertRegex(fields["name"], r"^[a-z0-9-]{1,64}$")
                self.assertNotRegex(fields["name"], r"anthropic|claude")
                self.assertTrue(0 < len(fields["description"]) <= 1024)
                self.assertNotRegex(fields["description"], r"<[A-Za-z/]")
                # Descriptions are injected into the system prompt: third person only.
                self.assertNotRegex(fields["description"], r"(?i)\b(you|your|I)\b")

    def test_a_skill_says_when_to_use_it_and_its_body_stays_short(self):
        for path in SKILLS:
            with self.subTest(path=path.relative_to(PLUGIN)):
                fields, body = parse(path)
                self.assertRegex(fields["description"], r"\bUse (when|whenever|to)\b")
                self.assertLess(body.count("\n"), 500)

    def test_a_name_matches_its_directory_or_file(self):
        for path in SKILLS:
            self.assertEqual(parse(path)[0]["name"], path.parent.name)
        for path in AGENTS:
            self.assertEqual(parse(path)[0]["name"], path.stem)

    def test_agents_carry_model_effort_and_tools(self):
        for path in AGENTS:
            with self.subTest(path=path.relative_to(PLUGIN)):
                fields, _ = parse(path)
                self.assertTrue(fields.get("model") and fields.get("effort") and fields.get("tools"))

    def test_relative_links_in_skills_resolve(self):
        for path in SKILLS:
            for target in re.findall(r"\]\(([^)#:]+)\)", path.read_text()):
                with self.subTest(path=path.relative_to(PLUGIN), link=target):
                    self.assertTrue((path.parent / target).is_file())


HUB = PLUGIN / "skills" / "loop-spec" / "SKILL.md"
REFERENCES = HUB.parent / "references"
VENDORED = REFERENCES / "visual-pr"  # copied from HumanLayer


def local_links(path: Path) -> set[Path]:
    return {(path.parent / t).resolve() for t in re.findall(r"\]\(([^)#:]+\.md)\)", path.read_text())}


class ProgressiveDisclosureTests(unittest.TestCase):
    """SKILL.md is the overview; every reference is one link away from it, never two."""

    def test_every_reference_is_linked_from_the_hub(self):
        linked = local_links(HUB)
        for path in REFERENCES.rglob("*.md"):
            if path.name == "README.md":
                continue  # provenance for contributors, not guidance for the lead
            with self.subTest(path=path.relative_to(PLUGIN)):
                self.assertIn(path.resolve(), linked)

    def test_no_reference_sends_the_reader_to_another_reference(self):
        for path in local_links(HUB):
            with self.subTest(path=path.relative_to(PLUGIN)):
                self.assertEqual(local_links(path), set())

    def test_long_references_open_with_their_contents(self):
        for path in REFERENCES.rglob("*.md"):
            if VENDORED in path.parents or path.read_text().count("\n") <= 100:
                continue
            with self.subTest(path=path.relative_to(PLUGIN)):
                self.assertIn("## Contents", path.read_text()[:600])

    def test_the_program_names_a_reference_that_exists_for_every_phase(self):
        from loop_spec import cli
        for guide in set(cli.PHASE_GUIDES.values()) | {"micro.md", "debug.md", "revise.md"}:
            with self.subTest(guide=guide):
                self.assertTrue((cli.REFERENCES / guide).is_file())


if __name__ == "__main__":
    unittest.main()
