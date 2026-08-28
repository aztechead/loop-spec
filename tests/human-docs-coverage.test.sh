#!/usr/bin/env bash
# Docs-for-humans coverage: the "the markdown is a deliverable too" directive MUST be
# present in every path that writes a document, mirroring tests/human-code-coverage.test.sh
# for code. The directive codifies: name the reader, one job per document, a procedure
# states its prerequisites and expected output, cite rather than copy, and a change that
# makes a document false fixes it in the same diff.
#
# A SessionStart hook does not reach a dispatched implementer, so a directive that lives
# only in the hook is absent exactly where the documents get written. This is the
# enforcement that keeps the wiring from silently regressing.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

# file<TAB>regex(any-case) that must match at least once.
checks=(
  "skills/shared/human-docs.md	maintain and operate"
  "skills/shared/human-docs.md	One document, one job"
  "skills/shared/human-docs.md	Cite, never copy"
  "skills/shared/human-docs.md	ships in the diff that changes the behavior"
  "agents/implementer.md	Docs for humans"
  "agents/planner.md	Docs for humans"
  "agents/spec-writer.md	Docs for humans"
  "agents/pattern-mapper.md	Docs for humans"
  "agents/verifier.md	Docs for humans"
  "agents/code-reviewer.md	Docs-for-humans pass"
  "skills/shared/team-prompts/implementer.md	Docs for humans"
  "skills/shared/execute-subagent.md	DOCS FOR HUMANS"
  "lib/plan-to-loop.sh	DOCS FOR HUMANS"
  "lib/workflows/execute-dag.js	DOCS FOR HUMANS"
  "hooks/team/human-code-inject.sh	DOCS FOR HUMANS"
  "skills/human-code/SKILL.md	human-docs.md"
  "skills/verify/SKILL.md	Docs-for-humans pass"
  "CLAUDE.md	Docs for humans"
)

for entry in "${checks[@]}"; do
  f="${entry%%	*}"
  rx="${entry##*	}"
  if [[ ! -f "$f" ]]; then
    echo "FAIL: $f missing"; FAIL=$((FAIL+1)); continue
  fi
  if grep -qiE "$rx" "$f"; then
    echo "PASS: $f carries docs-for-humans (/$rx/)"; PASS=$((PASS+1))
  else
    echo "FAIL: $f does NOT carry docs-for-humans (/$rx/) -- a document-producing path lost the directive"
    FAIL=$((FAIL+1))
  fi
done

# The EXECUTE subagent rung dispatches TWO implementer prompts (single-repo + workspace);
# both write documents, so both must carry the directive.
sub_count="$(grep -cE "DOCS FOR HUMANS" skills/shared/execute-subagent.md)"
marker_count="$(grep -cF "implementer contract stanza — insert the block above" skills/shared/execute-subagent.md)"
if [[ "$sub_count" -ge 1 && "$marker_count" -ge 2 ]]; then
  echo "PASS: execute-subagent.md covers both implementer prompts ($sub_count occurrences)"
  PASS=$((PASS+1))
else
  echo "FAIL: execute-subagent.md has $sub_count docs-for-humans occurrences; expected stanza >= 1 and both prompts inserting it (marker >= 2)"
  FAIL=$((FAIL+1))
fi

# Every dispatch copy must point at the probe, not just assert the principle: a prompt that
# says "write good docs" without naming the measurement is the prose criterion this change
# exists to replace.
for f in agents/implementer.md agents/code-reviewer.md \
         skills/shared/team-prompts/implementer.md skills/shared/execute-subagent.md \
         lib/plan-to-loop.sh lib/workflows/execute-dag.js hooks/team/human-code-inject.sh \
         skills/verify/SKILL.md; do
  if grep -q "doc-tells.sh" "$f"; then
    echo "PASS: $f names the probe"; PASS=$((PASS+1))
  else
    echo "FAIL: $f does not name doc-tells.sh"; FAIL=$((FAIL+1))
  fi
done

# The probe ships inside the plugin; a dispatched agent's cwd is the target repository, so
# no dispatch site may invoke it by a bare relative path -- each substitutes a real one.
for f in skills/shared/human-docs.md agents/implementer.md agents/code-reviewer.md \
         skills/shared/team-prompts/implementer.md skills/shared/execute-subagent.md \
         lib/plan-to-loop.sh lib/workflows/execute-dag.js hooks/team/human-code-inject.sh \
         skills/verify/SKILL.md; do
  if grep -qE 'bash (")?lib/doc-tells\.sh' "$f"; then
    echo "FAIL: $f invokes the probe by bare relative path -- unreachable outside this repo"
    FAIL=$((FAIL+1))
  else
    echo "PASS: $f has no bare-relative probe invocation"; PASS=$((PASS+1))
  fi
done

# Each site resolves the path by its own available mechanism.
resolvers=(
  "skills/shared/execute-subagent.md	CLAUDE_SKILL_DIR}/\.\./\.\./lib\"? doc-tells|CLAUDE_SKILL_DIR}/\.\./\.\./lib\"?/doc-tells"
  "skills/shared/team-prompts/implementer.md	CLAUDE_SKILL_DIR}/\.\./\.\./lib"
  "skills/verify/SKILL.md	CLAUDE_SKILL_DIR}/\.\./\.\./lib/doc-tells\.sh"
  "lib/plan-to-loop.sh	\{lib_dir\}/doc-tells\.sh"
  "lib/workflows/execute-dag.js	libDir \+ '/doc-tells\.sh"
  "hooks/team/human-code-inject.sh	\\\$\{LIB_DIR\}/doc-tells\.sh"
  "agents/implementer.md	\{probe_dir\}/doc-tells\.sh"
  "agents/code-reviewer.md	\{probe_dir\}/doc-tells\.sh"
)
for entry in "${resolvers[@]}"; do
  f="${entry%%	*}"
  rx="${entry##*	}"
  if grep -qE "$rx" "$f"; then
    echo "PASS: $f resolves the probe path (/$rx/)"; PASS=$((PASS+1))
  else
    echo "FAIL: $f lost its probe-path resolution (/$rx/)"; FAIL=$((FAIL+1))
  fi
