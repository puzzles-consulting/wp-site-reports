#!/usr/bin/env bash
# Usage: bash scripts/build.sh <version>  ->  dist/puzzles-site-reports.zip (top folder puzzles-site-reports/)
set -euo pipefail
V="${1:?usage: build.sh <version>}"
cd "$(dirname "$0")/.."

rm -rf dist && mkdir -p dist/stage/puzzles-site-reports
# everything the plugin ships; dev files stay out
tar --exclude=./dist --exclude=./.git --exclude=./.github --exclude=./.claude --exclude=./.superpowers \
  --exclude=./tests --exclude=./scripts --exclude=./docs --exclude=./AGENTS.md --exclude=./.gitignore -cf - . |
  tar -xf - -C dist/stage/puzzles-site-reports

F=dist/stage/puzzles-site-reports/puzzles-site-reports.php
sed -i -E "s/^( \* Version:).*/\1 $V/; s/(define\( 'PUZZLES_SITE_REPORTS_VERSION', ')[^']*(' \);)/\1$V\2/" "$F"
grep -q " \* Version: $V\$" "$F"
grep -q "'PUZZLES_SITE_REPORTS_VERSION', '$V'" "$F"

PY=python3; "$PY" -c '' 2>/dev/null || PY=python # python3 may be a Windows store stub
"$PY" - <<'PYEOF'
import os, zipfile
root = 'dist/stage'
with zipfile.ZipFile('dist/puzzles-site-reports.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for d, _, files in os.walk(root):
        for f in sorted(files):
            p = os.path.join(d, f)
            z.write(p, os.path.relpath(p, root).replace(os.sep, '/'))
PYEOF
rm -rf dist/stage
printf '%s' "$V" > dist/VERSION
echo "built dist/puzzles-site-reports.zip ($V)"
