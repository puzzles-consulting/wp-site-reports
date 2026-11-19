#!/usr/bin/env bash
# Offline check of the promotion on the committed HEAD: HEAD's scripts/launcher.sh, installed outside the checkouts as
# the owner installs it, running the recorded scripts/promote.sh. A local bare repository is `origin`; a "dev" clone
# pushes tagged commits (each carrying a throwaway public key) and builds their release zips as CI does; the "owner"
# clone stays on HEAD (only real keys in its history), runs dry runs, types the version on stdin and keeps the dry-run
# record (refs/puzzles-sr/dry-run/). Section 9 runs the real path in a "real" clone against a gh shim that serves
# releases from a directory, on a terminal made by script(1) (skipped where script(1) is missing: Git Bash; CI runs it).
# Throwaway keys only, never a real one. Everything is written under one temp dir, promote.sh's own temp dirs included.
# Needs php or Docker (scripts/php.sh), python, unzip. CI runs it (.github/workflows/ci.yml).
# Usage: bash tests/promote-dry-run.sh
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git -C "$REPO" push -q "$T/origin.git" HEAD:refs/heads/main
git clone -q -b main "$T/origin.git" "$T/owner"
git clone -q -b main "$T/origin.git" "$T/dev"
cp "$T/owner/scripts/launcher.sh" "$T/wp-sr-promote" # the owner's installed launcher (README, Release)
TRUST=$(git -C "$T/owner" rev-parse HEAD)          # the commit whose scripts the owner reviewed by hand
cd "$T/dev"
g() { git -c user.name=test -c user.email=test@example.com "$@"; }
. scripts/php.sh

# Throwaway keypairs: public keys in PUBn, secret keys in SKn.
for i in 1 2 3; do printf -v "PUB$i" %s "$(bash scripts/keygen.sh 3>"$T/sk$i")"; printf -v "SK$i" %s "$(cat "$T/sk$i")"; done
[[ -n $PUB1 && -n $PUB2 && -n $SK1 && -n $SK2 && -n $SK3 ]] || { echo "FAIL: keygen gave an empty key" >&2; exit 1; }
# The launcher's and promote.sh's children must never see a key: these shims fail the run if one inherits it.
mkdir "$T/bin" "$T/tmp" "$T/gh"
for c in git unzip python3 python docker php realpath; do
  r=$(command -v "$c") || continue
  printf '#!/usr/bin/env bash\n[ -z "${PUZZLES_SR_SIGNING_KEY+x}${PUZZLES_SR_NEW_SIGNING_KEY+x}" ] || { echo "LEAK: %s got a key" >&2; exit 99; }\nexec "%s" "$@"\n' \
    "$c" "$r" >"$T/bin/$c"
  chmod +x "$T/bin/$c"
done
# gh: GitHub's releases as a directory, $GHDIR/<tag>/<asset> and $GHDIR/latest; every call is logged in $GHDIR/calls.
export GHDIR="$T/gh"
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ -z "${PUZZLES_SR_SIGNING_KEY+x}${PUZZLES_SR_NEW_SIGNING_KEY+x}" ] || { echo "LEAK: gh got a key" >&2; exit 99; }
echo "$*" >>"$GHDIR/calls"
case "$1 $2" in
  "api repos/puzzles-consulting/wp-site-reports/releases/latest")
    [ -s "$GHDIR/latest" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    cat "$GHDIR/latest" ;;
  "release download") cp "$GHDIR/$3/$5" "$7/" ;;            # release download <tag> --pattern <asset> --dir <dir>
  "release upload") cp "$4" "$GHDIR/$3/" ;;                  # release upload <tag> <file> --clobber
  "release edit") printf '%s\n' "$3" >"$GHDIR/latest" ;;     # release edit <tag> --prerelease=false --latest
  *) echo "gh shim: unexpected call: $*" >&2; exit 97 ;;