done

# The rule with the teeth: a change that makes a document false fixes it in the same diff.
# Without it the directive is a style note, and documentation lands in the backlog forever.
for f in agents/implementer.md agents/planner.md skills/shared/execute-subagent.md \
         skills/shared/team-prompts/implementer.md lib/plan-to-loop.sh \
         lib/workflows/execute-dag.js hooks/team/human-code-inject.sh; do
  if grep -qiE "IN THIS DIFF|SAME diff|deferred scope" "$f"; then
    echo "PASS: $f requires the doc fix inside the change"; PASS=$((PASS+1))
  else
    echo "FAIL: $f omits the same-diff rule -- documentation becomes a follow-up that never lands"
    FAIL=$((FAIL+1))
  fi
done

# The carve-outs are load-bearing: without them the directive orders an agent to strip the
# frontmatter and required headings that artifact-lint.sh enforces.
for f in skills/shared/human-docs.md agents/implementer.md hooks/team/human-code-inject.sh \
         agents/code-reviewer.md; do
  if grep -qiE "frontmatter" "$f"; then
    echo "PASS: $f carries the machine-read carve-out"; PASS=$((PASS+1))
  else
    echo "FAIL: $f omits the frontmatter/contract carve-out"; FAIL=$((FAIL+1))
  fi
done

# The contract must keep saying which rules a script actually checks. A directive that
# claims enforcement it does not have is the prose criterion in a new costume.
if grep -q "Machine-checked?" skills/shared/human-docs.md &&
   grep -qF "**No.**" skills/shared/human-docs.md; then
  echo "PASS: human-docs.md separates the checked rules from the judgments"; PASS=$((PASS+1))
else
  echo "FAIL: human-docs.md lost the machine-checked/judgment split"; FAIL=$((FAIL+1))
fi

# The reviewer's severity fork: evidence blocks, taste does not -- the same split the
# code-for-humans pass makes.
if grep -qF 'stale-doc:' agents/code-reviewer.md &&
   grep -qE 'unusable-doc:` is \*\*Minor\*\*' agents/code-reviewer.md; then
  echo "PASS: code-reviewer.md blocks on evidenced doc findings and keeps taste Minor"
  PASS=$((PASS+1))
else
  echo "FAIL: code-reviewer.md lost the evidenced-blocks / taste-is-Minor split for docs"
  FAIL=$((FAIL+1))
fi

# The probe is the deterministic half; it must exist, run, and be wired into the suite.
for probe in lib/doc-tells.sh lib/doc-tells.py; do
  if [[ -f "$probe" ]]; then
    echo "PASS: $probe exists"; PASS=$((PASS+1))
  else
    echo "FAIL: $probe missing"; FAIL=$((FAIL+1))
  fi
done
if [[ -x lib/doc-tells.sh ]]; then
  echo "PASS: lib/doc-tells.sh is executable"; PASS=$((PASS+1))
else
  echo "FAIL: lib/doc-tells.sh is not executable"; FAIL=$((FAIL+1))
fi

if grep -qF "tests/lib/doc-tells.test.sh" tests/run-all.sh; then
  echo "PASS: tests/lib/doc-tells.test.sh registered in run-all.sh"; PASS=$((PASS+1))
else
  echo "FAIL: tests/lib/doc-tells.test.sh is not registered in tests/run-all.sh"; FAIL=$((FAIL+1))
fi

# Dispatch paths name the contract so they point at it instead of pasting it.
for f in skills/shared/execute-subagent.md lib/plan-to-loop.sh \
         lib/workflows/execute-dag.js hooks/team/human-code-inject.sh \
         agents/implementer.md skills/shared/team-prompts/implementer.md \
         CLAUDE.md; do
  if grep -q "skills/shared/human-docs.md" "$f"; then
    echo "PASS: $f names the human-docs contract"; PASS=$((PASS+1))
  else
    echo "FAIL: $f does not name skills/shared/human-docs.md -- the prompt will paste instead of point"
    FAIL=$((FAIL+1))
  fi
done
hd_count="$(grep -cF "skills/shared/human-docs.md" skills/shared/execute-subagent.md)"
if [[ "$hd_count" -ge 1 ]]; then
  echo "PASS: execute-subagent.md names the docs contract in the shared stanza ($hd_count occurrences)"
  PASS=$((PASS+1))
else
  echo "FAIL: execute-subagent.md has $hd_count human-docs.md references; expected >= 1 (shared stanza)"
  FAIL=$((FAIL+1))
fi

# The gate id is the loop's own: a project extension answering to it would be
# indistinguishable from the built-in pass in every log the cycle keeps.
if grep -qE 'PROTECTED_IDS=.*human-docs' lib/extension-points.sh; then
  echo "PASS: human-docs is a protected gate id"; PASS=$((PASS+1))
else
  echo "FAIL: human-docs is not in extension-points.sh PROTECTED_IDS"; FAIL=$((FAIL+1))
fi

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "PASS: docs-for-humans directive present in every document-producing path"
