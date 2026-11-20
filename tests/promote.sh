#!/usr/bin/env bash
# Offline check of the promoter, scripts/wp-sr-promote (this worktree's copy), against a stand-in for gh that serves
# releases from a directory, with throwaway keys. The release zips are built as CI builds them (scripts/build.sh), then
# some are changed to be hostile. Every refusal on the candidate and the baseline runs everywhere (they come before the
# review); the promotions themselves need a terminal, made by script(1): Linux and CI (with $CI set, a missing script(1)
# fails). Needs php or Docker, python, unzip. Usage: bash tests/promote.sh
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
P="$REPO/scripts/wp-sr-promote"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export XDG_CONFIG_HOME="$T/cfg" # the promoter's note of the last promotion, never the real one
PY=python3; "$PY" -I -c '' 2>/dev/null || PY=python # python3 may be a Windows store stub
PHP_IMAGE=$(sed -n 's/^PHP_IMAGE=\([^ ]*\).*/\1/p' "$P") # the promoter's pinned image
php_run() {
  if command -v php >/dev/null; then php "$@"; return; fi
  MSYS_NO_PATHCONV=1 docker run -i --rm --network none "$PHP_IMAGE" php "$@"
}

# Throwaway keypairs from the promoter itself: public keys in PUBn, secret keys in SKn.
for i in 1 2 3; do printf -v "PUB$i" %s "$(bash "$P" keygen 3>"$T/sk$i")"; printf -v "SK$i" %s "$(cat "$T/sk$i")"; done
[[ $PUB1 =~ ^[A-Za-z0-9+/]{43}=$ && ${#SK1} -eq 88 && -n $PUB2 && -n $SK3 ]] || { echo "FAIL: keygen" >&2; exit 1; }
o=$(bash "$P" keygen 2>&1) && exit 1; grep -qF 'open file descriptor 3' <<<"$o"
echo "ok: keygen: public key on stdout, secret key on fd 3 only"

# The promoter's children must never see a key, under the variables' names or the ones it keeps them in (the runs
# below export those, as an owner's shell might): these shims fail the run if one does.
mkdir "$T/bin" "$T/gh"
NOKEY='[ -z "${PUZZLES_SR_SIGNING_KEY+x}${PUZZLES_SR_NEW_SIGNING_KEY+x}${KEY+x}${NEWKEY+x}${KP+x}" ]'
for c in unzip php docker diff cmp sha256sum python3 python; do
  r=$(command -v "$c") || continue
  printf '#!/usr/bin/env bash\n%s || { echo "LEAK: %s got a key" >&2; exit 99; }\nexec "%s" "$@"\n' "$NOKEY" "$c" "$r" >"$T/bin/$c"
  chmod +x "$T/bin/$c"
done
# gh: GitHub's releases as a directory, $GHDIR/<tag>/<asset> and $GHDIR/latest.
export GHDIR="$T/gh"
printf '#!/usr/bin/env bash\n%s || { echo "LEAK: gh got a key" >&2; exit 99; }\n' "$NOKEY" >"$T/bin/gh"
cat >>"$T/bin/gh" <<'EOF'
case "$1 $2" in
  "api repos/puzzles-consulting/wp-site-reports/releases/latest")
    [ -s "$GHDIR/latest" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    cat "$GHDIR/latest" ;;
  "api repos/puzzles-consulting/wp-site-reports/releases?per_page=100") # every release's tag, pre-releases included
    for d in "$GHDIR"/v*/; do basename "$d"; done ;;
  "release download") # release download <tag> (--pattern <asset>)... --dir <dir>
    tag=$3; shift 3; pats=(); dir=.
    while [ $# -gt 0 ]; do case "$1" in --pattern) pats+=("$2"); shift 2 ;; --dir) dir=$2; shift 2 ;; *) shift ;; esac; done
    for p in "${pats[@]}"; do [ ! -e "$GHDIR/$tag/$p" ] || cp "$GHDIR/$tag/$p" "$dir/"; done ;;
  "release upload") # release upload <tag> <file>... --clobber
    tag=$3; shift 3; for f in "$@"; do [ "$f" = --clobber ] || cp "$f" "$GHDIR/$tag/"; done ;;
  "release edit") # release edit <tag> --prerelease=false --latest
    [ -z "${GH_FAIL_EDIT:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
    printf '%s\n' "$3" >"$GHDIR/latest" ;;
  *) echo "gh shim: unexpected call: $*" >&2; exit 97 ;;
