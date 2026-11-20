#!/usr/bin/env bash
# Usage: bash scripts/build.sh <version> [--src <dir>] [--out <dir>] [--test-overrides <file>]
#   -> <out>/puzzles-site-reports.zip (top folder puzzles-site-reports/) and <out>/VERSION.
#   --src   the tree to build (default: this checkout); --out  where the zip goes (default: this checkout's dist/).
# The zip is byte-reproducible: the same tree gives the same sha256 on any machine (entries sorted, fixed time and mode,
# stored uncompressed because zlib output can differ between builds, no directory entries, Python isolated with -I).
# The owner's promoter (scripts/wp-sr-promote) reviews and signs the zip that CI builds with this script.
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
# allowlist: only these ship, whatever else sits in the tree (not README or CHANGELOG: they would tell anyone the version)
(cd "$SRC" && cp puzzles-site-reports.php uninstall.php LICENSE "$S/" && cp -r includes "$S/")
# The promoter refuses anything else: every shipped file is plain ASCII, and only PHP holds "<?".
BAD=$(cd "$S" && { LC_ALL=C grep -rlaUE $'[^\t -~]' . || true; }); [ -z "$BAD" ] || die "not plain ASCII (TAB, LF, printable):" $BAD
BAD=$(cd "$S" && { grep -rlF '<?' --exclude='*.php' . || true; }); [ -z "$BAD" ] || die "not PHP but holds '<?':" $BAD

F="$S/puzzles-site-reports.php"
# Anchored: only these two whole lines are rewritten, and each must be there exactly once (the promoter checks it too).
sed -i -E "s/^( \* Version:) +[0-9]+\.[0-9]+\.[0-9]+\$/\1 $V/; s/^(define\( 'PUZZLES_SITE_REPORTS_VERSION', ')[0-9]+\.[0-9]+\.[0-9]+(' \);)\$/\1$V\2/" "$F"
HP='^([[:blank:]]*<\?(php)?)?[[:blank:]/*#@]*' # the prefix of a header line as get_file_data() reads it (any case)
[ "$(grep -ciE "${HP}Version:" "$F")" = 1 ] && grep -qxF " * Version: $V" "$F" || die "the main file needs exactly one ' * Version: X.Y.Z' header line"
[ "$(grep -cxF "define( 'PUZZLES_SITE_REPORTS_VERSION', '$V' );" "$F")" = 1 ] || die "the main file needs exactly one PUZZLES_SITE_REPORTS_VERSION define"

if [ -n "$OVR" ]; then
  while read -r name val; do
    case "$name" in
      PUZZLES_SR_UPDATE_PUBKEY | PUZZLES_SITE_REPORTS_MANIFEST_URL | PUZZLES_SITE_REPORTS_PACKAGE_PREFIX) ;;
      *) die "--test-overrides: '$name' is not an update constant" ;;
    esac
    [[ "$val" =~ ^[A-Za-z0-9+/=:._-]+$ ]] || die "--test-overrides: bad value for $name"
    sed -i "s|^define( '$name', '[^']*' );\$|define( '$name', '$val' );|" "$F"
    [ "$(grep -cxF "define( '$name', '$val' );" "$F")" = 1 ] || die "--test-overrides: $name not replaced exactly once"
  done <"$OVR"
fi

PY=python3; "$PY" -I -c '' 2>/dev/null || PY=python # python3 may be a Windows store stub
# Writes the zip and prints its entries (the CI log shows what ships). The promoter carries this builder word for word
# and requires a candidate to be its output (tests/promote.sh compares them): change both, in one commit.
# Relative paths only: Git Bash does not convert path arguments for Windows Python when MSYS_NO_PATHCONV is set.
cd "$OUT"
"$PY" -I - stage <<'PYEOF'
import os, sys, zipfile
src = sys.argv[1]
names = sorted(os.path.relpath(os.path.join(d, f), src).replace(os.sep, '/') for d, _, fs in os.walk(src) for f in fs)
with zipfile.ZipFile('puzzles-site-reports.zip', 'w') as z:
    for n in names:
        i = zipfile.ZipInfo(n, (1980, 1, 1, 0, 0, 0))  # ZIP_STORED by default
        i.create_system = 3                              # Unix, whatever machine builds it
        i.external_attr = 0o100644 << 16                 # a regular file, rw-r--r--
        with open(os.path.join(src, n), 'rb') as f:
            z.writestr(i, f.read())
print('\n'.join(names))
PYEOF
rm -rf stage
printf '%s' "$V" >VERSION
echo "built puzzles-site-reports.zip ($V)"
