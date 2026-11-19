#!/usr/bin/env bash
# Offline check of scripts/promote.sh --dry-run on the committed HEAD. A local bare repository is `origin`; a "dev" clone
# pushes tagged commits (each carrying a throwaway public key) and builds their release zips as CI does; the "owner" clone
# stays on HEAD (only real keys in its history) and runs promote.sh. Throwaway keys only, never a real one. Everything is
# written under one temp dir, promote.sh's own temp dirs included (TMPDIR).
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

# Throwaway keypairs: public keys in PUBn, secret keys in SKn (the third one's public key is never needed).
PUB1=$(bash scripts/keygen.sh 3>"$T/sk1"); SK1=$(cat "$T/sk1")
PUB2=$(bash scripts/keygen.sh 3>"$T/sk2"); SK2=$(cat "$T/sk2")
bash scripts/keygen.sh 3>"$T/sk3" >/dev/null; SK3=$(cat "$T/sk3")
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
SK=$SK1; NSK=""; Y=--yes
promote() { # promote <tag> <zip> [options]: as the owner, signing with $SK (and $NSK as the new key); $Y skips the prompt
  local tag=$1 zip=$2; shift 2
  PATH="$T/bin:$PATH" TMPDIR="$T/tmp" PUZZLES_SR_SIGNING_KEY="$SK" PUZZLES_SR_NEW_SIGNING_KEY="$NSK" \
    bash "$T/owner/scripts/promote.sh" "$tag" 6.8.1 --dry-run "$zip" $Y "$@"
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

# 2. The release zip is not this checkout's build of the tag: one byte changed.
cp "$T/v9.9.8.zip" "$T/flip.zip"; printf '\377' | dd of="$T/flip.zip" bs=1 seek=100 conv=notrunc status=none
cmp -s "$T/v9.9.8.zip" "$T/flip.zip" && exit 1
refuses 'is not what this checkout builds from v9.9.8' v9.9.8 "$T/flip.zip" --trusted-zip "$T/v9.9.7.zip"

# 3. The tag's tree: a symlink, then the tripwires on the shipped PHP.
g update-index --add --cacheinfo "120000,$(printf x | git hash-object -w --stdin),includes/link.php"
g commit -q -m 'test: symlink'; git push -q origin HEAD:main; tag v9.9.9
refuses "has 'includes/link.php' with mode 120000" v9.9.9 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
back_to v9.9.8
odd() { # odd <tag> <expected refusal>: dev's worktree changes, committed and tagged, are refused
  g add -A; g commit -q -m "test: $1"; git push -q origin HEAD:main; tag "$1"
  refuses "$2" "$1" "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
  back_to v9.9.8
}
printf '<?php define( "puzzles_sr_update_pubkey", "x", true );\n' >includes/evil.php; odd v9.9.10 'appears outside the main file'
printf 'PUZZLES_SR_UPDATE_PUBKEY\0' >includes/evil.bin; odd v9.9.14 'appears outside the main file' # grep -I would skip it
printf "const PUZZLES_SR_UPDATE_PUBKEY = 'x';\n" >>puzzles-site-reports.php; odd v9.9.11 'defines PUZZLES_SR_UPDATE_PUBKEY more than once'
printf "<?php \$n = 'PUZZLES_SR_' . 'UPDATE_PUBKEY';\n" >includes/evil.php; odd v9.9.15 'cannot follow'
printf "<?php echo constant( 'X' );\n" >includes/evil.php; odd v9.9.16 'cannot follow'
printf "<?php define(\n\t'X', 1 );\n" >includes/evil.php; odd v9.9.17 'cannot follow'
sed -i "/^define( 'PUZZLES_SR_UPDATE_PUBKEY'/i require_once __DIR__ . '/includes/seo.php';" puzzles-site-reports.php
odd v9.9.18 'includes a file before it defines'

# 3b. Entry names no checkout could write (git mktree). Git Bash takes `\` as a separator: on Windows these would land
# outside the export, in $T/tmp. Outside the allowlist they are ignored (the release signs); inside it, refused.
graft() { # graft <tag> <dir> <name> [tree]: tags a commit on main: v9.9.8's tree plus, at <dir>/<name> (<dir> "." for
  local b e root sub c # the root), a blob, or with "tree" a subtree holding x
  b=$(printf 'escaped\n' | git hash-object -w --stdin); e="100644 blob $b"
  [ "${4:-}" != tree ] || e="040000 tree $(printf '100644 blob %s\tx\0' "$b" | git mktree -z)"
  root=$(git rev-parse 'v9.9.8^{tree}')
  if [ "$2" = . ]; then root=$({ git ls-tree -z "$root"; printf '%s\t%s\0' "$e" "$3"; } | git mktree -z)
  else
    sub=$({ git ls-tree -z "$root:$2"; printf '%s\t%s\0' "$e" "$3"; } | git mktree -z)
    root=$({ git ls-tree -z "$root" | grep -zv $'\t'"$2"'$'; printf '040000 tree %s\t%s\0' "$sub" "$2"; } | git mktree -z)
  fi
  c=$(g commit-tree -p "$(git rev-parse 'v9.9.8^{commit}')" -m "test: $3" "$root")
  git push -q origin "$c:refs/heads/main"; tag "$1" "$c"
}
n=20
for name in '..\..\escaped' 'a\..\..\..\x' '-x' '.hidden' '..'; do # the first two would land in $T/tmp
  graft "v9.9.$n" . "$name" "$([ "$name" = .. ] && echo tree || true)"; zip_of "v9.9.$n"
  promote "v9.9.$n" "$T/v9.9.$n.zip" --trusted-zip "$T/v9.9.8.zip" >"$T/out" 2>&1 \
    || { cat "$T/out"; echo "FAIL: ${name@Q} outside the allowlist was not ignored" >&2; exit 1; }
  nothing_escaped; back_to v9.9.8; n=$((n + 1))
done
for name in '..\..\..\escaped' 'a\..\..\..\..\x' '-x' '.hidden' '..'; do
  graft "v9.9.$n" includes "$name" "$([ "$name" = .. ] && echo tree || true)"
  refuses 'has the path' "v9.9.$n" "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
  nothing_escaped; back_to v9.9.8; n=$((n + 1))
done
echo "ok: hostile names ignored outside the allowlist, refused inside it; nothing escaped"
# The raw tree, not `git archive`: with this .gitattributes an archive would drop includes/seo.php and fail the match.
printf 'includes/seo.php export-ignore\n' >>.gitattributes; g add .gitattributes; release v9.9.30 "$PUB1"
promote v9.9.30 "$T/v9.9.30.zip" --trusted-zip "$T/v9.9.8.zip" >"$T/out" 2>&1 || { cat "$T/out"; exit 1; }
back_to v9.9.8
echo "ok: .gitattributes does not change the export"

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
# With color.ui=always `git log -p` is coloured: the keys are read from each commit's file, not parsed from a log.
git -C "$T/owner" checkout -q v9.9.8; git -C "$T/owner" config color.ui always
refuses 'dry run with a release key' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"
git -C "$T/owner" config --unset color.ui; git -C "$T/owner" checkout -q main

# 7. What is signed is what the owner reviewed: a clean checkout, the typed version and (real runs) the tag in its history.
touch "$T/owner/stray"; refuses 'uncommitted changes' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip"; rm "$T/owner/stray"
Y=""
refuses 'not confirmed' v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip" <<<9.9.7
m=$(promote v9.9.8 "$T/v9.9.8.zip" --trusted-zip "$T/v9.9.7.zip" <<<9.9.8 2>"$T/err")
grep -qF 'what v9.9.8 ships, against v9.9.7' "$T/err"; grep -qF 'type 9.9.8 to sign v9.9.8' "$T/err"
[ "$(verify "$m" "$T/v9.9.8.zip")" = valid ]
Y=--yes
real() { PATH="$T/bin:$PATH" TMPDIR="$T/tmp" PUZZLES_SR_SIGNING_KEY="$SK" bash "$T/owner/scripts/promote.sh" "$1" 6.8.1 2>&1; }
o=$(real v9.9.12) && exit 1; grep -qF "is not in this checkout's history" <<<"$o"
git -C "$T/owner" tag v9.9.40 # the owner's own HEAD passes that check and stops at the next one, before any gh call
o=$(real v9.9.40) && exit 1; grep -qF 'origin is not github.com' <<<"$o"
echo "ok: clean checkout, typed version, tag in the reviewed history"

# 8. Arguments are checked before anything runs.
o=$(PUZZLES_SR_SIGNING_KEY="$SK" bash "$T/owner/scripts/promote.sh" v9.9.8 '6.8; rm -rf x' 2>&1) && exit 1; grep -qF 'bad tested' <<<"$o"
o=$(PUZZLES_SR_SIGNING_KEY= bash "$T/owner/scripts/promote.sh" v9.9.8 6.8.1 --dry-run "$T/v9.9.8.zip" 2>&1) && exit 1; grep -qF 'is not set' <<<"$o"
o=$(PUZZLES_SR_SIGNING_KEY="$SK" bash "$T/owner/scripts/promote.sh" v9.9.8 6.8.1 --trusted-zip "$T/v9.9.7.zip" 2>&1) && exit 1
grep -qF 'for dry runs only' <<<"$o"
o=$(PUZZLES_SR_SIGNING_KEY="$SK" bash "$T/owner/scripts/promote.sh" v9.9.8 6.8.1 --yes 2>&1) && exit 1; grep -qF -- '--yes is for dry runs only' <<<"$o"
echo "ok: bad arguments refused"
nothing_escaped
echo "promote-dry-run: all checks passed"
