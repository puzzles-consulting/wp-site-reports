#!/usr/bin/env bash
# Usage: bash scripts/manifest.sh <version> [tested-wp]  ->  dist/manifest.json (the file the plugin's update check reads)
# `tested` is the newest WordPress the smoke test has run against; bump the default (or pass it) when that moves.
set -euo pipefail
V="${1:?usage: manifest.sh <version> [tested-wp]}"
TESTED="${2:-6.9}"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || { echo "bad version: $V" >&2; exit 1; }
cd "$(dirname "$0")/.."
mkdir -p dist
printf '{"version":"%s","package":"https://github.com/puzzles-consulting/wp-site-reports/releases/download/v%s/puzzles-site-reports.zip","requires":"5.8","requires_php":"7.4","tested":"%s"}\n' "$V" "$V" "$TESTED" > dist/manifest.json
echo "wrote dist/manifest.json ($V)"
