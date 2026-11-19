#!/usr/bin/env bash
# Usage: bash scripts/build.sh <version> [--src <dir>] [--out <dir>] [--test-overrides <file>]
#   -> <out>/puzzles-site-reports.zip (top folder puzzles-site-reports/) and <out>/VERSION.
#   --src   the tree to build (default: this checkout); --out  where the zip goes (default: this checkout's dist/).
# The zip is byte-reproducible: the same tree gives the same sha256 on any machine (entries sorted, fixed time and mode,
# stored uncompressed because zlib output can differ between builds, no directory entries, Python isolated with -I).
# scripts/promote.sh relies on it (its header).
# --test-overrides <file>: tests only (tests/smoke.sh). Each line "<CONSTANT> <value>" replaces one of the update
# constants PUZZLES_SR_UPDATE_PUBKEY, PUZZLES_SITE_REPORTS_MANIFEST_URL or PUZZLES_SITE_REPORTS_PACKAGE_PREFIX in the
# staged copy.
set -euo pipefail
die() { echo "build.sh: $*" >&2; exit 1; }
V="${1:?usage: build.sh <version> [--src <dir>] [--out <dir>] [--test-overrides <file>]}"; shift
[[ "$V" =~ ^[0-9A-Za-z.-]+$ ]] || die "bad version: '$V'"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC=$ROOT; OUT=$ROOT/dist; OVR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC=$(realpath "${2:?--src needs a directory}") ;;
    --out) OUT=$(realpath -m "${2:?--out needs a directory}") ;;
    --test-overrides) OVR=$(realpath "${2:?--test-overrides needs a file}") ;;
    *) die "unknown argument: $1" ;;
  esac
  shift 2
done

S="$OUT/stage/puzzles-site-reports"
rm -rf "$OUT/stage" "$OUT/puzzles-site-reports.zip" && mkdir -p "$S"
# allowlist: only these ship, whatever else sits in the tree
(cd "$SRC" && cp puzzles-site-reports.php uninstall.php README.md CHANGELOG.md LICENSE "$S/" && cp -r includes "$S/")

F="$S/puzzles-site-reports.php"
sed -i -E "s/^( \* Version:).*/\1 $V/; s/(define\( 'PUZZLES_SITE_REPORTS_VERSION', ')[^']*(' \);)/\1$V\2/" "$F"
grep -q " \* Version: $V\$" "$F"
grep -q "'PUZZLES_SITE_REPORTS_VERSION', '$V'" "$F"

if [ -n "$OVR" ]; then
  while read -r name val; do
    case "$name" in
      PUZZLES_SR_UPDATE_PUBKEY | PUZZLES_SITE_REPORTS_MANIFEST_URL | PUZZLES_SITE_REPORTS_PACKAGE_PREFIX) ;;
      *) die "--test-overrides: '$name' is not an update constant" ;;
    esac
    [[ "$val" =~ ^[A-Za-z0-9+/=:._-]+$ ]] || die "--test-overrides: bad value for $name"
    sed -i "s|^define( '$name', '[^']*' );|define( '$name', '$val' );|" "$F"
    grep -qxF "define( '$name', '$val' );" "$F" || die "--test-overrides: $name not replaced"
  done <"$OVR"
fi

PY=python3; "$PY" -I -c '' 2>/dev/null || PY=python # python3 may be a Windows store stub
# Writes the zip and prints its entries (the CI log shows what ships).
# Relative paths only: Git Bash does not convert path arguments for Windows Python when MSYS_NO_PATHCONV is set.
cd "$OUT"
"$PY" -I - <<'PYEOF'
import os, zipfile
names = sorted(os.path.relpath(os.path.join(d, f), 'stage').replace(os.sep, '/') for d, _, fs in os.walk('stage') for f in fs)
with zipfile.ZipFile('puzzles-site-reports.zip', 'w') as z:
    for n in names:
        i = zipfile.ZipInfo(n, (1980, 1, 1, 0, 0, 0))  # ZIP_STORED by default
        i.create_system = 3                              # Unix, whatever machine builds it
        i.external_attr = 0o100644 << 16                 # a regular file, rw-r--r--
        with open(os.path.join('stage', n), 'rb') as f:
            z.writestr(i, f.read())
print('\n'.join(names))
PYEOF
rm -rf stage
printf '%s' "$V" >VERSION
echo "built puzzles-site-reports.zip ($V)"