esac
EOF
chmod +x "$T/bin/gh"
# promote.sh's temp dirs go under $T/tmp: a file that escaped an export lands there, where nothing_escaped looks.
d=$(TMPDIR="$T/tmp" mktemp -d); [[ $d == "$T/tmp/"* ]] || { echo "FAIL: mktemp ignores TMPDIR" >&2; exit 1; }; rmdir "$d"
nothing_escaped() { [ -z "$(ls -A "$T/tmp")" ] || { ls -laR "$T/tmp" >&2; echo "FAIL: a file escaped the export" >&2; exit 1; }; }

tag() { # tag <tag> [commit]: tags and pushes it; the owner's tags follow origin's (a moved tag fails: not called then)
  g tag -a "$1" -m "$1" ${2:-}; git push -q origin "$1"; git -C "$T/owner" fetch -q --tags origin
}
zip_of() { bash scripts/build.sh "${1#v}" --out "$T/build-$1" >/dev/null; cp "$T/build-$1/puzzles-site-reports.zip" "$T/$1.zip"; } # as CI does
release() { # release <tag> <pubkey>: a commit on main carrying that key, tagged; its zip is $T/<tag>.zip
  sed -i "s|^define( 'PUZZLES_SR_UPDATE_PUBKEY', '[^']*' );|define( 'PUZZLES_SR_UPDATE_PUBKEY', '$2' );|" puzzles-site-reports.php
  grep -qF "'PUZZLES_SR_UPDATE_PUBKEY', '$2'" puzzles-site-reports.php
  g commit -q --allow-empty -am "test: $1"; git push -q origin HEAD:main; tag "$1"; zip_of "$1"
}
back_to() { g reset -q --hard "$1"; git push -q -f origin HEAD:main; } # main drops the refused commits
records() { # records <tag>...: the owner's dry-run record (promote.sh, 1c) holds exactly these promotions
  git -C "$T/owner" for-each-ref --format='delete %(refname)' refs/puzzles-sr | git -C "$T/owner" update-ref --stdin
  local t; for t in "$@"; do git -C "$T/owner" update-ref "refs/puzzles-sr/dry-run/promoted/$t" "$t^{commit}"; done
}
SK=$SK1; NSK=""; ANS=""; OWNED="$T/owner"
promote() { # promote <tag> <zip> [options]: a dry run in $OWNED through the launcher, signing with $SK (and $NSK as the
  local tag=$1 zip=$2; shift 2 # new key); types $ANS, else the tag's version
  PATH="$T/bin:$PATH" TMPDIR="$T/tmp" PUZZLES_SR_SIGNING_KEY="$SK" PUZZLES_SR_NEW_SIGNING_KEY="$NSK" \
    bash "$T/wp-sr-promote" --repo "$OWNED" "$tag" 6.8.1 --dry-run "$zip" "$@" <<<"${ANS:-${tag#v}}"
}
refuses() { # refuses <expected message> <promote args...>
  local want=$1; shift
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

# 1. With no record on this machine the launcher needs a reviewed commit (a full sha); the first promotion shows
# everything as new. The next one (its main file and an include each gain a marker line) runs the scripts of the
# record of the first and shows both lines against it.
release v9.9.7 "$PUB1"
refuses 'no promotion is recorded on this machine' v9.9.7 "$T/v9.9.7.zip"
refuses 'full 40-character commit sha' v9.9.7 "$T/v9.9.7.zip" --trust-checkout HEAD
m=$(promote v9.9.7 "$T/v9.9.7.zip" --trust-checkout "$TRUST" 2>"$T/err"); grep -qF 'checks are skipped' "$T/err"
grep -qF "running the promotion scripts of $TRUST (--trust-checkout)" "$T/err"
grep -qF 'baseline: none: first promotion recorded on this machine: everything is new' "$T/err"
[ "$(verify "$m" "$T/v9.9.7.zip")" = valid ]
echo '// marker: main' >>puzzles-site-reports.php; echo '// marker: include' >>includes/seo.php
release v9.9.8 "$PUB1"
m=$(promote v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip" 2>"$T/err")
echo "$m"
grep -qF 'running the promotion scripts of v9.9.7, your last promotion recorded on this machine' "$T/err"
grep -qF 'baseline: v9.9.7, your last promotion recorded on this machine' "$T/err"
grep -qxF '+// marker: main' "$T/err"; grep -qxF '+// marker: include' "$T/err"
grep -qF "\"version\":\"9.9.8\",\"sha256\":\"$(sha256sum "$T/v9.9.8.zip" | cut -c1-64)\"" <<<"$m"
grep -qF '"requires":"5.8","requires_php":"7.4","tested":"6.8.1"' <<<"$m"
[ "$(verify "$m" "$T/v9.9.8.zip")" = valid ]
[ "$(verify "${m/6.8.1/6.8.2}" "$T/v9.9.8.zip")" = invalid ] # the verifier really checks
[ "$(git -C "$T/owner" rev-parse refs/puzzles-sr/dry-run/promoted/v9.9.8)" = "$(git rev-parse 'v9.9.8^{commit}')" ]
[ -z "$(git -C "$T/owner" for-each-ref refs/puzzles-sr/promoted)" ] # a dry run never writes the real record
echo "ok: signed; the plugin's own verifier accepts the manifest; the diff is against the owner's record"
records v9.9.7 # from here on the owner last promoted v9.9.7, the --trusted-zip of most runs below

# 2. The release zip is not the reviewed build.sh's build of the tag: one byte changed.
cp "$T/v9.9.8.zip" "$T/flip.zip"; printf '\377' | dd of="$T/flip.zip" bs=1 seek=100 conv=notrunc status=none
cmp -s "$T/v9.9.8.zip" "$T/flip.zip" && exit 1
refuses 'is not what the reviewed build.sh builds from v9.9.8' v9.9.8 "$T/flip.zip" --trusted-zip "$T/v9.9.7.zip"

# 3. The tag's tree: a symlink, then attributes, bytes, version lines and the tripwires on the shipped PHP.
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
printf '<?php /* \033[2K\r+// tidy */\n' >includes/evil.php; odd v9.9.50 "$BYTE" # erases its own line on a terminal
printf "<?php const PUZZLES_SR_UPDATE_\320\240UBKEY = 'x';\n" >includes/evil.php; odd v9.9.51 "$BYTE" # Cyrillic U+0420
printf 'PUZZLES_SR_UPDATE_PUBKEY\0' >includes/evil.bin; odd v9.9.14 "$BYTE"
printf '# caf\303\251\n' >>scripts/build.sh; odd v9.9.54 "'scripts/build.sh' $BYTE" # the next run's scripts too
printf 'includes/seo.php filter=evil\n' >>.gitattributes; odd v9.9.56 "includes/seo.php': filter=evil"
printf 'scripts/*.sh eol=crlf\n' >>.gitattributes; odd v9.9.57 "scripts/build.sh': eol=crlf"
printf ' * Version: 6.6.6\n' >>puzzles-site-reports.php; odd v9.9.55 'needs exactly one'
printf "\$doc = \"define( 'PUZZLES_SITE_REPORTS_VERSION', 'x' );\";\n" >>puzzles-site-reports.php; odd v9.9.59 'needs exactly one'
printf '<?php define( "puzzles_sr_update_pubkey", "x", true );\n' >includes/evil.php; odd v9.9.10 'appears outside the main file'
printf "const PUZZLES_SR_UPDATE_PUBKEY = 'x';\n" >>puzzles-site-reports.php; odd v9.9.11 'defines PUZZLES_SR_UPDATE_PUBKEY more than once'
printf "<?php \$n = 'PUZZLES_SR_' . 'UPDATE_PUBKEY';\n" >includes/evil.php; odd v9.9.15 'cannot follow'
printf "<?php echo constant( 'X' );\n" >includes/evil.php; odd v9.9.16 'cannot follow'
printf "<?php define(\n\t'X', 1 );\n" >includes/evil.php; odd v9.9.17 'cannot follow'
printf "<?php const\nPUZZLES_SR_X = 1;\n" >includes/evil.php; odd v9.9.52 'cannot follow'
printf "<?php const PUZZLES_SITE_REPORTS_MAX_PACKAGE = 1;\n" >includes/evil.php; odd v9.9.53 'defines a constant more than once'
sed -i "/^define( 'PUZZLES_SR_UPDATE_PUBKEY'/i require_once __DIR__ . '/includes/seo.php';" puzzles-site-reports.php
odd v9.9.18 'includes a file before it defines'
# A shipped non-code file is not byte-checked: its control bytes reach the screen only through cat -v. The diff is
# against the record: an unchanged line far from the change is not printed.
printf 'An escape: \033[2K here\n' >>README.md; release v9.9.58 "$PUB1"
promote v9.9.58 "$T/v9.9.58.zip" --trusted-zip "$T/v9.9.7.zip" >"$T/out" 2>&1 || { cat "$T/out"; exit 1; }
grep -qxF '+An escape: ^[[2K here' "$T/out"
! grep -q $'\033' "$T/out" || { echo "FAIL: a raw ESC in the output" >&2; exit 1; }
! grep -qE '^[ +]# Puzzles Site Reports$' "$T/out" || { echo "FAIL: the diff printed an unchanged line" >&2; exit 1; }
back_to v9.9.8; records v9.9.7
echo "ok: README's ESC shows as ^[; the diff holds only the change"

# 3b. Entry names no checkout could write (git mktree). Git Bash takes `\` as a separator: on Windows these would land
# outside the export, in $T/tmp. Outside the allowlist they are ignored (the release signs); inside it, refused, as are
# names Windows would not write as they are.
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
n=20
for name in '..\..\escaped' 'a\..\..\..\x' '-x' '.hidden' '..'; do # the first two would land in $T/tmp
  graft "v9.9.$n" . "$name" "$([ "$name" = .. ] && echo tree || true)"; zip_of "v9.9.$n"
  promote "v9.9.$n" "$T/v9.9.$n.zip" --trusted-zip "$T/v9.9.7.zip" >"$T/out" 2>&1 \
    || { cat "$T/out"; echo "FAIL: ${name@Q} outside the allowlist was not ignored" >&2; exit 1; }
  nothing_escaped; back_to v9.9.8; records v9.9.7; n=$((n + 1))
done
for c in '..\..\..\escaped|has the path' 'a\..\..\..\..\x|has the path' '-x|has the path' '.hidden|has the path' \
  '..|has the path' 'SEO.php|one name on Windows' 'x.php.|ending in' 'con.php|reserved device name' \
  'NUL|reserved device name' 'Lpt1.txt|reserved device name'; do
  graft "v9.9.$n" includes "${c%|*}" "$([ "${c%|*}" = .. ] && echo tree || true)"
  refuses "${c#*|}" "v9.9.$n" "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
  nothing_escaped; back_to v9.9.8; n=$((n + 1))
done
echo "ok: hostile names ignored outside the allowlist, refused inside it; nothing escaped"
# The raw tree, not `git archive`: with this .gitattributes an archive would drop includes/seo.php and fail the match.
printf 'includes/seo.php export-ignore\n' >>.gitattributes; g add .gitattributes; release v9.9.40 "$PUB1"
promote v9.9.40 "$T/v9.9.40.zip" --trusted-zip "$T/v9.9.7.zip" >"$T/out" 2>&1 || { cat "$T/out"; exit 1; }
back_to v9.9.8; records v9.9.7
echo "ok: .gitattributes does not change the export"

# 4. origin's tag points elsewhere (moved after the canary), then a tag that is not on main.
git push -q -f origin "$(git rev-parse 'v9.9.7^{commit}'):refs/tags/v9.9.8"
refuses "origin's v9.9.8 is" v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
git push -q -f origin v9.9.8
g checkout -q -b side; g commit -q --allow-empty -m side; tag v9.9.12; g checkout -q main
refuses 'is not on origin/main' v9.9.12 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"

# 5. Keys and versions against the latest release (v9.9.7, v9.9.8 or v9.9.13), which must be one the owner recorded.
# A bad release (v9.9.8) marked pre-release: GitHub's latest is v9.9.7 again, recorded too; the baseline stays the
# highest record, and the next release must be newer than it.
release v9.9.60 "$PUB1"
records v9.9.7 v9.9.8
m=$(promote v9.9.60 "$T/v9.9.60.zip" --trusted-zip "$T/v9.9.7.zip" 2>"$T/err")
grep -qF 'baseline: v9.9.8, your last promotion recorded' "$T/err"; [ "$(verify "$m" "$T/v9.9.60.zip")" = valid ]
records v9.9.7 v9.9.60
refuses 'is not newer than your last promotion recorded on this machine (v9.9.60)' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
echo "ok: rolling forward past a bad release"
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
NSK=$SK2; refuses 'set without --rotate' v9.9.13 "$T/v9.9.13.zip" --trusted-zip "$T/v9.9.8.zip"; NSK=""
records v9.9.7
SK=$SK2; refuses 'is not the one sites trust now' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"; SK=$SK1
refuses "GitHub's release state does not match your record" v9.9.13 "$T/v9.9.13.zip" --trusted-zip "$T/v9.9.8.zip"
records v9.9.7 v9.9.8
refuses 'is not newer than the latest release (9.9.8)' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.8.zip"
records v9.9.7 v9.9.13
refuses 'is not newer than the latest release (9.9.13)' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.13.zip"
records v9.9.7

# 6. A dry run refuses any key in the owner's history: here the owner's checkout is one whose history carries PUB1.
# With color.ui=always `git log -p` is coloured: the keys are read from each commit's file, not parsed from a log; the
# printed diffs stay plain.
git -C "$T/owner" checkout -q v9.9.8; git -C "$T/owner" config color.ui always
refuses 'dry run with a release key' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
grep -q $'\033' "$T/out" && { cat -v "$T/out"; echo "FAIL: a raw ESC in the output" >&2; exit 1; }
git -C "$T/owner" config --unset color.ui; git -C "$T/owner" checkout -q main

# 7. Nothing from the checkout's worktree runs: the owner's own commit makes its scripts/ leave a marker (and its
# promote.sh print a fake review), and the promotion runs the record's scripts instead. Then the reviewed scripts the
# launcher takes: a trusted commit whose build.sh changes or drops a staged file, or whose php.sh is not plain ASCII.
touch "$T/owner/stray"; refuses 'uncommitted changes' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"; rm "$T/owner/stray"
for f in promote build php; do sed -i "1a echo FAKE REVIEW >&2; touch \"$T/ran-$f\"" "$T/owner/scripts/$f.sh"; done
g -C "$T/owner" commit -q -am 'test: worktree scripts leave markers'
m=$(promote v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip" 2>"$T/err")
[ "$(verify "$m" "$T/v9.9.8.zip")" = valid ]
! grep -qF 'FAKE REVIEW' "$T/err" && [ -z "$(ls "$T" | grep '^ran-' || true)" ] \
  || { echo "FAIL: a script from the owner's worktree ran" >&2; exit 1; }
records v9.9.7; ANS=9.9.7; refuses 'not confirmed' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"; ANS=""
grep -qF 'type 9.9.8 to sign v9.9.8' "$T/out"
g -C "$T/owner" reset -q --hard HEAD~1; records v9.9.7
o=$(PUZZLES_SR_SIGNING_KEY="$SK" bash "$T/owner/scripts/promote.sh" v9.9.8 6.8.1 2>&1) && exit 1; grep -qF 'run it through the launcher' <<<"$o"
echo "ok: the worktree's scripts never ran; promote.sh refuses to run outside the launcher"
trusted() { # trusted <change> <expected refusal>: dev commits <change> (a command) on a side branch; the owner trusts it
  eval "$1"; g commit -q -am "test: $1"; git push -q -f origin HEAD:refs/heads/scripts-test; git -C "$T/owner" fetch -q origin scripts-test
  refuses "$2" v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip" --trust-checkout "$(git rev-parse HEAD)"
  g reset -q --hard HEAD~1
}
bdo() { sed -i "\\|^F=\"\$S/puzzles-site-reports.php\"\$|a $1" scripts/build.sh; grep -qxF "$1" scripts/build.sh; } # build.sh runs <line> on the staged copy
trusted "bdo 'echo x >>\"\$S/LICENSE\"'" "zip of v9.9.8 does not hold exactly the tag's files"
trusted "bdo 'rm \"\$S/uninstall.php\"'" "zip of v9.9.8 does not hold exactly the tag's files"
trusted "printf '# caf\303\251\n' >>scripts/php.sh" "scripts/php.sh has a byte other than TAB"
git -C "$T/owner" config --add remote.origin.fetch '+refs/*:refs/*'
refuses "fetches into 'refs/*'" v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
git -C "$T/owner" config --unset-all remote.origin.fetch; git -C "$T/owner" config --add remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
nodry() { PATH="$T/bin:$PATH" TMPDIR="$T/tmp" PUZZLES_SR_SIGNING_KEY="$SK" bash "$T/wp-sr-promote" --repo "$T/owner" --trust-checkout "$TRUST" "$1" 6.8.1 2>&1; }
o=$(nodry v9.9.12) && exit 1; grep -qF "is not in this checkout's history" <<<"$o"
git -C "$T/owner" tag v9.9.90 # the owner's own HEAD passes that check and stops at the next one, before any gh call
o=$(nodry v9.9.90) && exit 1; grep -qF 'origin is not github.com' <<<"$o"
echo "ok: reviewed scripts only, a clean checkout, the tag in the reviewed history"

# 8. Arguments are checked before anything runs.
L() { PUZZLES_SR_SIGNING_KEY="$1" bash "$T/wp-sr-promote" --repo "$T/owner" --trust-checkout "$TRUST" "${@:2}" 2>&1; }
o=$(L "$SK" v9.9.8 '6.8; rm -rf x') && exit 1; grep -qF 'bad tested' <<<"$o"
o=$(L "" v9.9.8 6.8.1 --dry-run "$T/v9.9.8.zip") && exit 1; grep -qF 'is not set' <<<"$o"
o=$(L "$SK" v9.9.8 6.8.1 --trusted-zip "$T/v9.9.7.zip") && exit 1; grep -qF 'for dry runs only' <<<"$o"
o=$(L "$SK" v9.9.8 6.8.1 --yes) && exit 1; grep -qF 'unknown argument: --yes' <<<"$o"
o=$(PUZZLES_SR_SIGNING_KEY="$SK" bash "$T/wp-sr-promote" v9.9.8 6.8.1 2>&1) && exit 1; grep -qF 'usage: wp-sr-promote --repo' <<<"$o"
echo "ok: bad arguments refused"
nothing_escaped
[ ! -e "$GHDIR/calls" ] || { cat "$GHDIR/calls"; echo "FAIL: gh was called by a dry run or before the origin check" >&2; exit 1; }

# 9. The real path, against the gh shim: a terminal is required; the first promotion, the next one on the record's
# scripts, rolling forward past a bad release, and a run stopped after it went live (recorded on the next run).
if ! command -v script >/dev/null; then
  echo "skip: the real path needs script(1) for a terminal (CI runs it)"
else
  git clone -q -b main "$T/origin.git" "$T/real"
  GHURL=https://github.com/puzzles-consulting/wp-site-reports.git
  git -C "$T/real" remote set-url origin "$GHURL"; git -C "$T/real" config "url.$T/origin.git.insteadOf" "$GHURL"
  pre() { mkdir -p "$GHDIR/$1"; cp "$T/$1.zip" "$GHDIR/$1/puzzles-site-reports.zip"; } # CI's pre-release of <tag>
  live() { # live <typed answer> <launcher args...>: a real run in $T/real on a terminal; prints its output
    local a=$1; shift
    PATH="$T/bin:$PATH" TMPDIR="$T/tmp" PUZZLES_SR_SIGNING_KEY="$SK" PUZZLES_SR_NEW_SIGNING_KEY="" \
      script -qec "$(printf '%q ' bash "$T/wp-sr-promote" --repo "$T/real" "$@")" /dev/null <<<"$a" | tr -d '\r'
  }
  rec() { git -C "$T/real" rev-parse --quiet --verify "refs/puzzles-sr/$1"; } # rec <promoted|pending>/<tag>
  pre v9.9.7; pre v9.9.8; pre v9.9.60
  o=$(PATH="$T/bin:$PATH" TMPDIR="$T/tmp" PUZZLES_SR_SIGNING_KEY="$SK" bash "$T/wp-sr-promote" --repo "$T/real" \
    --trust-checkout "$TRUST" v9.9.7 6.8.1 <<<9.9.7 2>&1) && exit 1
  grep -qF 'from a terminal, never from a pipe' <<<"$o"; [ ! -e "$GHDIR/latest" ]
  o=$(live 9.9.7 --trust-checkout "$TRUST" v9.9.7 6.8.1) || { echo "$o"; exit 1; }
  grep -qF 'promoted v9.9.7' <<<"$o"; [ "$(cat "$GHDIR/latest")" = v9.9.7 ]
  [ "$(verify "$(cat "$GHDIR/v9.9.7/manifest.json")" "$T/v9.9.7.zip")" = valid ]
  [ "$(rec promoted/v9.9.7)" = "$(git rev-parse 'v9.9.7^{commit}')" ]; ! rec pending/v9.9.7 >/dev/null
  o=$(live 9.9.8 v9.9.8 6.8.1) || { echo "$o"; exit 1; }
  grep -qF 'running the promotion scripts of v9.9.7, your last promotion' <<<"$o"; grep -qF 'promoted v9.9.8' <<<"$o"
  echo "ok: real path: a terminal, the first promotion, then the record's scripts; manifests uploaded, records written"
  echo v9.9.7 >"$GHDIR/latest" # v9.9.8 marked pre-release
  o=$(live 9.9.60 v9.9.60 6.8.1) || { echo "$o"; exit 1; }
  grep -qF 'baseline: v9.9.8, your last promotion' <<<"$o"; [ "$(cat "$GHDIR/latest")" = v9.9.60 ]
  echo "ok: real path: rolled forward past a bad release"
  # Stopped after `gh release edit`: v9.9.60 is latest and pending, not recorded.
  git -C "$T/real" update-ref -d refs/puzzles-sr/promoted/v9.9.60
  o=$(live 9.9.60 v9.9.60 6.8.1) && { echo "$o"; exit 1; }; grep -qF "does not match your record" <<<"$o"
  git -C "$T/real" update-ref refs/puzzles-sr/pending/v9.9.60 'v9.9.60^{commit}'
  cp "$GHDIR/v9.9.60/manifest.json" "$T/manifest.json"; sed -i 's/6\.8\.1/6.8.2/' "$GHDIR/v9.9.60/manifest.json"
  o=$(live 9.9.60 v9.9.60 6.8.1) && { echo "$o"; exit 1; }; grep -qF 'is not signed by the key of your record' <<<"$o"
  cp "$T/manifest.json" "$GHDIR/v9.9.60/manifest.json"
  o=$(live 9.9.60 v9.9.60 6.8.1) || { echo "$o"; exit 1; }; grep -qF 'recorded v9.9.60 as promoted' <<<"$o"
  [ "$(rec promoted/v9.9.60)" = "$(git rev-parse 'v9.9.60^{commit}')" ]; ! rec pending/v9.9.60 >/dev/null
  o=$(live 9.9.60 v9.9.60 6.8.1) && { echo "$o"; exit 1; }; grep -qF 'is not newer than the latest release (9.9.60)' <<<"$o"
  echo "ok: real path: an interrupted promotion is recorded after its manifest checks out"
  nothing_escaped
fi
echo "promote-dry-run: all checks passed"
