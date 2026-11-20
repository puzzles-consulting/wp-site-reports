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
  "release upload") # release upload <tag> <file>... --clobber
    tag=$3; shift 3; for f in "$@"; do [ "$f" = --clobber ] || cp "$f" "$GHDIR/$tag/"; done ;;
  "release edit") # release edit <tag> --prerelease=false --latest | --prerelease (GitHub's latest falls back)
    [ -z "${GH_FAIL_EDIT:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
    if [ "$4" = --prerelease ]; then
      touch "$GHDIR/$3/.pre"
      if [ "$(cat "$GHDIR/latest" 2>/dev/null)" = "$3" ]; then
        n=$(for d in "$GHDIR"/v*/; do [ -e "$d.pre" ] || basename "$d"; done | sort -V | tail -1)
        if [ -n "$n" ]; then printf '%s\n' "$n" >"$GHDIR/latest"; else : >"$GHDIR/latest"; fi
      fi
    else rm -f "$GHDIR/$3/.pre"; printf '%s\n' "$3" >"$GHDIR/latest"; fi ;;
  "release delete-asset") rm "$GHDIR/$3/$4" ;; # release delete-asset <tag> <asset> --yes
  "release view") # release view <tag> --json assets --jq <the names | one asset's API URL>
    case "$*" in
      *apiUrl*) # an asset's id: its tag's digits, 0, and 1 (the zip), 2 (manifest.json) or 3 (owner.sig)
        for k in 1:puzzles-site-reports.zip 2:manifest.json 3:owner.sig; do
          [[ "$*" != *"\"${k#*:}\""* ]] || [ ! -e "$GHDIR/$3/${k#*:}" ] \
            || echo "https://api.github.com/repos/puzzles-consulting/wp-site-reports/releases/assets/$(tr -cd 0-9 <<<"$3")0${k%%:*}"
        done ;;
      *) ls "$GHDIR/$3" ;;
    esac ;;
  "api repos/puzzles-consulting/wp-site-reports/releases/assets/"*) # an asset's bytes
    [ -z "${GH_FAIL_ASSET:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
    id=${2##*/}; a=$(sed -n "${id: -1}p" <<<$'puzzles-site-reports.zip\nmanifest.json\nowner.sig')
    for d in "$GHDIR"/v*/; do [ "$(basename "$d" | tr -cd 0-9)" != "${id%??}" ] || exec cat "$d/$a"; done
    exit 1 ;;
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
# zpatch.py <zip> <how>: one layout fault in an otherwise build.sh zip. local-deflate: the first local header claims
# deflate behind a central "stor"; overlap: the second central entry points at the first entry; gap: four bytes
# between the entries and the central directory; crc: a data byte changed; eocd: the end record's count on this disk
# differs; central: the first central signature broken.
cat >"$T/zpatch.py" <<'EOF'
import struct, sys
path, how = sys.argv[1:3]
d = bytearray(open(path, 'rb').read())
cdoff = struct.unpack('<I', d[-6:-2])[0]
if how == 'local-deflate':
    struct.pack_into('<H', d, 8, 8)
elif how == 'overlap':
    nl, xl, ml = struct.unpack('<HHH', d[cdoff + 28:cdoff + 34])
    struct.pack_into('<I', d, cdoff + 46 + nl + xl + ml + 42, 0)
elif how == 'gap':
    d[cdoff:cdoff] = b'\0\0\0\0'
    struct.pack_into('<I', d, len(d) - 6, cdoff + 4)
elif how == 'crc':
    nl = struct.unpack('<H', d[26:28])[0]
    d[30 + nl] ^= 1
elif how == 'eocd':
    struct.pack_into('<H', d, len(d) - 14, struct.unpack('<H', d[-14:-12])[0] + 1)
elif how == 'central':
    d[cdoff] = 0
open(path, 'wb').write(bytes(d))
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
  mkdir -p "$GHDIR/$1"; cp "$T/b/puzzles-site-reports.zip" "$GHDIR/$1/"; touch "$GHDIR/$1/.pre"; rm -f "$GHDIR/$1/manifest.json" "$GHDIR/$1/owner.sig"
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
refuses 'usage: wp-sr-promote' v9.9.01 6.8.1 --first # a leading zero: sort -V and PHP's version_compare would disagree
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
# Two central directories (Info-ZIP reads the shown files, WordPress' PclZip would install the hidden ones): refused at
# the end record, which build.sh never follows with a comment.
hidden() { echo '// hidden: installed, never reviewed' >>"$T/src/includes/seo.php"; }
release v9.9.1 "$PUB1" hidden; cp "$(Z v9.9.1)" "$T/hidden.zip"
"$PY" -I "$T/dualzip.py" "$T/v9.9.1.zip" "$T/hidden.zip" "$(Z v9.9.1)"
[ "$(unzip -p "$(Z v9.9.1)" puzzles-site-reports/includes/seo.php | grep -c hidden || true)" = 0 ] # Info-ZIP shows the clean files
refuses 'does not end in an end record without a comment' v9.9.1 6.8.1 --first
zcase() { fresh; "$PY" -I "$T/zpatch.py" "$(Z v9.9.1)" "$2"; refuses "$1" v9.9.1 6.8.1 --first; } # zcase <expected> <how>
zcase 'has a local header that differs from its central entry' local-deflate
zcase 'are not one after another from its start' overlap
zcase 'has bytes outside its entries and central directory' gap
zcase 'fails its CRC' crc
zcase 'has an end record that does not match its central directory' eocd
zcase 'has a broken central directory' central
zipcase 'has a name with a byte that is not printable ASCII' add $'puzzles-site-reports/a\nb.php'
zipcase 'has a name with a byte that is not printable ASCII' add $'puzzles-site-reports/a\rb.php'
zipcase 'has a name with a byte that is not printable ASCII' add $'puzzles-site-reports/caf\xc3\xa9.php'
fresh; head -c $((5242880 + 1)) /dev/zero >>"$(Z v9.9.1)"; refuses 'is missing or over 5242880 bytes' v9.9.1 6.8.1 --first
fresh; "$PY" -I -c '
import sys, zipfile
i = zipfile.ZipInfo("puzzles-site-reports/big.txt"); i.create_system = 3; i.external_attr = 0o100644 << 16
i.compress_type = zipfile.ZIP_DEFLATED
zipfile.ZipFile(sys.argv[1], "a").writestr(i, "x" * 6000000)' "$(Z v9.9.1)"
refuses 'has a compressed entry' v9.9.1 6.8.1 --first # 6 MB that deflate to a few KB
release v9.9.1 "$PUB2"; refuses 'if a new key is intended' v9.9.1 6.8.1 --first # another key, without --rotate
release v9.9.2 "$PUB1"; cp "$(Z v9.9.2)" "$(Z v9.9.1)"; refuses "' * Version: 9.9.1'" v9.9.1 6.8.1 --first # another version's zip
fresh; refuses 'never from a pipe or a file' v9.9.1 6.8.1 --first # every check passes: no terminal
[ ! -e "$GHDIR/latest" ]; [ ! -e "$GHDIR/v9.9.1/manifest.json" ]; [ ! -e "$XDG_CONFIG_HOME" ]
echo "ok: nothing was signed, uploaded or noted"
mkdir -p "$XDG_CONFIG_HOME/wp-sr-promote"; echo "9.9.0 $(printf x | sha256sum | cut -c1-64)" >"$XDG_CONFIG_HOME/wp-sr-promote/promoted"
refuses '--first, but this machine promoted 9.9.0' v9.9.1 6.8.1 --first # its release is gone from GitHub
rm -r "$XDG_CONFIG_HOME"

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
sign() { # sign <tag> <secret key>: a manifest and owner.sig for <tag>'s zip as it is now, both by that key
  local sha m sig
  sha=$(sha256sum "$(Z "$1")" | cut -c1-64); m="${1#v}"$'\n'"$sha"$'\n5.8\n7.4\n6.8.1'
  sig=$(printf '%s\n%s' "$2" "$m" | php_run -r '$k = base64_decode( trim( fgets( STDIN ) ) ); echo base64_encode( sodium_crypto_sign_detached( stream_get_contents( STDIN ), $k ) );' | tr -d '\r')
  printf '{"version":"%s","sha256":"%s","requires":"5.8","requires_php":"7.4","tested":"6.8.1","signature":"%s"}\n' "${1#v}" "$sha" "$sig" >"$GHDIR/$1/manifest.json"
  printf '%s\n' "$sig" >"$GHDIR/$1/owner.sig"
}
snap() { rm -rf "$T/snap"; mkdir "$T/snap"; cp -r "$GHDIR" "$XDG_CONFIG_HOME" "$T/snap/"; }   # the releases and the notes, saved
back() { rm -rf "$GHDIR" "$XDG_CONFIG_HOME"; mv "$T/snap/gh" "$GHDIR"; mv "$T/snap/cfg" "$XDG_CONFIG_HOME"; } # and restored
NOTEF="$XDG_CONFIG_HOME/wp-sr-promote/promoted"; PULLEDF="$XDG_CONFIG_HOME/wp-sr-promote/pulled"
pull() { PATH="$T/bin:$PATH" bash "$P" pull "$@" 2>&1; } # pull <args...>: the subcommand, no key in sight
o=$(term 9.9.0 v9.9.1 6.8.1 --first) && { echo "$o"; exit 1; }
grep -qF 'not confirmed' <<<"$o"; [ ! -e "$GHDIR/latest" ]; [ ! -e "$GHDIR/v9.9.1/owner.sig" ]
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
snap; o=$(pull v9.9.1); grep -qF 'pulled v9.9.1' <<<"$o"; [ ! -s "$GHDIR/latest" ] # a bad first release, pulled
release v9.9.2 "$PUB1"; o=$(term 9.9.2 v9.9.2 6.8.1 --first) || { echo "$o"; exit 1; }
grep -qF 'baseline: none (--first)' <<<"$o"; grep -qF 'promoted v9.9.2' <<<"$o"; back
echo "ok: after the only release is pulled, the next one is promoted with --first"
marker() { echo '// marker: a change' >>"$T/src/includes/seo.php"; }
release v9.9.2 "$PUB1" marker
mv "$NOTEF" "$T/note"; o=$(term 9.9.2 v9.9.2 6.8.1) || { echo "$o"; exit 1; }; cat "$T/note" "$NOTEF" >"$T/n"; mv "$T/n" "$NOTEF"
grep -qF "baseline: v9.9.1 (owner.sig verified, GitHub's latest); baseline taken from GitHub only" <<<"$o"
grep -qxF '+// marker: a change' <<<"$o"; grep -qF 'Companion column shows no version newer than v9.9.1, what the sites' <<<"$o"
! grep -qE '^[ +]<\?php$' <<<"$o" || { echo "FAIL: the diff printed an unchanged line" >&2; exit 1; }
grep -qF 'promoted v9.9.2' <<<"$o"; latest v9.9.2
o=$(term 9.9.2 v9.9.2 6.8.1); grep -qF 'v9.9.2 is already the latest release, signed by you: nothing to do' <<<"$o"
release v9.9.0 "$PUB1"; refuses 'v9.9.0 is not newer than v9.9.2' v9.9.0 6.8.1
echo "ok: the next promotion is reviewed against the last one; reruns and older tags change nothing"
release v9.9.3 "$PUB1"
cp "$(Z v9.9.2)" "$T/z"; cp "$(Z v9.9.1)" "$(Z v9.9.2)" # a release editor's zip: v9.9.2 no longer counts as promoted
refuses "GitHub's latest release is v9.9.2, but the newest release you promoted (owner.sig by $PUB1) is v9.9.1" v9.9.3 6.8.1
cp "$T/z" "$(Z v9.9.2)"; SK=$SK3; refuses 'is not one you promoted' v9.9.3 6.8.1; SK=$SK1 # owner.sigs by another key
# Valid content past the caps (1024 bytes of manifest.json, 200 of owner.sig): only the caps make v9.9.2 not count.
for a in manifest.json owner.sig; do
  cp "$GHDIR/v9.9.2/$a" "$T/a"; head -c 1100 /dev/zero | tr '\0' '\n' >>"$GHDIR/v9.9.2/$a"
  refuses "GitHub's latest release is v9.9.2, but the newest release you promoted (owner.sig by $PUB1) is v9.9.1" v9.9.3 6.8.1
  cp "$T/a" "$GHDIR/v9.9.2/$a"
done
cp "$NOTEF" "$T/note"; sed -i "s/^9\.9\.2 .*/9.9.2 $(printf x | sha256sum | cut -c1-64)/" "$NOTEF" # another v9.9.2 here
refuses 'is not the zip this machine promoted as v9.9.2' v9.9.3 6.8.1
cp "$T/note" "$NOTEF"; mv "$GHDIR/v9.9.2/manifest.json" "$T/m"; echo v9.9.1 >"$GHDIR/latest" # pulled behind its back
refuses 'is below 9.9.2, the highest release this machine promoted and did not pull' v9.9.3 6.8.1
mv "$T/m" "$GHDIR/v9.9.2/manifest.json"; echo v9.9.2 >"$GHDIR/latest"
snap; zedit add v9.9.2 'puzzles-site-reports/../evil.txt'; sign v9.9.2 "$SK1" # a baseline the owner signed, with a hostile name
refuses "v9.9.2's zip has the entry 'puzzles-site-reports/../evil.txt'" v9.9.3 6.8.1; back
snap; o=$(term 9.9.3 v9.9.3 6.8.1) || { echo "$o"; exit 1; } # 9.9.1-9.9.3 promoted; 9.9.3 pulled; 9.9.2 hidden by an editor
pull v9.9.3 >/dev/null; latest v9.9.2; mv "$GHDIR/v9.9.2/manifest.json" "$T/m"; echo v9.9.1 >"$GHDIR/latest"
release v9.9.4 "$PUB1"; refuses 'is below 9.9.2, the highest release this machine promoted and did not pull' v9.9.4 6.8.1
back; release v9.9.3 "$PUB1"
echo "ok: the baseline is the release you promoted last, as you promoted it, and GitHub's latest"

# Pulled: pre-release, no manifest, noted here; the next release rolls forward from the one before it.
mkdir "$T/nophp"; printf '#!/bin/sh\nexit 127\n' >"$T/nophp/php"; cp "$T/nophp/php" "$T/nophp/docker"; chmod +x "$T/nophp/"*
o=$(PATH="$T/nophp:$T/bin:$PATH" bash "$P" pull v9.9.2 2>&1) && { echo "$o"; exit 1; }
grep -qF 'v9.9.2 is pre-release now, but telling whether it is a rotation release needs php or Docker' <<<"$o"
[ -e "$GHDIR/v9.9.2/.pre" ]; [ -e "$GHDIR/v9.9.2/manifest.json" ]; latest v9.9.1; grep -qx 9.9.2 "$PULLEDF"
o=$(pull v9.9.2); grep -qF 'pulled v9.9.2' <<<"$o"
[ -e "$GHDIR/v9.9.2/.pre" ]; [ ! -e "$GHDIR/v9.9.2/manifest.json" ]; latest v9.9.1; grep -qx 9.9.2 "$PULLEDF"
o=$(term 9.9.3 v9.9.3 6.8.1) || { echo "$o"; exit 1; }
grep -qF 'baseline: v9.9.1 (' <<<"$o"; grep -qF 'promoted v9.9.3' <<<"$o"; latest v9.9.3; [ "$(tail -1 "$NOTEF" | cut -d' ' -f1)" = 9.9.3 ]
grep -qF 'or than a release this machine pulled: 9.9.2.' <<<"$o"
snap; pull v9.9.3 >/dev/null; refuses 'v9.9.2 is not newer than 9.9.3, which this machine pulled' v9.9.2 6.8.1; back
echo "ok: a pull, then the next release rolls forward from the release before it"

# A key rotation: the release ships the new key; the manifest is signed with the old one, owner.sig with the new one.
release v9.9.4 "$PUB2"
refuses 'if a new key is intended' v9.9.4 6.8.1
NSK=$SK2; o=$(term 9.9.4 v9.9.4 6.8.1 --rotate) || { echo "$o"; exit 1; }; NSK=""
grep -qF "sites that take v9.9.4 trust only $PUB2" <<<"$o"; latest v9.9.4; owner_sig_by v9.9.4 "$PUB2"
[ "$(verify "$(cat "$GHDIR/v9.9.4/manifest.json")" "$(Z v9.9.3)")" = valid ] # sites on v9.9.3 take it
echo "ok: a rotation"
snap; pull v9.9.4 --delete-manifest >/dev/null; [ ! -e "$GHDIR/v9.9.4/manifest.json" ]; back # its manifest goes on request
snap; cp "$GHDIR/v9.9.3/owner.sig" "$GHDIR/v9.9.4/owner.sig"; pull v9.9.4 >/dev/null # owner.sig not by the key it ships
[ ! -e "$GHDIR/v9.9.4/manifest.json" ]; back
snap; o=$(GH_FAIL_ASSET=1 pull v9.9.4) && { echo "$o"; exit 1; }; grep -qF "could not download v9.9.4's puzzles-site-reports.zip" <<<"$o"; back
echo "ok: pull keeps a manifest only for a rotation release it can prove, and fails loudly when it cannot read one"
# Pulled by mistake: its manifest stays, and promoting it again (--rotate) puts it back.
o=$(pull v9.9.4); grep -qF 'v9.9.4 is a rotation release: its manifest.json stays' <<<"$o"
[ -e "$GHDIR/v9.9.4/manifest.json" ]; latest v9.9.3
NSK=$SK2; o=$(term 9.9.4 v9.9.4 6.8.1 --rotate) || { echo "$o"; exit 1; }; NSK=""
grep -qF 'baseline: v9.9.3 (' <<<"$o"; grep -qF 'promoted v9.9.4' <<<"$o"; latest v9.9.4
if grep -qx 9.9.4 "$PULLEDF"; then echo "FAIL: v9.9.4 still noted as pulled" >&2; exit 1; fi
echo "ok: a rotation release pulled by mistake is promoted again"
# Pulled for good: one manifest serves one group of sites. Both choices, from the same state.
pull v9.9.4 >/dev/null
snap
release v9.9.5 "$PUB1"; o=$(term 9.9.5 v9.9.5 6.8.1) || { echo "$o"; exit 1; } # the sites on v9.9.3: the old key, as usual
grep -qF 'baseline: v9.9.3 (' <<<"$o"; grep -qF 'promoted v9.9.5' <<<"$o"; owner_sig_by v9.9.5 "$PUB1"
[ "$(verify "$(cat "$GHDIR/v9.9.5/manifest.json")" "$(Z v9.9.3)")" = valid ]
echo "ok: after a pulled rotation, the sites on the old key get a fix as usual"
back
SK=$SK2; release v9.9.5 "$PUB2" # the sites on v9.9.4: the new key, with v9.9.4 still signed as proof
refuses 'v9.9.4, was pulled on this machine, yet it is still signed' v9.9.5 6.8.1
mv "$GHDIR/v9.9.4/manifest.json" "$T/m"; refuses 'no release you promoted with your key' v9.9.5 6.8.1 --baseline-key "$PUB1"
mv "$T/m" "$GHDIR/v9.9.4/manifest.json"
o=$(term 9.9.5 v9.9.5 6.8.1 --baseline-key "$PUB1") || { echo "$o"; exit 1; }
grep -qF 'the sites that took the rotation release v9.9.4 trust your key' <<<"$o"; grep -qF 'promoted v9.9.5' <<<"$o"
grep -qF 'Companion column shows no version newer than v9.9.4' <<<"$o"
[ "$(verify "$(cat "$GHDIR/v9.9.5/manifest.json")" "$(Z v9.9.4)")" = valid ]   # manifest: the new key, for sites on v9.9.4
[ "$(verify "$(cat "$GHDIR/v9.9.5/manifest.json")" "$(Z v9.9.3)")" = invalid ] # not the old key
owner_sig_by v9.9.5 "$PUB2"
echo "ok: after a pulled rotation, the sites on the new key: --baseline-key, the rotation release as proof"
release v9.9.6 "$PUB2"; echo v9.9.3 >"$GHDIR/latest" # the newest release with the new key is no longer the rotation
refuses 'v9.9.5, is not a rotation from' v9.9.6 6.8.1 --baseline-key "$PUB1"
echo v9.9.5 >"$GHDIR/latest"
# Interrupted after the upload (marking it latest failed): a rerun finishes it.
o=$(GH_FAIL_EDIT=1 term 9.9.6 v9.9.6 6.8.1) && { echo "$o"; exit 1; }; latest v9.9.5; [ -e "$GHDIR/v9.9.6/owner.sig" ]
o=$(term 9.9.6 v9.9.6 6.8.1) || { echo "$o"; exit 1; }; grep -qF 'promoted v9.9.6' <<<"$o"; latest v9.9.6; owner_sig_by v9.9.6 "$PUB2"
echo "ok: an interrupted promotion is finished by a rerun"
# Marked latest without a manifest: not "nothing to do", it is promoted.
release v9.9.7 "$PUB2"; echo v9.9.7 >"$GHDIR/latest"
o=$(term 9.9.7 v9.9.7 6.8.1) || { echo "$o"; exit 1; }; grep -qF 'promoted v9.9.7' <<<"$o"; owner_sig_by v9.9.7 "$PUB2"
echo "ok: a latest release with no manifest is promoted, not skipped"
echo "promote: all checks passed"
