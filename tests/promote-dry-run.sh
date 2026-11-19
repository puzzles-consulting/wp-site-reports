#!/usr/bin/env bash
# Offline check of the promoter, scripts/wp-sr-promote (this worktree's copy, "installed" outside the clones it works
# on), against the trees of the committed HEAD. A local bare repository is `origin`; a "dev" clone pushes tagged commits
# (each carrying a throwaway public key) and builds their release zips as CI does, with HEAD's scripts/build.sh; the
# "owner" clone stays on HEAD (only real keys in its history), runs dry runs, types the version on stdin and keeps the
# dry-run record (refs/puzzles-sr/dry-run/). Section 9 runs the real path in "real" clones against a gh shim that
# serves releases from a directory, on a terminal made by script(1) (skipped where script(1) is missing: Git Bash; CI
# runs it). Throwaway keys only (wp-sr-promote keygen). Everything is written under one temp dir.
# Needs php or Docker, python, unzip. CI runs it (.github/workflows/ci.yml).
# Usage: bash tests/promote-dry-run.sh
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git -C "$T/origin.git" fetch -q "$REPO" HEAD:refs/heads/main # fetch: nothing of $REPO's (hooks) runs
git clone -q -b main "$T/origin.git" "$T/owner"
git clone -q -b main "$T/origin.git" "$T/dev"
cp "$REPO/scripts/wp-sr-promote" "$T/wp-sr-promote" # the owner's installed copy (README, Release)
cp "$T/dev/scripts/build.sh" "$T/ci-build.sh"       # CI's builder, as of HEAD: the release zips come from it
cd "$T/dev"
g() { git -c user.name=test -c user.email=test@example.com "$@"; }
PHP_IMAGE=$(sed -n 's/^PHP_IMAGE=\([^ ]*\).*/\1/p' "$T/wp-sr-promote") # the promoter's pinned image
php_run() { # the verifier below runs the plugin's own PHP
  if command -v php >/dev/null; then php "$@"; return; fi
  MSYS_NO_PATHCONV=1 docker run -i --rm --network none "$PHP_IMAGE" php "$@"
}

# Throwaway keypairs from the promoter itself: public keys in PUBn, secret keys in SKn.
for i in 1 2 3; do printf -v "PUB$i" %s "$(bash "$T/wp-sr-promote" keygen 3>"$T/sk$i")"; printf -v "SK$i" %s "$(cat "$T/sk$i")"; done
[[ $PUB1 =~ ^[A-Za-z0-9+/]{43}=$ && ${#SK1} -eq 88 && -n $PUB2 && -n $SK2 && -n $SK3 ]] || { echo "FAIL: keygen" >&2; exit 1; }
o=$(bash "$T/wp-sr-promote" keygen 2>&1) && exit 1; grep -qF 'open file descriptor 3' <<<"$o"
echo "ok: keygen: public key on stdout, secret key on fd 3 only"
# On runs that sign, the promoter's children must never see a key: these shims fail the run if one inherits it, under
# the variables' own names or the names the promoter keeps them in (promote() exports those, as an owner's shell might).
mkdir "$T/bin" "$T/ghbin" "$T/tmp" "$T/gh"
NOKEY='[ -z "${PUZZLES_SR_SIGNING_KEY+x}${PUZZLES_SR_NEW_SIGNING_KEY+x}${PUZZLES_SR_DRY_RUN_KEY+x}${PUZZLES_SR_DRY_RUN_NEW_KEY+x}${KEY+x}${NEWKEY+x}${DKEY+x}${DNEWKEY+x}${KP+x}" ]'
for c in git unzip python3 python docker php realpath; do
  r=$(command -v "$c") || continue
  printf '#!/usr/bin/env bash\n%s || { echo "LEAK: %s got a key" >&2; exit 99; }\nexec "%s" "$@"\n' "$NOKEY" "$c" "$r" >"$T/bin/$c"
  chmod +x "$T/bin/$c"
done
# gh, on every run: GitHub's releases as a directory, $GHDIR/<tag>/<asset> and $GHDIR/latest; calls logged in $GHDIR/calls.
export GHDIR="$T/gh"
printf '#!/usr/bin/env bash\n%s || { echo "LEAK: gh got a key" >&2; exit 99; }\n' "$NOKEY" >"$T/ghbin/gh"
cat >>"$T/ghbin/gh" <<'EOF'
echo "$*" >>"$GHDIR/calls"
case "$1 $2" in
  "api repos/puzzles-consulting/wp-site-reports/releases/latest")
    [ -s "$GHDIR/latest" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    cat "$GHDIR/latest" ;;
  "release download") # release download <tag> (--pattern <asset>)... --dir <dir>
    tag=$3; shift 3; pats=(); dir=.
    while [ $# -gt 0 ]; do case "$1" in --pattern) pats+=("$2"); shift 2 ;; --dir) dir=$2; shift 2 ;; *) shift ;; esac; done
    for p in "${pats[@]}"; do [ ! -e "$GHDIR/$tag/$p" ] || cp "$GHDIR/$tag/$p" "$dir/"; done ;;
  "release upload") cp "$4" "$GHDIR/$3/" ;;              # release upload <tag> <file> --clobber
  "release edit") printf '%s\n' "$3" >"$GHDIR/latest" ;; # release edit <tag> --prerelease=false --latest
  *) echo "gh shim: unexpected call: $*" >&2; exit 97 ;;
esac
EOF
chmod +x "$T/ghbin/gh"
# The promoter's temp dirs go under $T/tmp: a file that escaped the staging directory lands there.
d=$(TMPDIR="$T/tmp" mktemp -d); [[ $d == "$T/tmp/"* ]] || { echo "FAIL: mktemp ignores TMPDIR" >&2; exit 1; }; rmdir "$d"
nothing_escaped() { [ -z "$(ls -A "$T/tmp")" ] || { ls -laR "$T/tmp" >&2; echo "FAIL: a file escaped the staging directory" >&2; exit 1; }; }

