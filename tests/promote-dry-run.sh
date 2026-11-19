#!/usr/bin/env bash
# Offline check of scripts/promote.sh --dry-run on the committed HEAD. A local bare repository is `origin`; a "dev" clone
# pushes tagged commits (each carrying a throwaway public key) and builds their release zips as CI does; the "owner" clone
# stays on HEAD (only real keys in its history) and runs promote.sh. Throwaway keys only, never a real one.
# Needs php or Docker (scripts/php.sh), python, unzip. CI runs it (.github/workflows/ci.yml).
# Usage: bash tests/promote-dry-run.sh
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git -C "$REPO" push -q "$T/origin.git" HEAD:refs/heads/main
git clone -q -b main "$T/origin.git" "$T/owner"
git clone -q -b main "$T/origin.git" "$T/dev"
cd "$T/dev"
g() { git -c user.name=test -c user.email=test@example.com "$@"; }
PY=python3; "$PY" -I -c '' 2>/dev/null || PY=python
. scripts/php.sh

# Three throwaway keypairs: public keys in PUBn, secret keys in SKn.
for n in 1 2 3; do
  declare "PUB$n=$(bash scripts/keygen.sh 3>"$T/sk$n")"; declare "SK$n=$(cat "$T/sk$n")"
done
# promote.sh's children must never see a key: these shims fail the run if one inherits it.
mkdir "$T/bin"
for c in git gh unzip python3 python docker php; do
  r=$(command -v "$c") || continue
  printf '#!/usr/bin/env bash\n[ -z "${PUZZLES_SR_SIGNING_KEY+x}${PUZZLES_SR_NEW_SIGNING_KEY+x}" ] || { echo "LEAK: %s got a key" >&2; exit 99; }\nexec "%s" "$@"\n' \
    "$c" "$r" >"$T/bin/$c"
  chmod +x "$T/bin/$c"
done

sync() { git -C "$T/owner" fetch -q --tags origin; } # the owner's tags follow origin's new ones (a moved tag fails: not called then)
tag() { g tag -a "$1" -m "$1"; git push -q origin "$1"; sync; }
release() { # release <tag> <pubkey>: a commit on main carrying that key, tagged; its zip, built as CI does, is $T/<tag>.zip
  sed -i "s|^define( 'PUZZLES_SR_UPDATE_PUBKEY', '[^']*' );|define( 'PUZZLES_SR_UPDATE_PUBKEY', '$2' );|" puzzles-site-reports.php
  grep -qF "'PUZZLES_SR_UPDATE_PUBKEY', '$2'" puzzles-site-reports.php
  g commit -q --allow-empty -am "test: $1"; git push -q origin HEAD:main; tag "$1"
  bash scripts/build.sh "${1#v}" --out "$T/build-$1" >/dev/null; cp "$T/build-$1/puzzles-site-reports.zip" "$T/$1.zip"
}
back_to() { g reset -q --hard "$1"; git push -q -f origin HEAD:main; } # main drops the refused commits
SK=$SK1; NSK=""
promote() { # promote <tag> <zip> [options]: as the owner, signing with $SK (and $NSK as the new key)
  local tag=$1 zip=$2; shift 2
  PATH="$T/bin:$PATH" PUZZLES_SR_SIGNING_KEY="$SK" PUZZLES_SR_NEW_SIGNING_KEY="$NSK" \
    bash "$T/owner/scripts/promote.sh" "$tag" 6.8.1 --dry-run "$zip" "$@"
}
refuses() { # refuses <expected message> <promote args...>
  local want=$1; shift
  if promote "$@" >"$T/out" 2>&1; then cat "$T/out"; echo "FAIL: expected a refusal ($want)" >&2; exit 1; fi
  grep -qF -- "$want" "$T/out" || { cat "$T/out"; echo "FAIL: expected '$want'" >&2; exit 1; }
  echo "ok: refused: $want"
}
verify() { # verify <manifest> <zip>: the zip's own plugin file checks the manifest (puzzles_sr_verified_manifest)
  { printf '<?php define( "ABSPATH", "/" ); function add_filter() {} function add_action() {} function register_deactivation_hook() {} ?>'
    unzip -p "$2" puzzles-site-reports/puzzles-site-reports.php | grep -v '^require_once __DIR__'
    printf '\necho null === puzzles_sr_verified_manifest( base64_decode( $argv[1] ) ) ? "invalid" : "valid";\n'
  } | php_run -- "$(printf '%s' "$1" | base64 | tr -d '\n')" | tr -d '\r'
}

