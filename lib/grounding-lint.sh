#!/usr/bin/env bash
# grounding-lint.sh - Validate the ## Grounding section of design-phase artifacts.
#
# Why: the grounding protocol requires every load-bearing external-system fact to be
# backed by an EVIDENCE.md entry (EVID-NNN) or an explicit ASSUMPTION with a verify
# probe. Prose guidance in agent definitions demonstrably failed to enforce this (the
# BigQuery split-by-UTC-day incident). This script is the deterministic structural
# gate -- the same pattern as acceptance-lint and decision-coverage -- that catches
# missing/malformed grounding before DISCUSS commits or PLAN's gate cluster passes.
#
# Usage: grounding-lint.sh <artifact_path> [ledger_path]
#
# Default ledger_path: EVIDENCE.md in the artifact's directory.
# Missing ledger is only an error when an EVID-NNN token needs resolving.
#
# Exit codes: 0 all clear (prints 'grounding-lint: ok'), 1 any FLAG or bad invocation.
set -uo pipefail

artifact="${1:-}"
if [[ -z "$artifact" ]]; then
  echo "usage: grounding-lint.sh <artifact_path> [ledger_path]" >&2
  exit 1
fi
if [[ ! -f "$artifact" ]]; then
  echo "grounding-lint: artifact not found: $artifact" >&2
  exit 1
fi

artifact_dir="$(dirname "$artifact")"
ledger="${2:-$artifact_dir/EVIDENCE.md}"

# Read the artifact into an indexed array (0-based; line N in file = lines[N-1]).
# Using while-loop instead of mapfile for bash 3.x compatibility.
lines=()
while IFS= read -r line || [[ -n "$line" ]]; do
  lines+=("$line")
done < "$artifact"
total="${#lines[@]}"

flags=0

