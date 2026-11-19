#!/usr/bin/env bash
# Signs and promotes a release, on the owner's machine, never in CI: the signing key never lives in GitHub. Run ONLY
# through the launcher (scripts/launcher.sh, installed outside the repository: README, Release). The launcher runs this
# file, build.sh and php.sh as they were at the owner's last promotion recorded on that machine (or at a commit the
# owner reviewed by hand, --trust-checkout), from a temp dir: nothing in the checkout's worktree is run. The checkout
# (the launcher's --repo) is read through git only.
# Usage: wp-sr-promote --repo <checkout> [--trust-checkout <sha>] vX.Y.Z <tested> [--rotate] [--dry-run <zip> [--trusted-zip <zip>]]
#   PUZZLES_SR_SIGNING_KEY      the base64 secret key sites trust now (scripts/keygen.sh). The launcher and this script
#                               copy it into a shell variable and unset it first, so none of their other child processes
#                               (git, gh, the build, unzip, docker) inherits it; PHP gets it on stdin. Nothing can hide it
#                               from whatever started the launcher: put the key in the environment of that one command only.
#   <tested>                    the WordPress version the release's smoke test ran on, typed by the owner (the release notes
#                               say which). Never paste a command from release notes: anyone with write access can edit them.
#   --rotate                    the tag ships a new PUZZLES_SR_UPDATE_PUBKEY. Its secret key must be in
#                               PUZZLES_SR_NEW_SIGNING_KEY (read and unset the same way) as proof; the release is still
#                               signed with the key sites trust now.
#   --dry-run <zip>             every check, with <zip> standing in for the release's asset, except the origin URL and
#                               "the tag is in this checkout's history" (a dry run's tags are throwaway commits, and this
#                               history is what the known-key check reads); prints the manifest. It still fetches git refs
#                               from origin, but makes no gh call, and keeps its own record (refs/puzzles-sr/dry-run/),
#                               never the real one. Refuses any key in this checkout's history: dry runs use a throwaway key.
#   --trusted-zip <zip>         dry runs only: <zip> stands in for the latest release on GitHub (its key and version).
#                               Without it a dry run skips the key, version and record checks.
#
# The control is the owner's review of what step 1 prints; the checks only make it complete and hard to disguise.
# Nothing from the tag or the release is executed, sourced or unpacked; their files are only read as data.
#   1. Before the key is used:
#      a. the tag is one commit locally and on origin, on origin/main and in this checkout's history, and the checkout
#         has no uncommitted change;
#      b. the latest release on GitHub gives the key and version sites have now (its zip's main file, read as data): the
#         tag must be newer. A forged "latest" can only cause refusals;
#      c. the baseline is the owner's own record: refs/puzzles-sr/promoted/vX.Y.Z, which only this script writes, after
#         each promotion, pointing at the commit it signed (refs/puzzles-sr/pending/vX.Y.Z just before it goes live). It
#         is local: never pushed or fetched (keep it so; the launcher refuses a fetch refspec that could write it), so
#         nothing on GitHub can choose it. The baseline is the highest record, and the tag must be newer. GitHub's latest
#         release must be one the owner recorded (after a bad release is marked pre-release, an older one is latest
#         again); if it is instead the pending one of a run stopped after it went live, and its manifest verifies with
#         the record's key against its zip, the owner is offered to record it (and runs again). Anything else is refused.
#         With no record (the first promotion on this machine) the baseline is empty and everything is new;
#      d. the record's and the tag's trees assign no filter, ident, working-tree-encoding or non-LF eol attribute to a
#         shipped or scripts path; every shipped code file in the tag (the main file, uninstall.php, includes/) and every
#         file of its scripts/ and .gitattributes holds only TAB, LF and printable ASCII: no terminal control byte can
#         hide a line, no look-alike letter can pass for a known name; the main file has exactly one ` * Version: X.Y.Z`
#         line and one `define( 'PUZZLES_SITE_REPORTS_VERSION', 'X.Y.Z' );` line, the two build.sh rewrites;
#      e. it prints, through `cat -v`, from the baseline to the tag, (1) scripts/ and .gitattributes: the promotion code
#         the NEXT promotion runs (the ratchet: this run's code was shown by the promotion that recorded it), and (2) every
#         shipped file, in full. The owner reviews both and types the version (a real run: on a terminal, never piped).
#   2. Only build.sh's allowlist is exported from the tag's raw tree, blob by blob (not `git archive`, which applies
#      .gitattributes filters, LFS and export-subst). Every entry is checked before it is written: a plain path (letters,
#      digits and `._-`, no component starting with `.` or `-`: no `..`, no `\`, which Git Bash takes as a separator), a
#      name Windows writes as is (no two entries that are one name case-insensitively, no component ending in `.`, no
#      device name such as con, nul, com1 or lpt1, with or without an extension) and a regular file (no symlink, no
#      submodule); every written file must resolve inside the export. Tripwires on the shipped PHP:
#      PUZZLES_SR_UPDATE_PUBKEY is named in the main file only, defined once, before any require/include; no `constant(`,
#      no `'PUZZLES_...' .` concatenation, no `define(` or `const` without its literal name on the same line, no constant
#      defined twice. They catch the obvious only.
#   3. The reviewed build.sh builds that tree; the zip must hold exactly the tree's files, byte for byte (the main file
#      with build.sh's version rewrite), and the release zip must have the same sha256 (build.sh is byte-reproducible for
#      this: a release whose build.sh changes the zip is promoted with --trust-checkout, after reviewing it).
#   4. The signing key is the one sites trust now (for the first release, the tag's), and the tag keeps it unless
#      --rotate proves the new one. Then manifest.json (its format: README, Updates) is signed, uploaded, the release
#      marked latest (sites take it on their next check) and the promotion recorded (1c).
KEY="${PUZZLES_SR_SIGNING_KEY:-}"; NEWKEY="${PUZZLES_SR_NEW_SIGNING_KEY:-}"
unset PUZZLES_SR_SIGNING_KEY PUZZLES_SR_NEW_SIGNING_KEY
set -euo pipefail
export GIT_NO_REPLACE_OBJECTS=1
die() { echo "promote.sh: $*" >&2; exit 1; }
[ -n "${PUZZLES_SR_SCRIPTS:-}" ] || die "run it through the launcher installed outside the repository (README, Release), never from a checkout"
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/php.sh" # the launcher's reviewed copy, never the checkout's
export GH_REPO=puzzles-consulting/wp-site-reports # every gh call, whatever the checkout's remotes say
VER_RE='^[0-9]+\.[0-9]+(\.[0-9]+)?$'
KEY_RE='^[A-Za-z0-9+/]{43}=$'
TAG="${1:-}"; TESTED="${2:-}"
[[ "$TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || die "usage: wp-sr-promote --repo <checkout> [--trust-checkout <sha>] vX.Y.Z <tested> [--rotate] [--dry-run <zip> [--trusted-zip <zip>]]"
V="${BASH_REMATCH[1]}"
[[ "$TESTED" =~ $VER_RE ]] || die "bad tested: ${TESTED@Q}"
shift 2
ROTATE=""; DRY=""; TRUSTED_ZIP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rotate) ROTATE=1 ;;
    --dry-run) DRY=$(realpath "${2:?--dry-run needs a zip}"); shift ;;
    --trusted-zip) TRUSTED_ZIP=$(realpath "${2:?--trusted-zip needs a zip}"); shift ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