# 1. Matching tree: signs. Without --trusted-zip (the first release) and with the previous release as the trusted one.
release v9.9.7 "$PUB1"
m=$(promote v9.9.7 "$T/v9.9.7.zip" 2>"$T/err"); grep -qF 'checks are skipped' "$T/err"
[ "$(verify "$m" "$T/v9.9.7.zip")" = valid ]
release v9.9.8 "$PUB1"
m=$(promote v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip")
echo "$m"
grep -qF "\"version\":\"9.9.8\",\"sha256\":\"$(sha256sum "$T/v9.9.8.zip" | cut -c1-64)\"" <<<"$m"
grep -qF '"requires":"5.8","requires_php":"7.4","tested":"6.8.1"' <<<"$m"
[ "$(verify "$m" "$T/v9.9.8.zip")" = valid ]
[ "$(verify "${m/6.8.1/6.8.2}" "$T/v9.9.8.zip")" = invalid ] # the verifier really checks
echo "ok: signed; the plugin's own verifier accepts the manifest"

# 2. The release zip is not this checkout's build of the tag: one byte flipped.
"$PY" -I -c 'import sys; b = bytearray(open(sys.argv[1], "rb").read()); b[len(b) // 2] ^= 1; open(sys.argv[2], "wb").write(b)' \
  "$T/v9.9.8.zip" "$T/flip.zip"
refuses 'is not what this checkout builds from v9.9.8' v9.9.8 "$T/flip.zip" --trusted-zip "$T/v9.9.7.zip"

# 3. The tag's tree: a symlink, the key named in another PHP file, the key defined twice.
g update-index --add --cacheinfo "120000,$(printf x | git hash-object -w --stdin),includes/link.php"
g commit -q -m 'test: symlink'; git push -q origin HEAD:main; tag v9.9.9
refuses "has 'includes/link.php' with mode 120000" v9.9.9 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
back_to v9.9.8
printf '<?php define( "puzzles_sr_update_pubkey", "x", true );\n' >includes/evil.php
g add includes/evil.php; g commit -q -m 'test: second key'; git push -q origin HEAD:main; tag v9.9.10
refuses 'PUZZLES_SR_UPDATE_PUBKEY appears outside the main file' v9.9.10 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
back_to v9.9.8
printf "const PUZZLES_SR_UPDATE_PUBKEY = 'x';\n" >>puzzles-site-reports.php
g commit -q -am 'test: defined twice'; git push -q origin HEAD:main; tag v9.9.11
refuses 'defines PUZZLES_SR_UPDATE_PUBKEY more than once' v9.9.11 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
back_to v9.9.8

# 4. origin's tag points elsewhere (moved after the canary), then a tag that is not on main.
git push -q -f origin "$(git rev-parse 'v9.9.7^{commit}'):refs/tags/v9.9.8"
refuses "origin's v9.9.8 is" v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
git push -q -f origin v9.9.8
g checkout -q -b side; g commit -q --allow-empty -m side; tag v9.9.12; g checkout -q main
refuses 'is not on origin/main' v9.9.12 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"

# 5. Keys and versions against the latest promoted release (v9.9.7 or v9.9.8, key PUB1).
release v9.9.13 "$PUB2"
refuses 'changes the release key' v9.9.13 "$T/v9.9.13.zip" --trusted-zip "$T/v9.9.8.zip"
NSK=$SK3; refuses 'is not the secret key of' v9.9.13 "$T/v9.9.13.zip" --trusted-zip "$T/v9.9.8.zip" --rotate
NSK=$SK2; m=$(promote v9.9.13 "$T/v9.9.13.zip" --trusted-zip "$T/v9.9.8.zip" --rotate 2>"$T/err"); NSK=""
grep -qF "sites trust only $PUB2" "$T/err"
[ "$(verify "$m" "$T/v9.9.8.zip")" = valid ]    # signed with the old key: sites on v9.9.8 take it...
[ "$(verify "$m" "$T/v9.9.13.zip")" = invalid ] # ...and not with the new one
echo "ok: --rotate signs with the old key"
refuses '--rotate needs the new secret key' v9.9.13 "$T/v9.9.13.zip" --trusted-zip "$T/v9.9.8.zip" --rotate
NSK=$SK2; refuses 'set without --rotate' v9.9.13 "$T/v9.9.13.zip" --trusted-zip "$T/v9.9.8.zip"; NSK=""
SK=$SK2; refuses 'is not the one sites trust now' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"; SK=$SK1
refuses 'is not newer than the latest release (9.9.8)' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.8.zip"
refuses 'is not newer than the latest release (9.9.13)' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.13.zip"

# 6. A dry run refuses any key in the owner's history: here the owner's checkout is one whose history carries PUB1.
git -C "$T/owner" checkout -q v9.9.8
refuses 'dry run with a release key' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
git -C "$T/owner" checkout -q main

# 7. Arguments are checked before anything runs.
o=$(PUZZLES_SR_SIGNING_KEY="$SK" bash "$T/owner/scripts/promote.sh" v9.9.8 '6.8; rm -rf x' 2>&1) && exit 1; grep -qF 'bad tested' <<<"$o"
o=$(PUZZLES_SR_SIGNING_KEY= bash "$T/owner/scripts/promote.sh" v9.9.8 6.8.1 --dry-run "$T/v9.9.8.zip" 2>&1) && exit 1; grep -qF 'is not set' <<<"$o"
o=$(PUZZLES_SR_SIGNING_KEY="$SK" bash "$T/owner/scripts/promote.sh" v9.9.8 6.8.1 --trusted-zip "$T/v9.9.7.zip" 2>&1) && exit 1
grep -qF 'for dry runs only' <<<"$o"
echo "ok: bad arguments refused"
echo "promote-dry-run: all checks passed"