esac
EOF
chmod +x "$T/bin/gh"
# zedit.py <put|add|link> <zip> <name> [content file]: replaces or adds an entry (a regular file, or a symlink)
cat >"$T/zedit.py" <<'EOF'
import shutil, sys, zipfile
op, path, name = sys.argv[1:4]
data = open(sys.argv[4], 'rb').read() if len(sys.argv) > 4 else b'x'
with zipfile.ZipFile(path) as zin, zipfile.ZipFile(path + '.tmp', 'w') as zout:
    for i in zin.infolist():
        if not (op == 'put' and i.filename == name):
            zout.writestr(i, zin.read(i))
    i = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
    i.create_system = 3
    i.external_attr = (0o120777 if op == 'link' else 0o100644) << 16
    zout.writestr(i, data)
shutil.move(path + '.tmp', path)
EOF
# dualzip.py <shown.zip> <hidden.zip> <out>: one file, two central directories. Info-ZIP reads the last one (shown's
# files); PclZip, WordPress' fallback without ZipArchive, scans forward and takes the first (hidden's files).
cat >"$T/dualzip.py" <<'EOF'
import struct, sys
def parts(z):  # local entries, central directory, end record (build.sh writes no comment)
    size, off = struct.unpack('<II', z[-10:-2])
    return z[:off], z[off:off + size], bytearray(z[-22:])
def shift(cd, by):  # every central entry's local-header offset moves by `by`
    cd, p = bytearray(cd), 0
    while p < len(cd):
        n, x, c = struct.unpack('<HHH', cd[p + 28:p + 34])
        struct.pack_into('<I', cd, p + 42, struct.unpack('<I', cd[p + 42:p + 46])[0] + by)
        p += 46 + n + x + c
    return bytes(cd)
sl, scd, se = parts(open(sys.argv[1], 'rb').read())
hl, hcd, he = parts(open(sys.argv[2], 'rb').read())
struct.pack_into('<I', he, 16, len(sl) + len(hl))
hidden = hl + shift(hcd, len(sl)) + he
struct.pack_into('<I', se, 16, len(sl) + len(hidden))
struct.pack_into('<H', se, 20, 1)  # a comment, so the file does not end in an end record (PclZip's first look)
open(sys.argv[3], 'wb').write(sl + hidden + scd + bytes(se) + b'.')
EOF

