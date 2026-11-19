#!/usr/bin/env bash
# Usage: bash scripts/manifest.sh <version> [tested-wp]  ->  dist/manifest.json (the file the plugin's update check reads)
# `requires` / `requires_php` come from the plugin header. `tested` is the newest WordPress the smoke test has run
# against: bump the default below (or pass it) when that moves.
set -euo pipefail
V="${1:?usage: manifest.sh <version> [tested-wp]}"
TESTED="${2:-6.9}"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad version: $V" >&2; exit 1; }
cd "$(dirname "$0")/.."
hdr() { sed -n "s/^ \* $1: *//p" puzzles-site-reports.php | head -1 | tr -d '\r'; }
REQ="$(hdr 'Requires at least')"; REQPHP="$(hdr 'Requires PHP')"
[[ "$REQ" =~ ^[0-9.]+$ && "$REQPHP" =~ ^[0-9.]+$ ]] || { echo "bad Requires header: '$REQ' '$REQPHP'" >&2; exit 1; }
mkdir -p dist
printf '{"version":"%s","package":"https://github.com/puzzles-consulting/wp-site-reports/releases/download/v%s/puzzles-site-reports.zip","requires":"%s","requires_php":"%s","tested":"%s"}\n' "$V" "$V" "$REQ" "$REQPHP" "$TESTED" > dist/manifest.json
echo "wrote dist/manifest.json ($V)"
