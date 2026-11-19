#!/usr/bin/env bash
# Usage: bash scripts/build.sh <version>  ->  dist/puzzles-site-reports.zip (top folder puzzles-site-reports/)
set -euo pipefail
V="${1:?usage: build.sh <version>}"
cd "$(dirname "$0")/.."

rm -rf dist && mkdir -p dist/stage/puzzles-site-reports
# allowlist: only these ship, whatever else sits in the working tree
for f in puzzles-site-reports.php uninstall.php README.md CHANGELOG.md LICENSE; do
  cp "$f" dist/stage/puzzles-site-reports/
done
[ ! -d includes ] || cp -r includes dist/stage/puzzles-site-reports/

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
# the zip must hold nothing but puzzles-site-reports/ + the allowlist
"$PY" - <<'PYEOF'
import re, zipfile
ok = re.compile(r'^puzzles-site-reports/(puzzles-site-reports\.php|uninstall\.php|README\.md|CHANGELOG\.md|LICENSE|includes/.+)$')
bad = [n for n in zipfile.ZipFile('dist/puzzles-site-reports.zip').namelist() if not ok.match(n)]
if bad:
    raise SystemExit('unexpected zip entries: %s' % bad)
PYEOF
printf '%s' "$V" > dist/VERSION
echo "built dist/puzzles-site-reports.zip ($V)"