SK=$SK1; NSK=""
run() { # run <args...>: the promoter with no terminal (every refusal comes before the review)
  PATH="$T/bin:$PATH" PUZZLES_SR_SIGNING_KEY="$SK" PUZZLES_SR_NEW_SIGNING_KEY="$NSK" KEY=exported NEWKEY=exported KP=exported \
    bash "$P" "$@" </dev/null
}
refuses() { # refuses <expected message> <args...>
  local want=$1; shift
  if run "$@" >"$T/out" 2>&1; then cat "$T/out"; echo "FAIL: expected a refusal ($want)" >&2; exit 1; fi
  grep -qF -- "$want" "$T/out" || { cat "$T/out"; echo "FAIL: expected '$want'" >&2; exit 1; }
  echo "ok: refused: $want"
}
Z() { echo "$GHDIR/$1/puzzles-site-reports.zip"; }
release() { # release <tag> <public key> [function run on the tree first]: CI's pre-release of <tag>, from this worktree
  rm -rf "$T/src" "$T/b"; mkdir "$T/src"
  (cd "$REPO" && cp puzzles-site-reports.php uninstall.php LICENSE "$T/src/" && cp -r includes "$T/src/")
  sed -i "s|^define( 'PUZZLES_SR_UPDATE_PUBKEY', '[^']*' );|define( 'PUZZLES_SR_UPDATE_PUBKEY', '$2' );|" "$T/src/puzzles-site-reports.php"
  [ -z "${3:-}" ] || "$3"
  bash "$REPO/scripts/build.sh" "${1#v}" --src "$T/src" --out "$T/b" >/dev/null
  mkdir -p "$GHDIR/$1"; cp "$T/b/puzzles-site-reports.zip" "$GHDIR/$1/"
}
zedit() { printf "${4:-x}" >"$T/c"; "$PY" -I "$T/zedit.py" "$1" "$(Z "$2")" "$3" "$T/c"; } # zedit <op> <tag> <name> [printf bytes]
main_sed() { # main_sed <tag> <sed expression>: changes the main file inside <tag>'s zip
  unzip -p "$(Z "$1")" puzzles-site-reports/puzzles-site-reports.php >"$T/c"; sed -i "$2" "$T/c"
  "$PY" -I "$T/zedit.py" put "$(Z "$1")" puzzles-site-reports/puzzles-site-reports.php "$T/c"
}
# verify <manifest> <zip>: the zip's own plugin file checks the manifest (puzzles_sr_verified_manifest). Coupled to the
# main file: the stubs are the WordPress functions it calls while it loads, and its require_once lines are dropped.
verify() {
  { printf '<?php define( "ABSPATH", "/" ); function add_filter() {} function add_action() {} function register_deactivation_hook() {} ?>'
    unzip -p "$2" puzzles-site-reports/puzzles-site-reports.php | grep -v '^require_once __DIR__'
    printf '\necho null === puzzles_sr_verified_manifest( base64_decode( $argv[1] ) ) ? "invalid" : "valid";\n'
  } | php_run -- "$(printf '%s' "$1" | base64 | tr -d '\n')" | tr -d '\r'
}
owner_sig_by() { # owner_sig_by <tag> <public key>: its owner.sig is that key's signature over its manifest
  local m; m=$(tr -d '\r\n' <"$GHDIR/$1/manifest.json")
  [ "$(printf '%s\n%s\n%s' "$2" "$(tr -d '\r\n' <"$GHDIR/$1/owner.sig")" "$(sed -E 's/^[{]"version":"([^"]*)","sha256":"([^"]*)","requires":"([^"]*)","requires_php":"([^"]*)","tested":"([^"]*)".*/\1\n\2\n\3\n\4\n\5/' <<<"$m")" \
    | php_run -r '$p = base64_decode( trim( fgets( STDIN ) ) ); $s = base64_decode( trim( fgets( STDIN ) ) ); echo sodium_crypto_sign_verify_detached( $s, stream_get_contents( STDIN ), $p ) ? "valid" : "invalid";' | tr -d '\r')" = valid ]
}

# 0. The promoter's zip builder is build.sh's, word for word.
builder() { sed -n "/<<'PYEOF'/,/^PYEOF/{/<<'PYEOF'/d;p}" "$1"; }
[ -n "$(builder "$P")" ] && [ "$(builder "$P")" = "$(builder "$REPO/scripts/build.sh")" ] \
  || { echo "FAIL: the promoter's zip builder differs from build.sh's" >&2; exit 1; }
echo "ok: the promoter's zip builder is build.sh's"

# 1. Arguments, and no latest release without --first.
release v9.9.1 "$PUB1"; cp "$(Z v9.9.1)" "$T/v9.9.1.zip"
fresh() { cp "$T/v9.9.1.zip" "$(Z v9.9.1)"; } # v9.9.1 as CI built it
refuses 'pass --first if this is the first promotion' v9.9.1 6.8.1
refuses 'bad tested' v9.9.1 '6.8; rm -rf x' --first
SK=""; refuses 'PUZZLES_SR_SIGNING_KEY is not set' v9.9.1 6.8.1 --first; SK=$SK1
NSK=$SK2; refuses 'is set without --rotate' v9.9.1 6.8.1 --first; NSK=""
refuses 'unknown argument: --yes' v9.9.1 6.8.1 --yes
refuses '--rotate needs the new secret key' v9.9.1 6.8.1 --first --rotate