tag() { # tag <tag> [commit]: tags and pushes it; the owner's tags follow origin's (a moved tag fails: not called then)
  g tag -a "$1" -m "$1" ${2:-}; git push -q origin "$1"; git -C "$T/owner" fetch -q --tags origin
}
CI_BUILD="$T/ci-build.sh"
zip_of() { bash "$CI_BUILD" "${1#v}" --src . --out "$T/build-$1" >/dev/null; cp "$T/build-$1/puzzles-site-reports.zip" "$T/$1.zip"; } # as CI does
release() { # release <tag> <pubkey>: a commit on main carrying that key, tagged; its zip is $T/<tag>.zip
  sed -i "s|^define( 'PUZZLES_SR_UPDATE_PUBKEY', '[^']*' );|define( 'PUZZLES_SR_UPDATE_PUBKEY', '$2' );|" puzzles-site-reports.php
  grep -qF "'PUZZLES_SR_UPDATE_PUBKEY', '$2'" puzzles-site-reports.php
  g commit -q --allow-empty -am "test: $1"; git push -q origin HEAD:main; tag "$1"; zip_of "$1"
}
back_to() { g reset -q --hard "$1"; git push -q -f origin HEAD:main; } # main drops the refused commits
sha_of() { sha256sum "$1" | cut -c1-64; }
blob() { printf '%s %s\n' "$2" "$3" | git -C "$1" hash-object -w --stdin; } # blob <clone> <commit> <sha256>: a record
records() { # records <tag>...: the owner's dry-run record holds exactly these promotions, each with its zip's sha256
  git -C "$T/owner" for-each-ref --format='delete %(refname)' refs/puzzles-sr | git -C "$T/owner" update-ref --stdin
  local t; for t in "$@"; do
    git -C "$T/owner" update-ref "refs/puzzles-sr/dry-run/promoted/$t" "$(blob "$T/owner" "$(git rev-parse "$t^{commit}")" "$(sha_of "$T/$t.zip")")"
  done
}
SK=$SK1; NSK=""; ANS=""; OWNED="$T/owner"; PROMOTER="$T/wp-sr-promote"; SHIMS="$T/bin:"
promote() { # promote <tag> <zip> [options]: a dry run in $OWNED, signing with $SK (and $NSK as the new key); types $ANS,
  local tag=$1 zip=$2; shift 2 # else the tag's version
  PATH="$SHIMS$T/ghbin:$PATH" TMPDIR="$T/tmp" PUZZLES_SR_DRY_RUN_KEY="$SK" PUZZLES_SR_DRY_RUN_NEW_KEY="$NSK" \
    KEY=exported NEWKEY=exported DKEY=exported DNEWKEY=exported KP=exported \
    bash "$PROMOTER" --repo "$OWNED" "$tag" 6.8.1 --dry-run "$zip" "$@" <<<"${ANS:-${tag#v}}"
}
refuses() { # refuses <expected message> <promote args...>: no key-leak shims (no signature is made)
  local want=$1 SHIMS=""; shift
  if promote "$@" >"$T/out" 2>&1; then cat "$T/out"; echo "FAIL: expected a refusal ($want)" >&2; exit 1; fi
  grep -qF -- "$want" "$T/out" || { cat "$T/out"; echo "FAIL: expected '$want'" >&2; exit 1; }
  echo "ok: refused: $want"
}
# verify <manifest> <zip>: the zip's own plugin file checks the manifest (puzzles_sr_verified_manifest). Coupled to the
# main file: the stubs are the WordPress functions it calls while it loads, and its require_once lines are dropped.
verify() {
  { printf '<?php define( "ABSPATH", "/" ); function add_filter() {} function add_action() {} function register_deactivation_hook() {} ?>'
    unzip -p "$2" puzzles-site-reports/puzzles-site-reports.php | grep -v '^require_once __DIR__'
    printf '\necho null === puzzles_sr_verified_manifest( base64_decode( $argv[1] ) ) ? "invalid" : "valid";\n'
  } | php_run -- "$(printf '%s' "$1" | base64 | tr -d '\n')" | tr -d '\r'
}

