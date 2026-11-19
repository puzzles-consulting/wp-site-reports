#!/usr/bin/env bash
# Usage: bash scripts/build.sh <version>  ->  dist/puzzles-site-reports.zip (top folder puzzles-site-reports/)
set -euo pipefail
V="${1:?usage: build.sh <version>}"
cd "$(dirname "$0")/.."

rm -rf dist && mkdir -p dist/stage/puzzles-site-reports
# allowlist: only these ship, whatever else sits in the working tree
cp puzzles-site-reports.php uninstall.php README.md CHANGELOG.md LICENSE dist/stage/puzzles-site-reports/
cp -r includes dist/stage/puzzles-site-reports/

F=dist/stage/puzzles-site-reports/puzzles-site-reports.php
sed -i -E "s/^( \* Version:).*/\1 $V/; s/(define\( 'PUZZLES_SITE_REPORTS_VERSION', ')[^']*(' \);)/\1$V\2/" "$F"
grep -q " \* Version: $V\$" "$F"
grep -q "'PUZZLES_SITE_REPORTS_VERSION', '$V'" "$F"

PY=python3; "$PY" -c '' 2>/dev/null || PY=python # python3 may be a Windows store stub
# Writes the zip and prints its entries (the CI log shows what ships); fails on anything outside puzzles-site-reports/.
"$PY" - <<'PYEOF'
import os, zipfile
root = 'dist/stage'
with zipfile.ZipFile('dist/puzzles-site-reports.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for d, _, files in os.walk(root):
        for f in sorted(files):
            p = os.path.join(d, f)
            z.write(p, os.path.relpath(p, root).replace(os.sep, '/'))
    names = z.namelist()
print('\n'.join(names))
if any(not n.startswith('puzzles-site-reports/') for n in names):
    raise SystemExit('zip entry outside puzzles-site-reports/')
PYEOF
rm -rf dist/stage
printf '%s' "$V" > dist/VERSION
echo "built dist/puzzles-site-reports.zip ($V)"