# 2. The candidate zip, one case per check.
BYTE='has a byte other than TAB, LF and printable ASCII'
PRE='before its key define'
NOTBUILT="is not build.sh's zip of its own files"
KEYDEF="/^define( 'PUZZLES_SR_UPDATE_PUBKEY'/"
zipcase() { fresh; zedit "$2" v9.9.1 "$3" "${4:-x}"; refuses "$1" v9.9.1 6.8.1 --first; } # zipcase <expected> <op> <name> [bytes]
zipcase "has the entry 'other/x.php'" add other/x.php
zipcase "has the entry 'puzzles-site-reports/../x'" add 'puzzles-site-reports/../x'
zipcase 'something other than regular files' link puzzles-site-reports/includes/link.php
zipcase 'one name on Windows' add puzzles-site-reports/includes/SEO.php
zipcase 'reserved device name' add puzzles-site-reports/includes/con.php
zipcase "name ending in '.'" add puzzles-site-reports/includes/x.php.
zipcase "'puzzles-site-reports/LICENSE' $BYTE" put puzzles-site-reports/LICENSE 'caf\303\251\n'
zipcase "'puzzles-site-reports/includes/crlf.php' $BYTE" add puzzles-site-reports/includes/crlf.php '<?php\r\n' # Git Bash: grep -U
zipcase "'puzzles-site-reports/LICENSE' is not PHP but holds a PHP open tag" put puzzles-site-reports/LICENSE '<?php echo 1;\n'
zipcase "$NOTBUILT" add puzzles-site-reports/includes/extra.php '<?php\n' # every file passes, but out of build.sh's order
maincase() { fresh; main_sed v9.9.1 "$2"; refuses "$1" v9.9.1 6.8.1 --first; } # maincase <expected> <sed>
maincase 'needs exactly one version header line' '1a // Version: 6.6.6' # the line WordPress would read
maincase 'needs exactly one version header line' '$a <? Version: 6.6.6' # get_file_data() reads "<?" too
maincase 'must keep the exact Update URI header' '$a <?Update URI: https://evil.example/x'
maincase 'must keep the exact Update URI header' 's|^ \* Update URI: .*| * Update URI: https://evil.example/x|'
maincase 'must keep the exact Update URI header' 's|releases/latest/download/manifest.json|releases/download/v0/manifest.json|'
maincase "$PRE" "${KEYDEF}i \$pzr = array( 'k'=>include __DIR__ . '/includes/seo.php' );"
maincase "$PRE" "${KEYDEF}i define( 'PUZZLES_SR_UPDATE_PUBKEY', 'x' );" # a literal define of the key's name
maincase "$PRE" 's|^ \* Author: .*| * Author: x */ $pzr = 1; /*|' # the header comment closed mid-line
maincase 'needs its key on one top-level line' "${KEYDEF}{s/^/function puzzles_sr_k() { /;s/\$/ }/}"
# Two central directories: every check sees the shown files, WordPress' PclZip would install the hidden ones.
hidden() { echo '// hidden: installed, never reviewed' >>"$T/src/includes/seo.php"; }
release v9.9.1 "$PUB1" hidden; cp "$(Z v9.9.1)" "$T/hidden.zip"
"$PY" -I "$T/dualzip.py" "$T/v9.9.1.zip" "$T/hidden.zip" "$(Z v9.9.1)"
[ "$(unzip -p "$(Z v9.9.1)" puzzles-site-reports/includes/seo.php | grep -c hidden || true)" = 0 ] # Info-ZIP shows the clean files
refuses "$NOTBUILT" v9.9.1 6.8.1 --first
fresh; head -c $((5242880 + 1)) /dev/zero >>"$(Z v9.9.1)"; refuses 'is over 5242880 bytes' v9.9.1 6.8.1 --first
fresh; "$PY" -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1], "a", zipfile.ZIP_DEFLATED).writestr("puzzles-site-reports/big.txt", "x" * 6000000)' "$(Z v9.9.1)"
refuses 'over 5242880 bytes uncompressed' v9.9.1 6.8.1 --first
release v9.9.1 "$PUB2"; refuses 'if a new key is intended' v9.9.1 6.8.1 --first # another key, without --rotate
release v9.9.2 "$PUB1"; cp "$(Z v9.9.2)" "$(Z v9.9.1)"; refuses "' * Version: 9.9.1'" v9.9.1 6.8.1 --first # another version's zip
fresh; refuses 'never from a pipe or a file' v9.9.1 6.8.1 --first # every check passes: no terminal
[ ! -e "$GHDIR/latest" ] && [ ! -e "$GHDIR/v9.9.1/manifest.json" ] && [ ! -e "$XDG_CONFIG_HOME" ]
echo "ok: nothing was signed, uploaded or noted"

# 3. The promotions, on a terminal. The baseline is GitHub's latest, accepted on its owner.sig.
if ! command -v script >/dev/null; then
  [ -z "${CI:-}" ] || { echo "FAIL: CI must run the promotions, but script(1) is missing" >&2; exit 1; }
  echo "skip: the promotions need script(1) for a terminal (CI runs them)"
  echo "promote: all checks passed"; exit 0
