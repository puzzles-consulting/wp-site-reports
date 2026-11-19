#!/usr/bin/env bash
# Offline check of scripts/promote.sh --dry-run on the committed HEAD. A local bare repository is `origin`; a "dev" clone
# pushes tagged commits (each carrying a throwaway public key) and builds their release zips as CI does; the "owner" clone
# stays on HEAD (only real keys in its history), runs promote.sh, types the version on stdin and keeps the dry-run record
# (refs/puzzles-sr/dry-run/). Throwaway keys only, never a real one. Everything is written under one temp dir,
# promote.sh's own temp dirs included (TMPDIR).
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
. scripts/php.sh

# Throwaway keypairs: public keys in PUBn, secret keys in SKn.
for i in 1 2 3; do printf -v "PUB$i" %s "$(bash scripts/keygen.sh 3>"$T/sk$i")"; printf -v "SK$i" %s "$(cat "$T/sk$i")"; done
[[ -n $PUB1 && -n $PUB2 && -n $SK1 && -n $SK2 && -n $SK3 ]] || { echo "FAIL: keygen gave an empty key" >&2; exit 1; }
# promote.sh's children must never see a key: these shims fail the run if one inherits it. gh must not run at all.
mkdir "$T/bin" "$T/tmp"
for c in git unzip python3 python docker php realpath; do
  r=$(command -v "$c") || continue
  printf '#!/usr/bin/env bash\n[ -z "${PUZZLES_SR_SIGNING_KEY+x}${PUZZLES_SR_NEW_SIGNING_KEY+x}" ] || { echo "LEAK: %s got a key" >&2; exit 99; }\nexec "%s" "$@"\n' \
    "$c" "$r" >"$T/bin/$c"
  chmod +x "$T/bin/$c"