[ -z "$TRUSTED_ZIP" ] || [ -n "$DRY" ] || die "--trusted-zip is for dry runs only"
[ -n "$KEY" ] || die "PUZZLES_SR_SIGNING_KEY is not set"
if [ -n "$ROTATE" ]; then [ -n "$NEWKEY" ] || die "--rotate needs the new secret key in PUZZLES_SR_NEW_SIGNING_KEY"
else [ -z "$NEWKEY" ] || die "PUZZLES_SR_NEW_SIGNING_KEY is set without --rotate"; fi

cd "$(git rev-parse --show-toplevel)"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pubkey_of() { tr -d '\r' | sed -n "s/^define( 'PUZZLES_SR_UPDATE_PUBKEY', '\([^']*\)' );\$/\1/p"; } # stdin: a main file
ascii() { [ "$(LC_ALL=C tr -d '\11\12\40-\176' | wc -c)" -eq 0 ]; } # stdin: a file; only TAB, LF and printable ASCII
confirm() { # confirm <what the owner types> <prompt>
  [ -n "$DRY" ] || [ -t 0 ] || die "a real run takes your confirmation from a terminal, never from a pipe or a file"
  printf 'promote.sh: %s: ' "$2" >&2
  read -r ANS || true
  [ "$ANS" = "$1" ] || die "not confirmed"
}
SHIP=(puzzles-site-reports.php uninstall.php README.md CHANGELOG.md LICENSE includes) # build.sh's allowlist
CODE=(puzzles-site-reports.php uninstall.php includes)                                # the shipped PHP
REC=refs/puzzles-sr/promoted; [ -z "$DRY" ] || REC=refs/puzzles-sr/dry-run/promoted   # the owner's record (1c)
PEND=refs/puzzles-sr/pending                                                          # real runs only (1c)
# build.sh's version rewrite, exactly as it does it (both lines anchored; 1d requires one of each)
VSED="s/^( \* Version:) +[0-9]+\.[0-9]+\.[0-9]+\$/\1 $V/; s/^(define\( 'PUZZLES_SITE_REPORTS_VERSION', ')[0-9]+\.[0-9]+\.[0-9]+(' \);)\$/\1$V\2/"