fi
term() { # term <typed answer> <args...>: the promoter on a terminal; prints its output
  local a=$1; shift
  PATH="$T/bin:$PATH" PUZZLES_SR_SIGNING_KEY="$SK" PUZZLES_SR_NEW_SIGNING_KEY="$NSK" KEY=exported NEWKEY=exported KP=exported \
    script -qec "$(printf '%q ' bash "$P" "$@")" /dev/null <<<"$a" | tr -d '\r'
}
latest() { [ "$(cat "$GHDIR/latest")" = "$1" ]; }
NOTEF="$XDG_CONFIG_HOME/wp-sr-promote/last"
o=$(term 9.9.0 v9.9.1 6.8.1 --first) && { echo "$o"; exit 1; }
grep -qF 'not confirmed' <<<"$o"; [ ! -e "$GHDIR/latest" ] && [ ! -e "$GHDIR/v9.9.1/owner.sig" ]
echo "ok: a wrong answer on the terminal signs nothing"
o=$(term 9.9.1 v9.9.1 6.8.1 --first) || { echo "$o"; exit 1; }
grep -qF 'promoted v9.9.1' <<<"$o"; latest v9.9.1; [ "$(cat "$NOTEF")" = "9.9.1 $(sha256sum "$(Z v9.9.1)" | cut -c1-64)" ]
[ "$(verify "$(cat "$GHDIR/v9.9.1/manifest.json")" "$(Z v9.9.1)")" = valid ]; owner_sig_by v9.9.1 "$PUB1"
o=$(term '' v9.9.1 6.8.1 --first); grep -qF 'nothing to do' <<<"$o" # a rerun of a finished --first
o=$(PATH="$T/bin:$PATH" bash "$P" verify v9.9.1 "$(Z v9.9.1)" "$PUB1"); grep -qF 'ok: ' <<<"$o"
cp "$(Z v9.9.1)" "$T/flip.zip"; printf '\377' | dd of="$T/flip.zip" bs=1 seek=100 conv=notrunc status=none
o=$(PATH="$T/bin:$PATH" bash "$P" verify v9.9.1 "$T/flip.zip" "$PUB1" 2>&1) && exit 1; grep -qF 'is not the zip' <<<"$o"
o=$(PATH="$T/bin:$PATH" bash "$P" verify v9.9.1 "$(Z v9.9.1)" "$PUB2" 2>&1) && exit 1; grep -qF 'is not signed by' <<<"$o"
echo "ok: the first promotion: manifest, owner.sig and note; a rerun does nothing; verify checks a zip against them"
marker() { echo '// marker: a change' >>"$T/src/includes/seo.php"; }
release v9.9.2 "$PUB1" marker
mv "$NOTEF" "$T/note"; o=$(term 9.9.2 v9.9.2 6.8.1) || { echo "$o"; exit 1; }
grep -qF "baseline: v9.9.1 (owner.sig verified, GitHub's latest); baseline taken from GitHub only" <<<"$o"
grep -qxF '+// marker: a change' <<<"$o"; grep -qF 'Companion column shows no version newer than the baseline (v9.9.1)' <<<"$o"
! grep -qE '^[ +]<\?php$' <<<"$o" || { echo "FAIL: the diff printed an unchanged line" >&2; exit 1; }
grep -qF 'promoted v9.9.2' <<<"$o"; latest v9.9.2
o=$(term 9.9.2 v9.9.2 6.8.1); grep -qF 'v9.9.2 is already the latest release, signed by you: nothing to do' <<<"$o"
release v9.9.0 "$PUB1"; refuses 'v9.9.0 is not newer than v9.9.2' v9.9.0 6.8.1
echo "ok: the next promotion is reviewed against the last one; reruns and older tags change nothing"
LATESTMSG="GitHub's latest release is v9.9.2, but the newest release you promoted"
release v9.9.3 "$PUB1"
cp "$GHDIR/v9.9.2/owner.sig" "$T/sig"; cp "$GHDIR/v9.9.1/owner.sig" "$GHDIR/v9.9.2/owner.sig"
refuses "$LATESTMSG" v9.9.3 6.8.1 # a release editor's owner.sig
cp "$T/sig" "$GHDIR/v9.9.2/owner.sig"; cp "$(Z v9.9.2)" "$T/z"; cp "$(Z v9.9.1)" "$(Z v9.9.2)"
refuses "$LATESTMSG" v9.9.3 6.8.1 # a release editor's zip
cp "$T/z" "$(Z v9.9.2)"; SK=$SK3; refuses 'is not one you promoted' v9.9.3 6.8.1; SK=$SK1 # another key than the one that promoted it
mv "$GHDIR/v9.9.2/manifest.json" "$T/m"; echo v9.9.1 >"$GHDIR/latest" # v9.9.2 pulled behind this machine's back
refuses 'is not the last release this machine promoted' v9.9.3 6.8.1
mv "$T/m" "$GHDIR/v9.9.2/manifest.json"; echo v9.9.2 >"$GHDIR/latest"
echo "ok: the baseline is the release you promoted last, as you promoted it, and GitHub's latest"