# ── Step 1: locate ## Grounding section ─────────────────────────────────────
grounding_start=-1
for ((i=0; i<total; i++)); do
  if [[ "${lines[$i]}" =~ ^##[[:space:]]Grounding([[:space:]]|$) ]]; then
    grounding_start=$i
    break
  fi
done

if [[ $grounding_start -lt 0 ]]; then
  echo "FLAG $artifact:0: missing ## Grounding section"
  echo "grounding-lint: add a '## Grounding' section to $artifact. List each external-system" \
       "fact as '- EVID-NNN: text' (cite a ledger entry via lib/evidence.sh add) or" \
       "'- ASSUMPTION: <claim> | verify: <command>', or '- none' if nothing external is" \
       "load-bearing." >&2
  exit 1
fi

# ── Step 2: find section end (next ^## heading or EOF) ──────────────────────
grounding_end=$total
for ((i=grounding_start+1; i<total; i++)); do
  if [[ "${lines[$i]}" =~ ^##[[:space:]] ]]; then
    grounding_end=$i
    break
  fi
done

# ── Step 3: strip complete <!-- ... --> comment blocks; collect visible lines ─
# Multi-line: everything from a line containing <!-- through the line with -->,
# inclusive. Single-line <!-- ... --> on one line: that entire line is removed.
in_comment=0
vis_lnos=()   # original 1-indexed line numbers of visible (non-comment) lines
vis_texts=()  # corresponding line contents

for ((i=grounding_start+1; i<grounding_end; i++)); do
  line="${lines[$i]}"
  lineno=$((i+1))

  if [[ $in_comment -eq 1 ]]; then
    if [[ "$line" == *"-->"* ]]; then
      in_comment=0
    fi
    continue
  fi

  if [[ "$line" == *"<!--"* ]]; then
    if [[ "$line" == *"-->"* ]]; then
      # Entire comment on one line — skip it.
      continue
    else
      in_comment=1
      continue
    fi
  fi

  vis_lnos+=("$lineno")
  vis_texts+=("$line")
done

# ── Step 3b: reflow — join indented continuation lines onto their bullet ────
# Model-authored markdown legitimately wraps a long bullet across lines with
# indented continuations. Grammar checks run on the JOINED logical bullet;
# FLAG line numbers point at the bullet's first physical line.
mrg_lnos=()
mrg_texts=()
for ((j=0; j<${#vis_lnos[@]}; j++)); do
  line="${vis_texts[$j]}"
  n="${#mrg_texts[@]}"
  if [[ $n -gt 0 && "${mrg_texts[$((n-1))]}" =~ ^-[[:space:]] \
        && "$line" =~ ^[[:space:]]+[^[:space:]] ]]; then
    trimmed="${line#"${line%%[![:space:]]*}"}"
    mrg_texts[$((n-1))]="${mrg_texts[$((n-1))]} $trimmed"
    continue
  fi
  mrg_lnos+=("${vis_lnos[$j]}")
  mrg_texts+=("$line")
done

# ── Step 4: validate visible lines ──────────────────────────────────────────
has_none=0
none_lineno=0
has_evidence=0  # set when any EVID-NNN or ASSUMPTION bullet is found

# Optional parenthetical qualifier after the keyword — writers carry tags like
# 'ASSUMPTION (SPEC):' over from the DISCUSS transcript convention; accept them.
evid_re='^- EVID-[0-9][0-9][0-9]( ?\([^)]*\))?: .+'
assumption_re='^- ASSUMPTION( ?\([^)]*\))?: (.+)$'
graph_tagged_re='^- GRAPH\[([A-Z_]+)\]( ?\([^)]*\))?: (.+)$'
graph_bare_re='^- GRAPH( ?\([^)]*\))?: '

nvis="${#mrg_lnos[@]}"
for ((j=0; j<nvis; j++)); do
  lineno="${mrg_lnos[$j]}"
  line="${mrg_texts[$j]}"

  # 4a. Whole-word UNVERIFIED anywhere in visible section lines.
  if echo "$line" | grep -qw 'UNVERIFIED'; then
    echo "FLAG $artifact:$lineno: whole-word UNVERIFIED found inside ## Grounding section (replace with ASSUMPTION: ... | verify: ... or NEEDS_CONTEXT)"
    flags=$((flags+1))
  fi

  # Only validate lines that are grounding bullets (start with "- ").
  [[ "$line" =~ ^-[[:space:]] ]] || continue

  # 4b. Bullet grammar checks.

  # Pattern 1: - none  (prefix match; optional trailing explanation)
  if [[ "$line" == "- none"* ]]; then
    has_none=1
    none_lineno="$lineno"
    continue
  fi

  # Pattern 2: - EVID-NNN: non-empty text (optional qualifier: - EVID-NNN (X): ...)
  if [[ "$line" =~ $evid_re ]]; then
    has_evidence=1
    continue
  fi

  # Pattern 3: - ASSUMPTION: <text> | verify: <command>
  # (optional qualifier: - ASSUMPTION (X): ...)
  # Split on the LAST occurrence of " | verify: " so a literal | in the
  # verify command or claim is safe.
  if [[ "$line" =~ $assumption_re ]]; then
    rest="${BASH_REMATCH[2]}"
    claim_part="${rest% | verify: *}"
    if [[ "$claim_part" == "$rest" ]]; then
      # No " | verify: " found at all.
      echo "FLAG $artifact:$lineno: malformed ASSUMPTION bullet — missing '| verify: <command>' (split on last ' | verify: ')"
      flags=$((flags+1))
    else
      cmd_part="${rest##* | verify: }"
      if [[ -z "$cmd_part" ]]; then
        echo "FLAG $artifact:$lineno: malformed ASSUMPTION bullet — verify command is empty"
        flags=$((flags+1))
      elif ! bash -n -c "$cmd_part" 2>/dev/null; then
        echo "FLAG $artifact:$lineno: ASSUMPTION verify command fails bash -n syntax check: $cmd_part"
        flags=$((flags+1))
      fi
    fi
    has_evidence=1
    continue
  fi

  # Pattern 4: - GRAPH[<TAG>]: <claim> | query: <command>
  # The code graph labels every edge with its own confidence -- graphify emits
  # EXTRACTED (parsed from an AST), INFERRED (the tool guessed), or AMBIGUOUS.
  # A citation must carry that label, because only EXTRACTED is a fact. Accepting
  # an unlabelled graph citation is how a guess enters an artifact wearing the
  # authority of a probe, which is the exact failure this whole gate exists to
  # prevent.
  if [[ "$line" =~ $graph_tagged_re ]]; then
    tag="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[3]}"
    case "$tag" in
      EXTRACTED)
        if [[ "$rest" != *" | query: "* || -z "${rest##* | query: }" ]]; then
          echo "FLAG $artifact:$lineno: malformed GRAPH bullet — missing '| query: <command>' naming the graph call that produced it"
          flags=$((flags+1))
        fi
        ;;
      INFERRED|AMBIGUOUS)
        # The graph told you it was not sure. Confirm it against the tree, or
        # demote it to an ASSUMPTION with a verify command like any other
        # unverified claim.
        if [[ ! "$rest" =~ \|[[:space:]]confirmed:[[:space:]]*[^[:space:]]+:[0-9]+ ]]; then
          echo "FLAG $artifact:$lineno: GRAPH[$tag] citation is not self-sufficient — the graph labelled this edge unverified; add '| confirmed: <file>:<line>' or rewrite as '- ASSUMPTION: <claim> | verify: <cmd>'"
          flags=$((flags+1))
        fi
        ;;
      *)
        echo "FLAG $artifact:$lineno: unknown graph confidence tag '$tag' — expected EXTRACTED, INFERRED, or AMBIGUOUS"
        flags=$((flags+1))
        ;;
    esac
    has_evidence=1
    continue
  fi

  # A graph citation with no confidence tag at all: the writer read the graph but
  # dropped the one field that says whether to believe it. Fail closed.
  if [[ "$line" =~ $graph_bare_re ]]; then
    echo "FLAG $artifact:$lineno: GRAPH citation carries no confidence tag — write '- GRAPH[EXTRACTED|INFERRED|AMBIGUOUS]: <claim> | query: <command>'"
    flags=$((flags+1))
    has_evidence=1
    continue
  fi

  # None of the valid patterns matched.
  echo "FLAG $artifact:$lineno: malformed grounding bullet — expected one of: '- none', '- EVID-NNN: text', '- ASSUMPTION: <claim> | verify: <cmd>', '- GRAPH[<TAG>]: <claim> | query: <cmd>'"
  flags=$((flags+1))
done

# ── Step 5: - none + evidence contradiction ──────────────────────────────────
if [[ $has_none -eq 1 && $has_evidence -eq 1 ]]; then
  echo "FLAG $artifact:$none_lineno: '- none' coexists with EVID/ASSUMPTION bullet(s) — contradiction; remove '- none' when evidence bullets are present"
  flags=$((flags+1))
fi

# ── Step 6: EVID-NNN tokens anywhere in the artifact must resolve to ledger ──
while IFS= read -r token; do
  [[ -z "$token" ]] && continue
  # Use -- to prevent grep/ugrep from treating the leading "- " as an option flag.
  if [[ ! -f "$ledger" ]] || ! grep -qF -- "- $token | " "$ledger"; then
    # Find the first line in the artifact that contains this token for the lineno.
    ref_lineno="$(grep -n "$token" "$artifact" | head -1 | cut -d: -f1)"
    echo "FLAG $artifact:${ref_lineno:-0}: EVID token $token referenced in artifact but has no matching entry in ledger ($ledger)"
    flags=$((flags+1))
  fi
done < <(grep -oE 'EVID-[0-9]{3}' "$artifact" 2>/dev/null | sort -u)

# ── Summary ──────────────────────────────────────────────────────────────────
if [[ $flags -gt 0 ]]; then
  echo "grounding-lint: $flags FLAG(s) in $artifact. Fix: cite each load-bearing external fact" \
       "via 'bash lib/evidence.sh add <ledger> \"<claim>\" \"<cmd>\" \"<output>\"' and add" \
       "'- EVID-NNN: text' to ## Grounding, or rewrite as '- ASSUMPTION: <claim> | verify: <cmd>'." >&2
  exit 1
fi

echo "grounding-lint: ok"
exit 0
