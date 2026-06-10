#!/usr/bin/env bash
# Ingest existing get-shit-done artifacts into super-spec format.
#
# Subcommands:
#
#   codebase
#     Reads .planning/codebase/* and concatenates into docs/super-spec/codebase/{TECH,ARCH,QUALITY,CONCERNS}.md.
#     Mapping (one row per super-spec target):
#       TECH      <- STACK.md + INTEGRATIONS.md
#       ARCH      <- ARCHITECTURE.md + STRUCTURE.md
#       QUALITY   <- CONVENTIONS.md + TESTING.md
#       CONCERNS  <- CONCERNS.md
#     DOMAIN.md is never ingested (no GSD analog) and must be produced by super-spec-mapper-domain.
#     Prints one line per target: "INGESTED <target>" or "SKIPPED <target> (no source)".
#     Outputs are idempotent: if super-spec target already exists it is overwritten only when at least
#     one source exists; otherwise left alone.
#
#   patterns <slug> <target_path>
#     Looks for .planning/phases/<slug>/PATTERNS.md or .planning/<slug>/PATTERNS.md.
#     If found, writes into <target_path> with an "Imported from GSD" header.
#     Prints "INGESTED <source>" or "NONE" (caller decides whether to dispatch pattern-mapper).
#
# Both subcommands operate from the current working directory (the project root).
# Exit codes:
#   0 success (whether or not anything was ingested; read stdout to find out)
#   1 bad invocation
set -euo pipefail

cmd="${1:-}"

case "$cmd" in
  codebase)
    if [[ ! -d .planning/codebase ]]; then
      printf 'NONE\n'
      exit 0
    fi

    mkdir -p docs/super-spec/codebase
    iso_now="$(date -u +%Y-%m-%dT%H:%MZ)"

    declare -a rows=(
      "TECH:STACK.md INTEGRATIONS.md"
      "ARCH:ARCHITECTURE.md STRUCTURE.md"
      "QUALITY:CONVENTIONS.md TESTING.md"
      "CONCERNS:CONCERNS.md"
    )

    for row in "${rows[@]}"; do
      target_name="${row%%:*}"
      sources_str="${row#*:}"
      # shellcheck disable=SC2206
      sources=($sources_str)

      present=()
      for s in "${sources[@]}"; do
        [[ -f ".planning/codebase/$s" ]] && present+=("$s")
      done

      target="docs/super-spec/codebase/${target_name}.md"
      if (( ${#present[@]} == 0 )); then
        printf 'SKIPPED %s (no source)\n' "$target_name"
        continue
      fi

      {
        printf '# %s\n\n' "$target_name"
        printf '> Imported from GSD `.planning/codebase/` on %s. Sources: ' "$iso_now"
        printf '%s, ' "${present[@]}" | sed 's/, $//'
        printf '\n\n'
        for s in "${present[@]}"; do
          printf '## (from %s)\n\n' "$s"
          cat ".planning/codebase/$s"
          printf '\n'
        done
      } > "$target"
      printf 'INGESTED %s\n' "$target_name"
    done
    ;;

  patterns)
    slug="${2:-}"
    target="${3:-}"
    if [[ -z "$slug" || -z "$target" ]]; then
      echo "usage: gsd-ingest.sh patterns <slug> <target_path>" >&2
      exit 1
    fi

    candidates=(
      ".planning/phases/$slug/PATTERNS.md"
      ".planning/$slug/PATTERNS.md"
    )

    for cand in "${candidates[@]}"; do
      if [[ -f "$cand" ]]; then
        mkdir -p "$(dirname "$target")"
        {
          printf '# PATTERNS.md - %s\n\n' "$slug"
          printf '> Imported from GSD `%s` on %s.\n\n' "$cand" "$(date -u +%Y-%m-%dT%H:%MZ)"
          cat "$cand"
        } > "$target"
        printf 'INGESTED %s\n' "$cand"
        exit 0
      fi
    done

    printf 'NONE\n'
    ;;

  *)
    echo "usage: gsd-ingest.sh {codebase|patterns <slug> <target>}" >&2
    exit 1
    ;;
esac