# 1. The first promotion in a clone shows everything as new; the next one (its main file and an include each gain a
# marker line) shows both lines against the record of the first. Every dry run that signs proves the promoter's own
# build is byte for byte CI's: it refuses a release zip with any other sha256 (section 2).
release v9.9.7 "$PUB1"
m=$(promote v9.9.7 "$T/v9.9.7.zip" 2>"$T/err"); grep -qF 'checks are skipped' "$T/err"
grep -qF 'baseline: none: the first promotion recorded in this clone: everything is new' "$T/err"
grep -qF "v9.9.7 is commit $(git rev-parse 'v9.9.7^{commit}')" "$T/err"
[ "$(verify "$m" "$T/v9.9.7.zip")" = valid ]
echo '// marker: main' >>puzzles-site-reports.php; echo '// marker: include' >>includes/seo.php
release v9.9.8 "$PUB1"
m=$(promote v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip" 2>"$T/err")
echo "$m"
grep -qF 'baseline: v9.9.7, your last promotion recorded in this clone' "$T/err"
grep -qxF '+// marker: main' "$T/err"; grep -qxF '+// marker: include' "$T/err"
grep -qF '"requires":"5.8","requires_php":"7.4","tested":"6.8.1"' <<<"$m"
[ "$(verify "$m" "$T/v9.9.8.zip")" = valid ]
[ "$(verify "${m/6.8.1/6.8.2}" "$T/v9.9.8.zip")" = invalid ] # the verifier really checks
[ "$(git -C "$T/owner" cat-file blob refs/puzzles-sr/dry-run/promoted/v9.9.8)" = "$(git rev-parse 'v9.9.8^{commit}') $(sha_of "$T/v9.9.8.zip")" ]
[ -z "$(git -C "$T/owner" for-each-ref refs/puzzles-sr/promoted)" ] # a dry run never writes the real record
echo "ok: signed; the plugin's own verifier accepts it; the record is the commit and the zip's sha256"
records v9.9.7 # from here on the owner last promoted v9.9.7, the --trusted-zip of most runs below

# 2. The release zip is not the promoter's build of the tag: one byte changed.
cp "$T/v9.9.8.zip" "$T/flip.zip"; printf '\377' | dd of="$T/flip.zip" bs=1 seek=100 conv=notrunc status=none
cmp -s "$T/v9.9.8.zip" "$T/flip.zip" && exit 1
refuses 'is not what this promoter builds from v9.9.8' v9.9.8 "$T/flip.zip" --trusted-zip "$T/v9.9.7.zip"

# 3. The tag's tree, one case per check: a symlink; bytes; attributes; version lines; what comes before the key define.
g update-index --add --cacheinfo "120000,$(printf x | git hash-object -w --stdin),includes/link.php"
g commit -q -m 'test: symlink'; git push -q origin HEAD:main; tag v9.9.9
refuses "has 'includes/link.php' with mode 120000" v9.9.9 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
back_to v9.9.8
odd() { # odd <tag> <expected refusal>: dev's worktree changes, committed and tagged, are refused
  g add -A; g commit -q -m "test: $1"; git push -q origin HEAD:main; tag "$1"
  refuses "$2" "$1" "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
  back_to v9.9.8
}
BYTE='has a byte other than TAB, LF and printable ASCII'
VLINE='needs exactly one version header line'
PRE='before its key define'
KEYDEF="/^define( 'PUZZLES_SR_UPDATE_PUBKEY'/"
printf '<?php /* \033[2K\r+// tidy */\n' >includes/evil.php; odd v9.9.50 "$BYTE" # erases its own line on a terminal
printf "<?php const PUZZLES_SR_UPDATE_\320\240UBKEY = 'x';\n" >includes/evil.php; odd v9.9.51 "$BYTE" # Cyrillic U+0420
# A CRLF file (staged as is: `git add` would turn it into LF): Git Bash's grep drops a CR before LF unless -U.
g update-index --add --cacheinfo "100644,$(printf '<?php\r\n' | git hash-object -w --stdin),includes/crlf.php"
g commit -q -m 'test: crlf'; git push -q origin HEAD:main; tag v9.9.76
refuses "'includes/crlf.php' $BYTE" v9.9.76 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"; back_to v9.9.8
printf "<?php define( 'X', 1 );\n" >>CHANGELOG.md; odd v9.9.19 "'CHANGELOG.md' is not PHP but holds a PHP open tag"
printf 'includes/seo.php filter=evil\n' >>.gitattributes; odd v9.9.56 "includes/seo.php': filter=evil"
sed -i '1a // Version: 6.6.6' puzzles-site-reports.php; odd v9.9.54 "$VLINE" # the line WordPress would read
printf "\$doc = \"define( 'PUZZLES_SITE_REPORTS_VERSION', 'x' );\";\n" >>puzzles-site-reports.php; odd v9.9.59 "$VLINE"
sed -i "s|^define( 'PUZZLES_SITE_REPORTS_OPTION'|define/**/( 'PUZZLES_SITE_REPORTS_OPTION'|" puzzles-site-reports.php; odd v9.9.45 "$PRE"
sed -i "${KEYDEF}i define( 'PUZZLES_SR_UPDATE_PUBKEY', 'x' );" puzzles-site-reports.php; odd v9.9.44 "$PRE" # the key's name
sed -i "s|^ \* Author: .*| * Author: x */ \$pzr = 1; /*|" puzzles-site-reports.php; odd v9.9.46 "$PRE" # comment closed mid-line
sed -i 's|^ \*/$| *|' puzzles-site-reports.php; odd v9.9.71 "'/**' $PRE"                          # a header never closed
sed -i '1s|.*|<?php echo 1;|' puzzles-site-reports.php; odd v9.9.72 "'<?php echo 1;' $PRE"         # first line
sed -i "s|^\texit;\$|\texit( print 1 );|" puzzles-site-reports.php; odd v9.9.73 "$PRE"           # the ABSPATH guard
sed -i "${KEYDEF}i // note ?> <?php \$pzr = 1;" puzzles-site-reports.php; odd v9.9.74 "$PRE"     # ?> in a // comment
sed -i "${KEYDEF}{s/^/function puzzles_sr_k() { /;s/\$/ }/}" puzzles-site-reports.php; odd v9.9.47 'needs its key on one top-level line'
graft() { # graft <tag> <dir> <name> [tree]: tags, on main, v9.9.8's tree plus a blob (with "tree": a subtree holding x)
  local e t # at <dir>/<name>, <dir> "." for the root
  e="100644 blob $(printf 'escaped\n' | git hash-object -w --stdin)"
  [ "${4:-}" != tree ] || e="040000 tree $(printf '%s\tx\0' "$e" | git mktree -z)"
  t=$(git rev-parse 'v9.9.8^{tree}')
  [ "$2" = . ] || { e="040000 tree $({ git ls-tree -z "$t:$2"; printf '%s\t%s\0' "$e" "$3"; } | git mktree -z)"; set -- "$1" . "$2"; }
  t=$({ git ls-tree -z "$t" | grep -zvF $'\t'"$3"; printf '%s\t%s\0' "$e" "$3"; } | git mktree -z)
  t=$(g commit-tree -p "$(git rev-parse 'v9.9.8^{commit}')" -m "test: $1" "$t")
  git push -q origin "$t:refs/heads/main"; tag "$1" "$t"
}
graft v9.9.43 . README.md tree; refuses "'README.md/x' is not a shipped file" v9.9.43 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
back_to v9.9.8
# A legitimate release still signs: its docs name the key, a const and the version define, and its .gitattributes would
# make `git archive` drop includes/seo.php (the export reads the raw tree). The diff omits an unchanged line.
printf 'Docs may say `PUZZLES_SR_UPDATE_PUBKEY`, a const, or define( %s, %s );\n' "'PUZZLES_SITE_REPORTS_VERSION'" "'1.0.0'" >>README.md
printf 'includes/seo.php export-ignore\n' >>.gitattributes; g add .gitattributes; release v9.9.58 "$PUB1"
promote v9.9.58 "$T/v9.9.58.zip" --trusted-zip "$T/v9.9.7.zip" >"$T/out" 2>&1 || { cat "$T/out"; exit 1; }
grep -qF '+Docs may say `PUZZLES_SR_UPDATE_PUBKEY`' "$T/out"
! grep -qE '^[ +]# Puzzles Site Reports$' "$T/out" || { echo "FAIL: the diff printed an unchanged line" >&2; exit 1; }
back_to v9.9.8; records v9.9.7
echo "ok: a release whose docs name the key signs; .gitattributes does not change the export; the diff is only the change"

# 3b. Entry names no checkout could write (git mktree). Git Bash takes `\` as a separator: on Windows the first would
# land outside the staging directory, in $T/tmp. Outside the allowlist it is ignored (the release signs); inside it,
# names are refused, as are names Windows would not write as they are.
graft v9.9.20 . '..\..\escaped'; zip_of v9.9.20
promote v9.9.20 "$T/v9.9.20.zip" --trusted-zip "$T/v9.9.7.zip" >"$T/out" 2>&1 || { cat "$T/out"; echo "FAIL: a name outside the allowlist was not ignored" >&2; exit 1; }
nothing_escaped; back_to v9.9.8; records v9.9.7
n=21
for c in '..\..\..\escaped|has the path' '.hidden|has the path' 'SEO.php|one name on Windows' 'x.php.|ending in' \
  'con.php|reserved device name'; do
  graft "v9.9.$n" includes "${c%|*}"
  refuses "${c#*|}" "v9.9.$n" "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
  nothing_escaped; back_to v9.9.8; n=$((n + 1))
done
echo "ok: hostile names ignored outside the allowlist, refused inside it; nothing escaped"

# 4. origin's tag points elsewhere (moved after the canary); a decoy tag whose name ends like it does not count; a tag
# that is not on main, also when a tag named main points at it.
git push -q -f origin "$(git rev-parse 'v9.9.7^{commit}'):refs/tags/v9.9.8"
refuses "origin's v9.9.8 is" v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
git push -q -f origin v9.9.8
git push -q origin "$(git rev-parse 'v9.9.7^{commit}'):refs/tags/x/refs/tags/v9.9.8"
promote v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip" >"$T/out" 2>&1 || { cat "$T/out"; exit 1; }
git push -q origin :refs/tags/x/refs/tags/v9.9.8; records v9.9.7
echo "ok: origin's tag is matched exactly"
g checkout -q -b side; g commit -q --allow-empty -m side; tag v9.9.12; g checkout -q main
git push -q origin "$(git rev-parse 'v9.9.12^{commit}'):refs/tags/main"
refuses 'is not on origin/main' v9.9.12 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
git push -q origin :refs/tags/main

# 5. GitHub's latest release (here --trusted-zip) against the owner's record: recorded, with the recorded sha256; its
# key is the one sites trust now. A bad release (v9.9.8) marked pre-release: v9.9.7 is latest again, recorded too; the
# baseline stays the highest record, and the next release must be newer than it.
release v9.9.60 "$PUB1"
records v9.9.7 v9.9.8
m=$(promote v9.9.60 "$T/v9.9.60.zip" --trusted-zip "$T/v9.9.7.zip" 2>"$T/err")
grep -qF 'baseline: v9.9.8, your last promotion recorded' "$T/err"; [ "$(verify "$m" "$T/v9.9.60.zip")" = valid ]
records v9.9.7 v9.9.60
refuses 'is not newer than your last promotion recorded in this clone (v9.9.60)' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
echo "ok: rolling forward past a bad release"
records
refuses 'v9.9.7, which this dry-run clone has not recorded' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
git -C "$T/owner" update-ref refs/puzzles-sr/dry-run/promoted/v9.9.7 "$(blob "$T/owner" "$(git rev-parse 'v9.9.7^{commit}')" "$(sha_of "$T/v9.9.8.zip")")"
refuses 'is not the zip you signed' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip" # the record's sha256 differs
release v9.9.13 "$PUB2"
records v9.9.8
refuses 'changes the release key' v9.9.13 "$T/v9.9.13.zip" --trusted-zip "$T/v9.9.8.zip"
NSK=$SK3; refuses 'is not the secret key of' v9.9.13 "$T/v9.9.13.zip" --trusted-zip "$T/v9.9.8.zip" --rotate
NSK=$SK2; m=$(promote v9.9.13 "$T/v9.9.13.zip" --trusted-zip "$T/v9.9.8.zip" --rotate 2>"$T/err"); NSK=""
grep -qF "sites trust only $PUB2" "$T/err"
[ "$(verify "$m" "$T/v9.9.8.zip")" = valid ]    # signed with the old key: sites on v9.9.8 take it...
[ "$(verify "$m" "$T/v9.9.13.zip")" = invalid ] # ...and not with the new one
echo "ok: --rotate signs with the old key"
refuses '--rotate needs the new secret key' v9.9.13 "$T/v9.9.13.zip" --trusted-zip "$T/v9.9.8.zip" --rotate
NSK=$SK2; refuses 'is set without --rotate' v9.9.13 "$T/v9.9.13.zip" --trusted-zip "$T/v9.9.8.zip"; NSK=""
records v9.9.7
SK=$SK2; refuses 'is not the one sites trust now' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"; SK=$SK1
refuses 'v9.9.8, which this dry-run clone has not recorded' v9.9.13 "$T/v9.9.13.zip" --trusted-zip "$T/v9.9.8.zip"
records v9.9.7 v9.9.8
refuses 'is not newer than the latest release (9.9.8)' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.8.zip"
records v9.9.7 v9.9.13
refuses 'is not the release your record expects' v9.9.60 "$T/v9.9.60.zip" --trusted-zip "$T/v9.9.7.zip" # v9.9.13 pulled
# A release that changes the zip's format (build.sh and the re-installed promoter alike) promotes: no record is rebuilt.
TIP=$(git rev-parse HEAD)
sed -i 's/(1980, 1, 1, 0, 0, 0)/(1981, 1, 1, 0, 0, 0)/' scripts/build.sh
sed 's/(1980, 1, 1, 0, 0, 0)/(1981, 1, 1, 0, 0, 0)/' "$T/wp-sr-promote" >"$T/promoter-1981"; cp scripts/build.sh "$T/ci-1981.sh"
CI_BUILD="$T/ci-1981.sh"; release v9.9.75 "$PUB1"; CI_BUILD="$T/ci-build.sh"
records v9.9.7
refuses 'is not what this promoter builds from v9.9.75' v9.9.75 "$T/v9.9.75.zip" --trusted-zip "$T/v9.9.7.zip" # it did change
PROMOTER="$T/promoter-1981"; m=$(promote v9.9.75 "$T/v9.9.75.zip" --trusted-zip "$T/v9.9.7.zip" 2>"$T/err"); PROMOTER="$T/wp-sr-promote"
[ "$(verify "$m" "$T/v9.9.75.zip")" = valid ]
back_to "$TIP"; records v9.9.7
echo "ok: a zip-format change promotes with the re-installed promoter"

# 6. A dry run refuses any key in the clone's HEAD history: here the owner's checkout is one whose history carries PUB1.
# With color.ui=always `git log -p` is coloured: the keys are read from each commit's file; the printed diff stays plain.
git -C "$T/owner" checkout -q v9.9.8; git -C "$T/owner" config color.ui always
refuses 'dry run with a release key' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
grep -q $'\033' "$T/out" && { cat -v "$T/out"; echo "FAIL: a raw ESC in the output" >&2; exit 1; }
git -C "$T/owner" config --unset color.ui; git -C "$T/owner" checkout -q main

# 7. No file from the repository runs: every script of the tag's tree and of the owner's checkout leaves a marker (and
# prints a fake review) if run. Dry runs and real runs never share a clone, nor keys.
for f in scripts/build.sh scripts/wp-sr-promote tests/smoke.sh tests/promote-dry-run.sh; do
  sed -i "1a echo FAKE REVIEW >&2; touch \"$T/ran-tag-${f##*/}\"" "$f"
  sed -i "1a echo FAKE REVIEW >&2; touch \"$T/ran-owner-${f##*/}\"" "$T/owner/$f"
done
g -C "$T/owner" commit -q -am 'test: the checkout scripts leave markers'
release v9.9.61 "$PUB1" # its zip comes from CI's unmarked build.sh
m=$(promote v9.9.61 "$T/v9.9.61.zip" --trusted-zip "$T/v9.9.7.zip" 2>"$T/err")
[ "$(verify "$m" "$T/v9.9.61.zip")" = valid ]
! grep -qxF 'FAKE REVIEW' "$T/err" && ! compgen -G "$T/ran-*" >/dev/null || { echo "FAIL: a file from the repository ran" >&2; exit 1; }
back_to "$TIP"; g -C "$T/owner" reset -q --hard HEAD~1; records v9.9.7
echo "ok: nothing from the repository ran (tag and checkout)"
touch "$T/owner/stray"; promote v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip" >"$T/out" 2>&1 || { cat "$T/out"; exit 1; }
rm "$T/owner/stray"; records v9.9.7 # the worktree is never read: a stray file changes nothing
ANS=9.9.7; refuses 'not confirmed' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"; ANS=""
grep -qF 'type 9.9.8 to sign v9.9.8' "$T/out"
OWNED="$T/owner/includes"; refuses "must be the clone's top folder" v9.9.8 "$T/v9.9.8.zip"; OWNED="$T/owner"
git -C "$T/owner" update-ref refs/puzzles-sr/promoted/v9.9.7 'v9.9.7^{commit}'
refuses 'holds your real promotion record' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
git -C "$T/owner" update-ref -d refs/puzzles-sr/promoted/v9.9.7
o=$(PUZZLES_SR_SIGNING_KEY="$SK" PUZZLES_SR_DRY_RUN_KEY="$SK" bash "$T/wp-sr-promote" --repo "$T/owner" v9.9.8 6.8.1 \
  --dry-run "$T/v9.9.8.zip" 2>&1) && exit 1; grep -qF 'a dry run never takes the release key' <<<"$o"
nodry() { PATH="$T/ghbin:$PATH" TMPDIR="$T/tmp" PUZZLES_SR_SIGNING_KEY="$SK" bash "$T/wp-sr-promote" --repo "$T/owner" "$1" 6.8.1 2>&1; }
o=$(nodry v9.9.8) && exit 1; grep -qF 'holds dry-run records' <<<"$o"
records
o=$(nodry v9.9.8) && exit 1; grep -qF 'origin is not github.com' <<<"$o" # stops before any gh call
records v9.9.7
git -C "$T/owner" config --add remote.origin.fetch '+refs/*:refs/*'
refuses "fetches into 'refs/*'" v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
git -C "$T/owner" config --unset-all remote.origin.fetch; git -C "$T/owner" config --add remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
echo "ok: dry runs and real runs keep apart; the record cannot be fetched into"

# 8. Arguments are checked before anything runs; relative paths are resolved where they are typed.
L() { PUZZLES_SR_SIGNING_KEY="$1" bash "$T/wp-sr-promote" --repo "$T/owner" "${@:2}" 2>&1; }
o=$(L "$SK" v9.9.8 '6.8; rm -rf x') && exit 1; grep -qF 'bad tested' <<<"$o"
o=$(L "" v9.9.8 6.8.1) && exit 1; grep -qF 'PUZZLES_SR_SIGNING_KEY is not set' <<<"$o"
o=$(L "" v9.9.8 6.8.1 --dry-run "$T/v9.9.8.zip") && exit 1; grep -qF 'PUZZLES_SR_DRY_RUN_KEY is not set' <<<"$o"
o=$(L "$SK" v9.9.8 6.8.1 --trusted-zip "$T/v9.9.7.zip") && exit 1; grep -qF 'for dry runs only' <<<"$o"
o=$(L "$SK" v9.9.8 6.8.1 --yes) && exit 1; grep -qF 'unknown argument: --yes' <<<"$o"
o=$(PUZZLES_SR_DRY_RUN_KEY="$SK" L "$SK" v9.9.8 6.8.1) && exit 1; grep -qF 'is set for a real run' <<<"$o"
o=$(PUZZLES_SR_SIGNING_KEY="$SK" bash "$T/wp-sr-promote" v9.9.8 6.8.1 2>&1) && exit 1; grep -qF 'usage: wp-sr-promote --repo' <<<"$o"
o=$(bash "$T/wp-sr-promote" record --repo "$T/owner" v9.9.8 v9.9.8 x 2>&1) && exit 1; grep -qF 'record takes the full commit sha' <<<"$o"
(cd "$T" && PATH="$T/ghbin:$PATH" TMPDIR="$T/tmp" PUZZLES_SR_DRY_RUN_KEY="$SK" bash "$T/wp-sr-promote" --repo owner \
  v9.9.8 6.8.1 --dry-run v9.9.8.zip --trusted-zip v9.9.7.zip <<<9.9.8 >"$T/out" 2>&1) || { cat "$T/out"; exit 1; }
records v9.9.7
echo "ok: bad arguments refused; relative paths work"
nothing_escaped
[ ! -e "$GHDIR/calls" ] || { cat "$GHDIR/calls"; echo "FAIL: gh was called by a dry run or before the origin check" >&2; exit 1; }

# 8b. scripts/build.sh's own guards (CI's builder; the promoter has the same checks before its review).
dup() { # dup <sed expression on the main file> <expected refusal> [overrides] [file] [printf bytes appended to it]
  rm -rf "$T/dup" "$T/dupout"; mkdir "$T/dup"
  cp puzzles-site-reports.php uninstall.php README.md CHANGELOG.md LICENSE "$T/dup/"; cp -r includes "$T/dup/"
  [ -z "$1" ] || sed -i "$1" "$T/dup/puzzles-site-reports.php"; [ -z "${4:-}" ] || printf "$5" >>"$T/dup/$4"
  o=$(bash "$T/ci-build.sh" 9.9.9 --src "$T/dup" --out "$T/dupout" ${3:+--test-overrides "$3"} 2>&1) && { echo "FAIL: build.sh took it" >&2; exit 1; }
  grep -qF "$2" <<<"$o" || { echo "$o"; echo "FAIL: expected '$2'" >&2; exit 1; }
  echo "ok: build.sh refused: $2"
}
dup '/^ \* Version:/p' "exactly one ' * Version: X.Y.Z' line"
dup "/^define( 'PUZZLES_SITE_REPORTS_VERSION'/p" 'exactly one PUZZLES_SITE_REPORTS_VERSION define'
echo "PUZZLES_SR_UPDATE_PUBKEY $PUB3" >"$T/ovr"
dup "/^define( 'PUZZLES_SR_UPDATE_PUBKEY'/p" 'not replaced exactly once' "$T/ovr"
dup '' 'not plain ASCII' '' README.md 'caf\303\251\n'
dup '' 'not plain ASCII' '' includes/crlf.php '<?php\r\n' # a CR before LF too (grep -U)
dup '' "not PHP but holds '<?'" '' CHANGELOG.md '<?php\n'

# 9. The real path, against the gh shim: a terminal is required; a first promotion pulled; the first promotion; the next
# one; rolling forward past a bad release; GitHub's latest checked against the record's sha256; a run stopped after it
# went live; a key rotation, then other clones that resume from the first one's records, or from `record`.
if ! command -v script >/dev/null; then
  [ -z "${CI:-}" ] || { echo "FAIL: CI must run the real path, but script(1) is missing" >&2; exit 1; }
  echo "skip: the real path needs script(1) for a terminal (CI runs it)"
else
  release v9.9.62 "$PUB2"; release v9.9.63 "$PUB2"; release v9.9.64 "$PUB2" # a rotation release and two after it
  GHURL=https://github.com/puzzles-consulting/wp-site-reports.git
  clone() { git clone -q -b main "$T/origin.git" "$T/$1"; git -C "$T/$1" remote set-url origin "$GHURL"; git -C "$T/$1" config "url.$T/origin.git.insteadOf" "$GHURL"; }
  pre() { mkdir -p "$GHDIR/$1"; cp "$T/$1.zip" "$GHDIR/$1/puzzles-site-reports.zip"; } # CI's pre-release of <tag>
  term() { # term <typed answer> <promoter args...>: a run on a terminal; prints its output
    local a=$1; shift
    PATH="$T/bin:$T/ghbin:$PATH" TMPDIR="$T/tmp" PUZZLES_SR_SIGNING_KEY="$SK" PUZZLES_SR_NEW_SIGNING_KEY="$NSK" \
      script -qec "$(printf '%q ' bash "$T/wp-sr-promote" "$@")" /dev/null <<<"$a" | tr -d '\r'
  }
  live() { local a=$1; shift; term "$a" --repo "$T/$CLONE" "$@"; } # live <typed answer> <tag> <tested> [options]
  rec() { git -C "$T/real" cat-file blob "refs/puzzles-sr/$1" 2>/dev/null; } # rec <promoted|pending>/<tag>
  recorded_as() { # recorded_as <tag>: the record holds the commit and the zip's sha256, and the commit is kept
    [ "$(rec "promoted/$1")" = "$(git rev-parse "$1^{commit}") $(sha_of "$T/$1.zip")" ] \
      && [ "$(git -C "$T/real" rev-parse "refs/puzzles-sr/commits/$1")" = "$(git rev-parse "$1^{commit}")" ]
  }
  pre v9.9.7; pre v9.9.8; pre v9.9.60; pre v9.9.62; pre v9.9.63; pre v9.9.64
  # A first promotion marked pre-release: no latest release, but a record. Its key is the one sites trust: a tag with
  # another key is refused without --rotate, and signs with --rotate and the record's key.
  pre v9.9.13; clone real0; CLONE=real0
  git -C "$T/real0" update-ref refs/puzzles-sr/promoted/v9.9.6 "$(blob "$T/real0" "$(git rev-parse 'v9.9.7^{commit}')" "$(sha_of "$T/v9.9.7.zip")")"
  SK=$SK2; o=$(live 9.9.13 v9.9.13 6.8.1) && { echo "$o"; exit 1; }; grep -qF 'is not the one sites trust now' <<<"$o"; SK=$SK1
  ! grep -q 'record values' <<<"$o" || { echo "FAIL: a refusing run printed record values" >&2; exit 1; }
  NSK=$SK2; o=$(live 9.9.13 v9.9.13 6.8.1 --rotate) || { echo "$o"; exit 1; }; NSK=""
  grep -qF 'baseline: v9.9.6, your last promotion' <<<"$o"
  rm -f "$GHDIR/latest" "$GHDIR/v9.9.13/manifest.json"; echo "ok: real path: a pulled first promotion is the trust anchor"
  clone real; CLONE=real
  o=$(PATH="$T/ghbin:$PATH" TMPDIR="$T/tmp" PUZZLES_SR_SIGNING_KEY="$SK" bash "$T/wp-sr-promote" --repo "$T/real" \
    v9.9.7 6.8.1 <<<9.9.7 2>&1) && exit 1
  grep -qF 'never from a pipe or a file' <<<"$o"; [ ! -e "$GHDIR/latest" ]
  o=$(live 9.9.7 v9.9.7 6.8.1) || { echo "$o"; exit 1; }
  C7=$(git rev-parse 'v9.9.7^{commit}'); S7=$(sha_of "$T/v9.9.7.zip")
  grep -qF "record values for v9.9.7: $C7 $S7" <<<"$o"
  [ "$(cat "$GHDIR/latest")" = v9.9.7 ]; [ "$(verify "$(cat "$GHDIR/v9.9.7/manifest.json")" "$T/v9.9.7.zip")" = valid ]
  recorded_as v9.9.7; ! rec pending/v9.9.7 >/dev/null
  o=$(live 9.9.8 v9.9.8 6.8.1) || { echo "$o"; exit 1; }
  grep -qF 'baseline: v9.9.7, your last promotion' <<<"$o"; grep -qF 'promoted v9.9.8' <<<"$o"
  echo "ok: real path: a terminal, the first promotion, the next one; values printed, manifests uploaded, records written"
  echo v9.9.7 >"$GHDIR/latest" # v9.9.8 marked pre-release
  o=$(live 9.9.60 v9.9.60 6.8.1) || { echo "$o"; exit 1; }
  grep -qF 'baseline: v9.9.8, your last promotion' <<<"$o"; [ "$(cat "$GHDIR/latest")" = v9.9.60 ]
  echo "ok: real path: rolled forward past a bad release"
  mkdir "$GHDIR/v9.9.98"; cp "$GHDIR/v9.9.60/"* "$GHDIR/v9.9.98/"; echo v9.9.98 >"$GHDIR/latest"
  o=$(live 9.9.60 v9.9.60 6.8.1) && { echo "$o"; exit 1; }; grep -qF 'the latest release on GitHub is v9.9.98, not a promotion recorded' <<<"$o"
  echo v9.9.60 >"$GHDIR/latest"; cp "$GHDIR/v9.9.60/puzzles-site-reports.zip" "$T/live.zip"
  printf '\377' | dd of="$GHDIR/v9.9.60/puzzles-site-reports.zip" bs=1 seek=100 conv=notrunc status=none # another zip went live
  o=$(live 9.9.60 v9.9.60 6.8.1) && { echo "$o"; exit 1; }; grep -qF 'is not the zip you signed' <<<"$o"
  cp "$T/live.zip" "$GHDIR/v9.9.60/puzzles-site-reports.zip"
  echo "ok: real path: GitHub's latest must be recorded, with the zip you signed"
  # Stopped after `gh release edit`: v9.9.60 is latest and pending, not recorded.
  git -C "$T/real" update-ref -d refs/puzzles-sr/promoted/v9.9.60
  o=$(live 9.9.60 v9.9.60 6.8.1) && { echo "$o"; exit 1; }; grep -qF 'If you promoted it, copy the records' <<<"$o"
  pend() { git -C "$T/real" update-ref refs/puzzles-sr/pending/v9.9.60 "$(blob "$T/real" "$(git rev-parse 'v9.9.60^{commit}')" "$1")"; }
  pend "$(printf x | sha256sum | cut -c1-64)" # the run here signed some other zip
  o=$(live 9.9.60 v9.9.60 6.8.1) && { echo "$o"; exit 1; }; grep -qF 'is not the one the interrupted run here signed' <<<"$o"
  pend "$(sha_of "$T/v9.9.60.zip")"
  o=$(live 9.9.60 v9.9.60 6.8.1) || { echo "$o"; exit 1; }
  C60=$(git rev-parse 'v9.9.60^{commit}'); S60=$(sha_of "$T/v9.9.60.zip")
  grep -qF "promoted v9.9.60 (it was already live): commit $C60, zip sha256 $S60" <<<"$o"
  recorded_as v9.9.60; ! rec pending/v9.9.60 >/dev/null
  o=$(live 9.9.60 v9.9.60 6.8.1) && { echo "$o"; exit 1; }; grep -qF 'is not newer than the latest release (9.9.60)' <<<"$o"
  echo "ok: real path: an interrupted promotion is recorded, nothing left to do"
  NSK=$SK2; o=$(live 9.9.62 v9.9.62 6.8.1 --rotate) || { echo "$o"; exit 1; }; NSK=""
  grep -qF "sites trust only $PUB2" <<<"$o"; SK=$SK2
  git push -q origin :refs/tags/v9.9.62 # origin loses the tag: the commits ref is copied
  clone real2; CLONE=real2 # a second clone: with no record it is told how to restore one...
  o=$(live 9.9.63 v9.9.63 6.8.1) && { echo "$o"; exit 1; }; grep -qF 'If you promoted it, copy the records' <<<"$o"
  git -C "$T/real2" fetch -q "$T/real" 'refs/puzzles-sr/*:refs/puzzles-sr/*' # README's command
  [ "$(git -C "$T/real2" rev-parse refs/puzzles-sr/commits/v9.9.62)" = "$(git rev-parse 'v9.9.62^{commit}')" ]
  o=$(live 9.9.63 v9.9.63 6.8.1) || { echo "$o"; exit 1; } # ...and with the first one's records (README) it promotes
  grep -qF 'baseline: v9.9.62, your last promotion' <<<"$o"; grep -qF 'promoted v9.9.63' <<<"$o"
  echo "ok: real path: a rotation, then a second clone resumes with the first one's records"
  clone real3; CLONE=real3 # a third clone records the latest by hand, from the values its promotion printed
  C63=$(git rev-parse 'v9.9.63^{commit}'); S63=$(sha_of "$T/v9.9.63.zip")
  g checkout -q -b extra v9.9.63; echo '<?php' >includes/extra.php; g add includes/extra.php; g commit -q -m extra
  git push -q origin HEAD:refs/heads/extra; git -C "$T/real3" fetch -q origin extra; EXTRA=$(git rev-parse HEAD); g checkout -q main
  o=$(term 9.9.63 record --repo "$T/real3" v9.9.63 "$C63" "$(sha_of "$T/v9.9.62.zip")") && { echo "$o"; exit 1; }
  grep -qF 'it is not the release you signed' <<<"$o"
  o=$(term 9.9.63 record --repo "$T/real3" v9.9.63 "$EXTRA" "$S63") && { echo "$o"; exit 1; }
  grep -qF "does not hold the files of commit $EXTRA" <<<"$o"
  o=$(term 9.9.63 record --repo "$T/real3" v9.9.63 "$C60" "$S63") && { echo "$o"; exit 1; }
  grep -qF "differs from commit $C60 in 'puzzles-site-reports/puzzles-site-reports.php'" <<<"$o"
  o=$(term 9.9.63 record --repo "$T/real3" v9.9.63 "$C63" "$S63") || { echo "$o"; exit 1; }
  grep -qF "recorded v9.9.63: commit $C63" <<<"$o"
  [ "$(git -C "$T/real3" cat-file blob refs/puzzles-sr/promoted/v9.9.63)" = "$C63 $S63" ]
  o=$(term 9.9.63 record --repo "$T/real3" v9.9.63 "$C63" "$S63") && { echo "$o"; exit 1; }; grep -qF 'is already recorded' <<<"$o"
  o=$(term 9.9.64 record --repo "$T/real3" v9.9.64 "$(git rev-parse 'v9.9.64^{commit}')" "$(sha_of "$T/v9.9.64.zip")") && { echo "$o"; exit 1; }
  grep -qF 'it was never promoted' <<<"$o" # a release with no manifest is not recorded
  o=$(live 9.9.64 v9.9.64 6.8.1) || { echo "$o"; exit 1; } # the lost-clone clone promotes the next release
  grep -qF 'baseline: v9.9.63, your last promotion' <<<"$o"; grep -qF 'promoted v9.9.64' <<<"$o"
  CLONE=real; SK=$SK1
  echo "ok: real path: record checks the release's sha256, its file list and content; then that clone promotes"
  nothing_escaped
fi
echo "promote-dry-run: all checks passed"
