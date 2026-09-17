#!/usr/bin/env bash
# Ingest existing get-shit-done artifacts into loop-spec format.
#
# Subcommands:
#
#   patterns <slug> <target_path>
#     Looks for .planning/phases/<slug>/PATTERNS.md or .planning/<slug>/PATTERNS.md.
#     If found, writes into <target_path> with an "Imported from GSD" header.
#     Prints "INGESTED <source>" or "NONE" (caller decides whether to dispatch pattern-mapper).
#
# Operates from the current working directory (the project root).
# Exit codes:
#   0 success (whether or not anything was ingested; read stdout to find out)
#   1 bad invocation
set -euo pipefail

cmd="${1:-}"

case "$cmd" in
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
    echo "usage: gsd-ingest.sh patterns <slug> <target>" >&2
    exit 1
    ;;
esac