done
printf '#!/usr/bin/env bash\necho "FAIL: gh called" >&2; exit 98\n' >"$T/bin/gh"; chmod +x "$T/bin/gh"
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
SK=$SK1; NSK=""; ANS=""
promote() { # promote <tag> <zip> [options]: as the owner, signing with $SK (and $NSK as the new key); types $ANS, else the tag's version
  local tag=$1 zip=$2; shift 2
  PATH="$T/bin:$PATH" TMPDIR="$T/tmp" PUZZLES_SR_SIGNING_KEY="$SK" PUZZLES_SR_NEW_SIGNING_KEY="$NSK" \
    bash "$T/owner/scripts/promote.sh" "$tag" 6.8.1 --dry-run "$zip" "$@" <<<"${ANS:-${tag#v}}"
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

# 1. Matching tree: signs. The first promotion recorded on this machine shows everything as new; the next one (its main
# file and an include each gain a marker line) shows both lines against the record of the first.
release v9.9.7 "$PUB1"
m=$(promote v9.9.7 "$T/v9.9.7.zip" 2>"$T/err"); grep -qF 'checks are skipped' "$T/err"
grep -qF 'baseline: none: first promotion recorded on this machine: everything is new' "$T/err"
[ "$(verify "$m" "$T/v9.9.7.zip")" = valid ]
echo '// marker: main' >>puzzles-site-reports.php; echo '// marker: include' >>includes/seo.php
release v9.9.8 "$PUB1"
m=$(promote v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip" 2>"$T/err")
echo "$m"
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

# 2. The release zip is not this checkout's build of the tag: one byte changed.
cp "$T/v9.9.8.zip" "$T/flip.zip"; printf '\377' | dd of="$T/flip.zip" bs=1 seek=100 conv=notrunc status=none
cmp -s "$T/v9.9.8.zip" "$T/flip.zip" && exit 1
refuses 'is not what this checkout builds from v9.9.8' v9.9.8 "$T/flip.zip" --trusted-zip "$T/v9.9.7.zip"

# 3. The tag's tree: a symlink, then the byte check and the tripwires on the shipped PHP.
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
printf '<?php define( "puzzles_sr_update_pubkey", "x", true );\n' >includes/evil.php; odd v9.9.10 'appears outside the main file'
printf "const PUZZLES_SR_UPDATE_PUBKEY = 'x';\n" >>puzzles-site-reports.php; odd v9.9.11 'defines PUZZLES_SR_UPDATE_PUBKEY more than once'
printf "<?php \$n = 'PUZZLES_SR_' . 'UPDATE_PUBKEY';\n" >includes/evil.php; odd v9.9.15 'cannot follow'
printf "<?php echo constant( 'X' );\n" >includes/evil.php; odd v9.9.16 'cannot follow'
printf "<?php define(\n\t'X', 1 );\n" >includes/evil.php; odd v9.9.17 'cannot follow'
printf "<?php const\nPUZZLES_SR_X = 1;\n" >includes/evil.php; odd v9.9.52 'cannot follow'
printf "<?php const PUZZLES_SITE_REPORTS_MAX_PACKAGE = 1;\n" >includes/evil.php; odd v9.9.53 'defines a constant more than once'
sed -i "/^define( 'PUZZLES_SR_UPDATE_PUBKEY'/i require_once __DIR__ . '/includes/seo.php';" puzzles-site-reports.php
odd v9.9.18 'includes a file before it defines'

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

# 5. Keys and versions against the latest release (v9.9.7, v9.9.8 or v9.9.13), which must be the owner's last record.
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
refuses 'is not newer than the latest release (9.9.8)' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.8.zip"
refuses 'is not newer than the latest release (9.9.13)' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.13.zip"
refuses "GitHub's release state does not match your record" v9.9.13 "$T/v9.9.13.zip" --trusted-zip "$T/v9.9.8.zip"

# 6. A dry run refuses any key in the owner's history: here the owner's checkout is one whose history carries PUB1.
# With color.ui=always `git log -p` is coloured: the keys are read from each commit's file, not parsed from a log; the
# printed diffs stay plain.
git -C "$T/owner" checkout -q v9.9.8; git -C "$T/owner" config color.ui always
refuses 'dry run with a release key' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
grep -q $'\033' "$T/out" && { cat -v "$T/out"; echo "FAIL: a raw ESC in the output" >&2; exit 1; }
git -C "$T/owner" config --unset color.ui; git -C "$T/owner" checkout -q main

# 7. What is signed is what the owner reviewed: a clean checkout, the typed version before anything from the checkout is
# sourced (this php.sh leaves a marker when it is), a checkout whose scripts are plain ASCII, and (real runs) the tag in
# its history.
touch "$T/owner/stray"; refuses 'uncommitted changes' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"; rm "$T/owner/stray"
printf 'touch "%s/sourced"\n' "$T" >>"$T/owner/scripts/php.sh"; g -C "$T/owner" commit -q -am 'test: php.sh marker'
ANS=9.9.7; refuses 'not confirmed' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"; ANS=""
[ ! -e "$T/sourced" ] || { echo "FAIL: php.sh was sourced before the confirmation" >&2; exit 1; }
m=$(promote v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip" 2>"$T/err")
[ -e "$T/sourced" ]; grep -qxF "+touch \"$T/sourced\"" "$T/err" # sourced once confirmed; the scripts diff showed it
grep -qF 'type 9.9.8 to sign v9.9.8' "$T/err"
[ "$(verify "$m" "$T/v9.9.8.zip")" = valid ]
g -C "$T/owner" reset -q --hard HEAD~1; records v9.9.7
printf '# caf\303\251\n' >>"$T/owner/scripts/build.sh"; g -C "$T/owner" commit -q -am 'test: non-ASCII'
refuses "this checkout's scripts/build.sh $BYTE" v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
g -C "$T/owner" reset -q --hard HEAD~1
build_does() { # build_does <line> <expected refusal>: the owner's build.sh runs <line> on the staged copy
  sed -i "\\|^F=\"\$S/puzzles-site-reports.php\"\$|a $1" "$T/owner/scripts/build.sh"
  grep -qxF "$1" "$T/owner/scripts/build.sh"; g -C "$T/owner" commit -q -am "test: build.sh $1"
  refuses "$2" v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
  g -C "$T/owner" reset -q --hard HEAD~1
}
build_does 'echo x >>"$S/LICENSE"' "build of v9.9.8 changes 'LICENSE'"
build_does 'rm "$S/uninstall.php"' "build of v9.9.8 does not list exactly the tag's files"
real() { PATH="$T/bin:$PATH" TMPDIR="$T/tmp" PUZZLES_SR_SIGNING_KEY="$SK" bash "$T/owner/scripts/promote.sh" "$1" 6.8.1 2>&1; }
o=$(real v9.9.12) && exit 1; grep -qF "is not in this checkout's history" <<<"$o"
git -C "$T/owner" tag v9.9.90 # the owner's own HEAD passes that check and stops at the next one, before any gh call
o=$(real v9.9.90) && exit 1; grep -qF 'origin is not github.com' <<<"$o"
echo "ok: clean checkout, typed version before php.sh, ASCII scripts, tag in the reviewed history"

# 8. Arguments are checked before anything runs.
o=$(PUZZLES_SR_SIGNING_KEY="$SK" bash "$T/owner/scripts/promote.sh" v9.9.8 '6.8; rm -rf x' 2>&1) && exit 1; grep -qF 'bad tested' <<<"$o"
o=$(PUZZLES_SR_SIGNING_KEY= bash "$T/owner/scripts/promote.sh" v9.9.8 6.8.1 --dry-run "$T/v9.9.8.zip" 2>&1) && exit 1; grep -qF 'is not set' <<<"$o"
o=$(PUZZLES_SR_SIGNING_KEY="$SK" bash "$T/owner/scripts/promote.sh" v9.9.8 6.8.1 --trusted-zip "$T/v9.9.7.zip" 2>&1) && exit 1
grep -qF 'for dry runs only' <<<"$o"
o=$(PUZZLES_SR_SIGNING_KEY="$SK" bash "$T/owner/scripts/promote.sh" v9.9.8 6.8.1 --yes 2>&1) && exit 1; grep -qF 'unknown argument: --yes' <<<"$o"
echo "ok: bad arguments refused"
nothing_escaped
echo "promote-dry-run: all checks passed"
