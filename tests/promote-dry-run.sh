#!/usr/bin/env bash
# Offline check of scripts/promote.sh --dry-run on the committed HEAD: a throwaway key, a local bare repository as
# `origin`, and "release" zips built locally. Needs php or Docker (scripts/php.sh), python, unzip. Never uses a real key.
# Usage: bash tests/promote-dry-run.sh
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git clone -q --bare "$REPO" "$T/origin.git"
git clone -q "$T/origin.git" "$T/work"
cd "$T/work"
g() { git -c user.name=test -c user.email=test@example.com "$@"; }
PY=python3; "$PY" -c '' 2>/dev/null || PY=python

PUB=$(bash scripts/keygen.sh 3>"$T/sk"); SK=$(cat "$T/sk")
# Children of promote.sh must never see the key: these shims fail the run if git or unzip inherit it.
mkdir "$T/bin"
for c in git unzip; do
  printf '#!/usr/bin/env bash\n[ -z "${PUZZLES_SR_SIGNING_KEY+x}" ] || { echo "LEAK: %s got the key" >&2; exit 99; }\nexec "%s" "$@"\n' \
    "$c" "$(command -v "$c")" >"$T/bin/$c"
  chmod +x "$T/bin/$c"
done

release() { # release <tag>: tags HEAD, pushes it with HEAD as main, builds the stand-in release zip $T/<tag>.zip
  g tag -a "$1" -m "$1"; git push -q origin HEAD:main "$1"
  bash scripts/build.sh "${1#v}" >/dev/null; cp dist/puzzles-site-reports.zip "$T/$1.zip"
}
promote() { PATH="$T/bin:$PATH" PUZZLES_SR_SIGNING_KEY="$SK" bash scripts/promote.sh "$1" 6.8.1 --dry-run "$2"; }
refuses() { # refuses <expected message> <tag> <zip>
  local want=$1; shift
  if promote "$@" >"$T/out" 2>&1; then cat "$T/out"; echo "FAIL: expected a refusal ($want)" >&2; exit 1; fi
  grep -qF "$want" "$T/out" || { cat "$T/out"; echo "FAIL: expected '$want'" >&2; exit 1; }
  echo "ok: refused: $want"
}
rezip() { # rezip <in> <out> flip|add: one byte of includes/seo.php flipped, or one extra entry
  "$PY" - "$@" <<'EOF'
import sys, zipfile
src, dst, mode = sys.argv[1:4]
with zipfile.ZipFile(src) as a, zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as b:
    for i in a.infolist():
        d = a.read(i)
        if mode == 'flip' and i.filename == 'puzzles-site-reports/includes/seo.php':
            d = d[:-1] + bytes([d[-1] ^ 1])
        b.writestr(i, d)
    if mode == 'add':
        b.writestr('puzzles-site-reports/extra.php', '<?php')
EOF
}

# 1. Matching contents: signs. The manifest carries the release zip's sha256 and verifies over its five fields.
release v9.9.9
m=$(promote v9.9.9 "$T/v9.9.9.zip")
echo "$m"
grep -qF "\"sha256\":\"$(sha256sum "$T/v9.9.9.zip" | cut -c1-64)\"" <<<"$m"
grep -qF '"version":"9.9.9","sha256":' <<<"$m"
grep -qF '"requires":"5.8","requires_php":"7.4","tested":"6.8.1"' <<<"$m"
. scripts/php.sh
v=$(printf '%s' "$m" | php_run -r '$m = json_decode( stream_get_contents( STDIN ), true );
echo sodium_crypto_sign_verify_detached( base64_decode( $m["signature"] ), implode( "\n", array( $m["version"], $m["sha256"], $m["requires"], $m["requires_php"], $m["tested"] ) ), base64_decode( $argv[1] ) ) ? "valid" : "invalid";' "$PUB")
[ "$v" = valid ] || { echo "FAIL: signature $v" >&2; exit 1; }
echo "ok: signed, signature valid"

# 2. The release zip is not what the tag builds.
rezip "$T/v9.9.9.zip" "$T/flip.zip" flip
refuses 'puzzles-site-reports/includes/seo.php in the release zip differs from a build of v9.9.9' v9.9.9 "$T/flip.zip"
rezip "$T/v9.9.9.zip" "$T/add.zip" add
refuses "the release zip's entries differ from a build of v9.9.9" v9.9.9 "$T/add.zip"

# 3. origin's tag points elsewhere (moved after the canary), then a tag that is not on main.
git push -q -f origin "$(git rev-parse HEAD~1):refs/tags/v9.9.9"
refuses "origin's v9.9.9 is" v9.9.9 "$T/v9.9.9.zip"
git push -q -f origin v9.9.9
g checkout -q -b side; g commit -q --allow-empty -m side
g tag -a v9.9.8 -m v9.9.8; git push -q origin v9.9.8
bash scripts/build.sh 9.9.8 >/dev/null; cp dist/puzzles-site-reports.zip "$T/v9.9.8.zip"
refuses 'is not on origin/main' v9.9.8 "$T/v9.9.8.zip"
g checkout -q main

# 4. A dry run refuses the plugin's release key (this throwaway one stands in as the constant), and any earlier one.
sed -i "s|^define( 'PUZZLES_SR_UPDATE_PUBKEY', '[^']*' );|define( 'PUZZLES_SR_UPDATE_PUBKEY', '$PUB' );|" puzzles-site-reports.php
grep -qF "'PUZZLES_SR_UPDATE_PUBKEY', '$PUB'" puzzles-site-reports.php
g commit -qam 'test: the throwaway key is the release key'
release v9.9.7
refuses 'dry run with a release key' v9.9.7 "$T/v9.9.7.zip"
g revert --no-edit HEAD >/dev/null
release v9.9.6
refuses 'dry run with a release key' v9.9.6 "$T/v9.9.6.zip"

# 5. Arguments are checked before anything runs.
o=$(PUZZLES_SR_SIGNING_KEY="$SK" bash scripts/promote.sh v9.9.9 '6.8; rm -rf x' 2>&1) && exit 1; grep -qF 'bad tested' <<<"$o"
o=$(PUZZLES_SR_SIGNING_KEY= bash scripts/promote.sh v9.9.9 6.8.1 --dry-run "$T/v9.9.9.zip" 2>&1) && exit 1; grep -qF 'is not set' <<<"$o"
echo "ok: bad arguments refused"
echo "promote-dry-run: all checks passed"
