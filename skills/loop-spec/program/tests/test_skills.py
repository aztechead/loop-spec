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
    _, front, body = path.read_text().split("---", 2)
    fields = {}
    for line in front.strip().splitlines():
        key, _, value = line.partition(":")
        fields[key.strip()] = value.strip().strip('"')
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


if __name__ == "__main__":
    unittest.main()