# A key rotation: the release ships the new key; the manifest is signed with the old one, owner.sig with the new one.
release v9.9.3 "$PUB2"
refuses 'if a new key is intended' v9.9.3 6.8.1
NSK=$SK2; o=$(term 9.9.3 v9.9.3 6.8.1 --rotate) || { echo "$o"; exit 1; }; NSK=""
grep -qF "sites that take v9.9.3 trust only $PUB2" <<<"$o"; latest v9.9.3; owner_sig_by v9.9.3 "$PUB2"
[ "$(verify "$(cat "$GHDIR/v9.9.3/manifest.json")" "$(Z v9.9.2)")" = valid ] # sites on v9.9.2 take it
echo "ok: a rotation"
# The rotation release pulled (v9.9.2 latest again, v9.9.3 still signed); the next release serves the sites on v9.9.3.
echo v9.9.2 >"$GHDIR/latest"; SK=$SK2; release v9.9.4 "$PUB2"
refuses "$LATESTMSG" v9.9.4 6.8.1
mv "$GHDIR/v9.9.3/manifest.json" "$T/m"; refuses 'no release proves a rotation' v9.9.4 6.8.1 --baseline-key "$PUB1"
mv "$T/m" "$GHDIR/v9.9.3/manifest.json"
o=$(term 9.9.4 v9.9.4 6.8.1 --baseline-key "$PUB1") || { echo "$o"; exit 1; }
grep -qF 'the sites that took the rotation release v9.9.3 trust your key' <<<"$o"; grep -qF 'promoted v9.9.4' <<<"$o"
[ "$(verify "$(cat "$GHDIR/v9.9.4/manifest.json")" "$(Z v9.9.3)")" = valid ]   # manifest: the new key, for sites on v9.9.3
[ "$(verify "$(cat "$GHDIR/v9.9.4/manifest.json")" "$(Z v9.9.2)")" = invalid ] # not the old key
owner_sig_by v9.9.4 "$PUB2"
echo "ok: a pulled rotation release: --baseline-key with the rotation release as proof, signed with the new key"
release v9.9.5 "$PUB2"; o=$(term 9.9.5 v9.9.5 6.8.1) || { echo "$o"; exit 1; }; grep -qF 'promoted v9.9.5' <<<"$o"
# Interrupted after the upload (marking it latest failed): a rerun finishes it.
release v9.9.6 "$PUB2"
o=$(GH_FAIL_EDIT=1 term 9.9.6 v9.9.6 6.8.1) && { echo "$o"; exit 1; }; latest v9.9.5; [ -e "$GHDIR/v9.9.6/owner.sig" ]
o=$(term 9.9.6 v9.9.6 6.8.1) || { echo "$o"; exit 1; }; grep -qF 'promoted v9.9.6' <<<"$o"; latest v9.9.6; owner_sig_by v9.9.6 "$PUB2"
echo "ok: an interrupted promotion is finished by a rerun"
# Marked latest without a manifest: not "nothing to do", it is promoted.
release v9.9.7 "$PUB2"; echo v9.9.7 >"$GHDIR/latest"
o=$(term 9.9.7 v9.9.7 6.8.1) || { echo "$o"; exit 1; }; grep -qF 'promoted v9.9.7' <<<"$o"; owner_sig_by v9.9.7 "$PUB2"
echo "ok: a latest release with no manifest is promoted, not skipped"
echo "promote: all checks passed"
