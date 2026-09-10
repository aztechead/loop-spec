#!/usr/bin/env bash
# Read one key of feature.json through the typed reader (lib/feature_read.py).
# Usage: feature-read.sh <feature_dir|feature.json> <key>[.<sub>...] [-r] [--default <json>] [--jq <filter>]
#        feature-read.sh <feature_dir|feature.json> [-r|-c] [-e] --filter <jq filter> [-- <jq args>]
#        feature-read.sh <feature_dir|feature.json> --all [--drop-strays] | --strays
#        feature-read.sh --keys
# Exit: 0 printed; 1 the key is not a state key; 2 unreadable feature.json or bad call.
set -euo pipefail

exec python3 "$(dirname "${BASH_SOURCE[0]}")/feature_read.py" "$@"