# 1a. The tag: one commit, locally and on origin, on main, and in this checkout's history.
COMMIT=$(git rev-parse --verify --quiet "refs/tags/$TAG^{commit}") || die "no local tag $TAG"
[ -z "$(git status --porcelain)" ] || die "this checkout has uncommitted changes: promote from a clean, reviewed checkout"
if [ -z "$DRY" ]; then
  git merge-base --is-ancestor "$COMMIT" HEAD || die "$TAG ($COMMIT) is not in this checkout's history: review main up to it first"
  [[ "$(git config --get remote.origin.url)" =~ ^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)$GH_REPO(\.git)?$ ]] \
    || die "origin is not github.com/$GH_REPO"
fi
git fetch --quiet --no-tags origin main
REMOTE=$(git ls-remote origin "refs/tags/$TAG" "refs/tags/$TAG^{}" | sort -k2 | tail -1 | cut -f1) # the peeled line sorts last
[ "$REMOTE" = "$COMMIT" ] || die "origin's $TAG is '${REMOTE:-missing}', the local one is $COMMIT"
git merge-base --is-ancestor "$COMMIT" origin/main || die "$TAG ($COMMIT) is not on origin/main"

# 1b. The key and version sites have now: the latest release's (none yet: the first release trusts its own key).
CURZIP=""; TRUSTED=""; CURV=""; FIRST=""
if [ -n "$DRY" ]; then CURZIP=$TRUSTED_ZIP
elif CUR=$(gh api "repos/$GH_REPO/releases/latest" --jq .tag_name 2>"$W/gh-err"); then
  [[ "$CUR" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the latest release's tag is ${CUR@Q}"
  mkdir "$W/cur"; gh release download "$CUR" --pattern puzzles-site-reports.zip --dir "$W/cur"; CURZIP="$W/cur/puzzles-site-reports.zip"
else
  grep -q 'HTTP 404' "$W/gh-err" || { cat "$W/gh-err" >&2; die "could not read the latest release"; }
  [ -z "$ROTATE" ] || die "--rotate, but no release was promoted yet"
  FIRST=1
fi
if [ -n "$CURZIP" ]; then # read as data: one file to stdout, nothing extracted
  CURMAIN=$(unzip -p "$CURZIP" puzzles-site-reports/puzzles-site-reports.php | tr -d '\r')
  TRUSTED=$(pubkey_of <<<"$CURMAIN")
  CURV=$(sed -n 's/^ \* Version: *//p' <<<"$CURMAIN" | head -1)
  [[ "$TRUSTED" =~ $KEY_RE && "$CURV" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "cannot read the latest release's key and version"
fi

# 1c. The baseline: the highest promotion recorded on this machine, never anything fetched.
MAN_RE='^[{]"version":"([0-9.]+)","sha256":"([0-9a-f]{64})","requires":"([0-9.]+)","requires_php":"([0-9.]+)","tested":"([0-9.]+)","signature":"([A-Za-z0-9+/]{86}==)"[}]$'
recover() { # GitHub's latest is v$CURV, pending here: a run that made it latest was stopped before recording it
  local pc k m f msg
  pc=$(git rev-parse --verify "$PEND/v$CURV^{commit}")
  k=$(git cat-file blob "${LAST:-$pc}:puzzles-site-reports.php" | pubkey_of) # the key it was signed with: the record's
  mkdir "$W/curm"; gh release download "v$CURV" --pattern manifest.json --dir "$W/curm"
  m=$(head -c 1024 "$W/curm/manifest.json" | tr -d '\r\n')
  [[ "$m" =~ $MAN_RE ]] || die "v$CURV's manifest.json is not one this script writes"
  f=("${BASH_REMATCH[@]:1}"); msg="${f[0]}"$'\n'"${f[1]}"$'\n'"${f[2]}"$'\n'"${f[3]}"$'\n'"${f[4]}"
  [ "${f[0]}" = "$CURV" ] && [ "${f[1]}" = "$(sha256sum "$CURZIP" | cut -c1-64)" ] || die "v$CURV's manifest does not match its release zip"
  [ "$(printf '%s\n%s\n%s' "$k" "${f[5]}" "$msg" | php_run -r '
$pk = base64_decode( trim( (string) fgets( STDIN ) ), true );
$sig = base64_decode( trim( (string) fgets( STDIN ) ), true );
$ok = is_string( $pk ) && is_string( $sig ) && SODIUM_CRYPTO_SIGN_PUBLICKEYBYTES === strlen( $pk ) && SODIUM_CRYPTO_SIGN_BYTES === strlen( $sig );
echo $ok && sodium_crypto_sign_verify_detached( $sig, stream_get_contents( STDIN ), $pk ) ? "valid" : "invalid";
' | tr -d '\r')" = valid ] || die "v$CURV's manifest is not signed by the key of your record (${k:-none})"
  echo "promote.sh: GitHub's latest release, v$CURV, was signed and made latest by a run on this machine that did not record it ($PEND/v$CURV -> $pc); its manifest is signed by your key and matches its zip" >&2
  confirm "$CURV" "type $CURV to record v$CURV as promoted"
  git update-ref -m "promote.sh: recorded after an interrupted run" "$REC/v$CURV" "$pc"; git update-ref -d "$PEND/v$CURV"
  echo "recorded v$CURV as promoted ($REC/v$CURV); run again to promote $TAG"
  exit 0
}
LAST=$(git for-each-ref --sort=-version:refname --count=1 --format='%(refname)' "$REC"); LV=""
if [ -n "$LAST" ]; then
  LV=${LAST##*/}
  [[ "$LV" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "${LAST@Q} is not a record this script wrote"
  BASE=$(git rev-parse --verify "$LAST^{commit}"); BL="$LV, your last promotion recorded on this machine ($LAST)"
else
  BASE=$(git hash-object -t tree --stdin </dev/null); BL="none: first promotion recorded on this machine: everything is new"
fi
CURREC=""; [ -z "$CURV" ] || ! git rev-parse --quiet --verify "$REC/v$CURV" >/dev/null || CURREC=1
if [ -n "$CURV" ] && [ -z "$CURREC" ] && [ -z "$DRY" ] && git rev-parse --quiet --verify "$PEND/v$CURV" >/dev/null; then recover; fi
if [ -n "$LAST" ] && { [ -n "$FIRST" ] || { [ -n "$CURV" ] && [ -z "$CURREC" ]; }; }; then
  die "the latest release on GitHub is ${CURV:+v}${CURV:-none}, not a promotion recorded on this machine (your last: $LV): GitHub's release state does not match your record; find out why before promoting anything (README, Release)"
fi
[ -z "$CURV" ] || printf '%s\n' "$CURV" "$V" | sort -VCu || die "$TAG is not newer than the latest release ($CURV)"
[ -z "$LV" ] || printf '%s\n' "${LV#v}" "$V" | sort -VCu || die "$TAG is not newer than your last promotion recorded on this machine ($LV)"

# 1d. Nothing reviewed below can change on checkout, carry a control byte or a non-ASCII letter, or hide a version line.
attrs() { # attrs <commit> <name>
  local p a v bad=""
  while IFS= read -r -d '' p && IFS= read -r -d '' a && IFS= read -r -d '' v; do
    case "$a=$v" in *=unspecified | *=unset | eol=lf) ;; *) bad+=" ${p@Q}: $a=$v;" ;; esac
  done < <(git ls-tree -r -z --name-only --full-tree "$1" -- "${SHIP[@]}" scripts .gitattributes \
    | git check-attr -z --source="$1" --stdin filter ident working-tree-encoding eol)
  [ -z "$bad" ] || die "$2 assigns git attributes that change a file on checkout:$bad"
}
[ -z "$LAST" ] || attrs "$BASE" "your record $LV"
attrs "$COMMIT" "$TAG"
while IFS= read -r -d '' e; do
  [[ "${e%%$'\t'*}" == *" blob "* ]] || continue # a submodule is refused in step 2
  sha="${e%%$'\t'*}"; sha="${sha##* }"; p="${e#*$'\t'}"
  git cat-file blob "$sha" | ascii || die "$TAG's ${p@Q} has a byte other than TAB, LF and printable ASCII (a terminal control byte or a look-alike letter)"
done < <(git ls-tree -r -z --full-tree "$COMMIT" -- "${CODE[@]}" scripts .gitattributes)
MAINB=$(git cat-file blob "$COMMIT:puzzles-site-reports.php" 2>/dev/null) || die "$TAG has no puzzles-site-reports.php"
lines() { grep -cE "$1" <<<"$MAINB" || true; }
[ "$(lines '^ \* Version:')" = 1 ] && [ "$(lines '^ \* Version: +[0-9]+\.[0-9]+\.[0-9]+$')" = 1 ] \
  && [ "$(lines "define\( 'PUZZLES_SITE_REPORTS_VERSION', '[^']*' \);")" = 1 ] \
  && [ "$(lines "^define\( 'PUZZLES_SITE_REPORTS_VERSION', '[0-9]+\.[0-9]+\.[0-9]+' \);$")" = 1 ] \
  || die "$TAG's main file needs exactly one ' * Version: X.Y.Z' line and one \"define( 'PUZZLES_SITE_REPORTS_VERSION', 'X.Y.Z' );\" line, and no other line like them (build.sh rewrites both)"

# 1e. What the owner confirms: the promotion code of the next run, and everything the tag ships.
D=(git --no-pager diff --no-color --no-ext-diff --no-textconv --text)
{
  echo "promote.sh: running the promotion scripts of $PUZZLES_SR_SCRIPTS"
  echo "promote.sh: baseline: $BL"
  echo "promote.sh: (1) the promotion code your NEXT promotion runs once $TAG is recorded: scripts/ and .gitattributes, baseline -> $TAG:"
  "${D[@]}" "$BASE" "$COMMIT" -- scripts/ .gitattributes | cat -v
  echo "promote.sh: (2) every file $TAG ships, baseline -> $TAG, in full:"
  "${D[@]}" "$BASE" "$COMMIT" -- "${SHIP[@]}" | cat -v
} >&2
confirm "$V" "review both diffs above, then type $V to sign $TAG"

# 2. The tag's raw tree: the allowlist only, each entry checked before it is written.
T="$W/tree"; mkdir "$T"; TR=$(realpath "$T")
PATH_RE='^[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*$'
DEV_RE='/(con|prn|aux|nul|com[0-9]|lpt[0-9])(\.[^/]*)?/'
declare -A SEEN # lowercased path -> f (a file) or d (a directory)
mapfile -d '' ENTRIES < <(git ls-tree -r -z --full-tree "$COMMIT" -- "${SHIP[@]}")
for e in "${ENTRIES[@]}"; do
  p="${e#*$'\t'}"; read -r mode _ sha <<<"${e%%$'\t'*}"; l="${p,,}"
  [[ "$p" =~ $PATH_RE ]] || die "$TAG has the path ${p@Q}"
  [ "$mode" = 100644 ] || [ "$mode" = 100755 ] || die "$TAG has ${p@Q} with mode $mode (a symlink or a submodule)"
  [[ ! "/$l/" =~ $DEV_RE ]] || die "$TAG's ${p@Q} has a reserved device name on Windows"
  [[ "$p/" != *./* ]] || die "$TAG's ${p@Q} has a name ending in '.', which Windows drops"
  [ -z "${SEEN[$l]:-}" ] || die "$TAG's ${p@Q} and another entry are one name on Windows (case-insensitive)"
  SEEN[$l]=f; d=$l
  while [[ "$d" == */* ]]; do
    d=${d%/*}; [ "${SEEN[$d]:-d}" = d ] || die "$TAG's ${p@Q} and another entry are one name on Windows (case-insensitive)"
    SEEN[$d]=d
  done
  mkdir -p -- "$T/$(dirname -- "$p")"
  git cat-file blob "$sha" >"$T/$p"
  case "$(realpath -- "$T/$p")" in "$TR"/*) ;; *) die "$TAG's ${p@Q} was written outside the export" ;; esac
done
MAINF="$T/puzzles-site-reports.php"
[ -f "$MAINF" ] || die "$TAG has no puzzles-site-reports.php"
# Tripwires (header, 2). grep -a: a file grep takes for binary is still read.
HITS=$(cd "$T" && { grep -rlia PUZZLES_SR_UPDATE_PUBKEY "${CODE[@]}" 2>/dev/null || true; })
[ "$HITS" = puzzles-site-reports.php ] || die "PUZZLES_SR_UPDATE_PUBKEY appears outside the main file in $TAG: $(echo $HITS)"
[ "$(grep -ciaE '(define|const)[^;]*PUZZLES_SR_UPDATE_PUBKEY' "$MAINF")" = 1 ] || die "$TAG defines PUZZLES_SR_UPDATE_PUBKEY more than once"
CONST_RE='(^|[^A-Za-z0-9_$>:])const([^A-Za-z0-9_]|$)'
ODD=$(cd "$T" && {
  grep -rniaE "constant[[:space:]]*\(|PUZZLES_[A-Z0-9_]*['\"][[:space:]]*\." "${CODE[@]}" 2>/dev/null || true
  grep -rniaE 'define[[:space:]]*\(' "${CODE[@]}" 2>/dev/null \
    | grep -viaE "define[[:space:]]*\([[:space:]]*['\"][A-Z0-9_]+['\"][[:space:]]*," || true
  grep -rniaE "$CONST_RE" "${CODE[@]}" 2>/dev/null | grep -viaE 'const[[:space:]]+[A-Z0-9_]+[[:space:]]*=.*;' || true
})
[ -z "$ODD" ] || die "$TAG's shipped PHP names a constant in a way these checks cannot follow: $ODD"
TWICE=$(cd "$T" && { grep -rhoiaE "define[[:space:]]*\([[:space:]]*['\"][A-Z0-9_]+|$CONST_RE[[:space:]]*[A-Z0-9_]+" "${CODE[@]}" 2>/dev/null || true; } \
  | grep -oiaE '[A-Z0-9_]+$' | tr a-z A-Z | sort | uniq -d)
[ -z "$TWICE" ] || die "$TAG's shipped PHP defines a constant more than once: $(echo $TWICE)"
NEWPUB=$(pubkey_of <"$MAINF")
[[ "$NEWPUB" =~ $KEY_RE ]] || die "$TAG's PUZZLES_SR_UPDATE_PUBKEY is not one base64 Ed25519 public key: '$NEWPUB'"
DEFL=$(grep -naE "^define\( 'PUZZLES_SR_UPDATE_PUBKEY'" "$MAINF" | cut -d: -f1)
INCL=$(grep -naiE '^[[:space:]]*(require|include)(_once)?[[:space:](]' "$MAINF" | head -1 | cut -d: -f1)
[ -z "$INCL" ] || [ "$DEFL" -lt "$INCL" ] || die "$TAG's main file includes a file before it defines PUZZLES_SR_UPDATE_PUBKEY"
MAIN=$(tr -d '\r' <"$MAINF")
hdr() { sed -n "s/^ \* $1: *//p" <<<"$MAIN" | head -1; }
REQ="$(hdr 'Requires at least')"; REQPHP="$(hdr 'Requires PHP')"
[[ "$REQ" =~ $VER_RE && "$REQPHP" =~ $VER_RE ]] || die "bad Requires header: '$REQ' '$REQPHP'"

# 3. The reviewed build.sh's build of that tree holds exactly its files, and the release zip is the same bytes.
bash "$HERE/build.sh" "$V" --src "$T" --out "$W/build" >/dev/null
BZ="$W/build/puzzles-site-reports.zip"
mkdir "$W/want" "$W/got"; cp -R "$T" "$W/want/puzzles-site-reports"
sed -i -E "$VSED" "$W/want/puzzles-site-reports/puzzles-site-reports.php"
unzip -q "$BZ" -d "$W/got" # our own build of the checked tree
diff -rq "$W/want" "$W/got" >&2 || die "the reviewed build.sh's zip of $TAG does not hold exactly the tag's files, byte for byte"
BUILT=$(sha256sum "$BZ" | cut -c1-64)
if [ -n "$DRY" ]; then ZIP=$DRY
else mkdir "$W/rel"; gh release download "$TAG" --pattern puzzles-site-reports.zip --dir "$W/rel"; ZIP="$W/rel/puzzles-site-reports.zip"; fi
SHA=$(sha256sum "$ZIP" | cut -c1-64)
[ "$SHA" = "$BUILT" ] || die "the release zip (sha256 $SHA) is not what the reviewed build.sh builds from $TAG ($BUILT)"

# 4. Sign. stdin: the key, the new key (or an empty line), then the message exactly. Prints "<pub> <new pub or -> <sig>".
[ -z "$FIRST" ] || TRUSTED=$NEWPUB
MSG="$V"$'\n'"$SHA"$'\n'"$REQ"$'\n'"$REQPHP"$'\n'"$TESTED"
OUT=$(printf '%s\n%s\n%s' "$KEY" "$NEWKEY" "$MSG" | php_run -r '
$sk = function ( $line ) {
	$k = base64_decode( trim( (string) $line ), true );
	if ( ! is_string( $k ) || SODIUM_CRYPTO_SIGN_SECRETKEYBYTES !== strlen( $k ) ) { fwrite( STDERR, "not a base64 Ed25519 secret key\n" ); exit( 1 ); }
	return $k;
};
$k = $sk( fgets( STDIN ) );
$n = trim( (string) fgets( STDIN ) );
$np = "" === $n ? "-" : base64_encode( sodium_crypto_sign_publickey_from_secretkey( $sk( $n ) ) );
echo base64_encode( sodium_crypto_sign_publickey_from_secretkey( $k ) ), " ", $np, " ", base64_encode( sodium_crypto_sign_detached( stream_get_contents( STDIN ), $k ) );
' | tr -d '\r')
read -r PUB PROOF SIG <<<"$OUT"
[[ "$PUB" =~ $KEY_RE && "$SIG" =~ ^[A-Za-z0-9+/]{86}==$ ]] || die "signing failed"

if [ -n "$ROTATE" ]; then
  [ "$PROOF" = "$NEWPUB" ] || die "PUZZLES_SR_NEW_SIGNING_KEY is not the secret key of $TAG's PUZZLES_SR_UPDATE_PUBKEY ($NEWPUB)"
fi
if [ -n "$TRUSTED" ]; then
  [ "$PUB" = "$TRUSTED" ] || die "the signing key's public key ($PUB) is not the one sites trust now ($TRUSTED)"
  if [ -n "$ROTATE" ]; then
    [ "$NEWPUB" != "$TRUSTED" ] || die "--rotate, but $TAG keeps the key sites trust now"
    echo "promote.sh: rotating: after $TAG, sites trust only $NEWPUB" >&2
  else
    [ "$NEWPUB" = "$TRUSTED" ] || die "$TAG changes the release key to $NEWPUB; pass --rotate (with PUZZLES_SR_NEW_SIGNING_KEY) if that is intended"
  fi
else
  echo "promote.sh: dry run without --trusted-zip: the key, version and record checks are skipped" >&2
fi
if [ -n "$DRY" ]; then # every release key this checkout's history ever carried, read from each commit's main file
  KNOWN=$(for c in $(git rev-list HEAD -- puzzles-site-reports.php); do
    git cat-file blob "$c:puzzles-site-reports.php" 2>/dev/null | pubkey_of || true # a commit that deletes it has none
  done)
  ! grep -qxF -- "$PUB" <<<"$KNOWN" || die "dry run with a release key: use a throwaway key (scripts/keygen.sh)"
fi

printf '{"version":"%s","sha256":"%s","requires":"%s","requires_php":"%s","tested":"%s","signature":"%s"}\n' \
  "$V" "$SHA" "$REQ" "$REQPHP" "$TESTED" "$SIG" >"$W/manifest.json"
if [ -n "$DRY" ]; then cat "$W/manifest.json"; git update-ref -m "promote.sh --dry-run" "$REC/$TAG" "$COMMIT"; exit 0; fi
git update-ref -m "promote.sh: going live" "$PEND/$TAG" "$COMMIT" # 1c: a run stopped after the edit below is recoverable
gh release upload "$TAG" "$W/manifest.json" --clobber
gh release edit "$TAG" --prerelease=false --latest
git update-ref -m "promote.sh" "$REC/$TAG" "$COMMIT"; git update-ref -d "$PEND/$TAG" # the record: local only, never pushed
echo "promoted $TAG (sha256 $SHA); recorded as $REC/$TAG"
