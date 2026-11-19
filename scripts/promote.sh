#!/usr/bin/env bash
# Signs and promotes a release. Run by the owner on their own machine, from a reviewed checkout of main (this script and
# scripts/build.sh are what run), never in CI: the signing key never lives in GitHub.
# Usage: bash scripts/promote.sh vX.Y.Z <tested> [--rotate] [--dry-run <zip> [--trusted-zip <zip>]]
#   PUZZLES_SR_SIGNING_KEY      the base64 secret key sites trust now (scripts/keygen.sh). The script copies it into a
#                               shell variable and unsets it before running anything, so none of its child processes (git,
#                               gh, the build, unzip, docker) inherits it; PHP gets it on stdin. It cannot hide the key from
#                               whatever started the script: put the key in the environment of this one command only.
#   <tested>                    the WordPress version the release's smoke test ran on, typed by the owner (the release notes
#                               say which). Never paste a command from release notes: anyone with write access can edit them.
#   --rotate                    the tag ships a new PUZZLES_SR_UPDATE_PUBKEY. Its secret key must be in
#                               PUZZLES_SR_NEW_SIGNING_KEY (read and unset the same way) as proof; the release is still
#                               signed with the key sites trust now.
#   --dry-run <zip>             every check, with <zip> standing in for the release's asset; prints the manifest. It still
#                               fetches git refs from origin, but makes no gh call (no release download, upload or edit).
#                               Refuses any key in this checkout's history: dry runs use a throwaway key.
#   --trusted-zip <zip>         dry runs only: <zip> stands in for the latest promoted release (its key and version).
#                               Without it a dry run skips the key and version checks.
# Nothing from the tag or the release is executed, sourced or unpacked; their files are only read as data:
#   1. the tag is one commit locally and on origin, and that commit is on origin/main;
#   2. its raw tree is exported blob by blob (not `git archive`, which applies .gitattributes filters, LFS and
#      export-subst), refusing symlinks and submodules, and PUZZLES_SR_UPDATE_PUBKEY is defined once, in the main file
#      only (no shipped PHP mentions it elsewhere);
#   3. THIS checkout's scripts/build.sh builds that tree, and the release zip must have exactly the same sha256;
#   4. the signing key is the one sites trust now (the latest promoted release's; for the first release, the tag's), the
#      tag keeps it unless --rotate proves the new one, and the version is greater than the latest's;
#   5. manifest.json (its format: README, Updates) is signed, uploaded, and the release marked latest: sites take it on
#      their next check.
set -euo pipefail
die() { echo "promote.sh: $*" >&2; exit 1; }
export GH_REPO=puzzles-consulting/wp-site-reports # every gh call, whatever the checkout's remotes say
VER_RE='^[0-9]+\.[0-9]+(\.[0-9]+)?$'
KEY_RE='^[A-Za-z0-9+/]{43}=$'
TAG="${1:-}"; TESTED="${2:-}"
[[ "$TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || die "usage: promote.sh vX.Y.Z <tested> [--rotate] [--dry-run <zip> [--trusted-zip <zip>]]"
V="${BASH_REMATCH[1]}"
[[ "$TESTED" =~ $VER_RE ]] || die "bad tested: '$TESTED'"
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
KEY="${PUZZLES_SR_SIGNING_KEY:-}"; NEWKEY="${PUZZLES_SR_NEW_SIGNING_KEY:-}"
unset PUZZLES_SR_SIGNING_KEY PUZZLES_SR_NEW_SIGNING_KEY
[ -n "$KEY" ] || die "PUZZLES_SR_SIGNING_KEY is not set"
if [ -n "$ROTATE" ]; then [ -n "$NEWKEY" ] || die "--rotate needs the new secret key in PUZZLES_SR_NEW_SIGNING_KEY"
else [ -z "$NEWKEY" ] || die "PUZZLES_SR_NEW_SIGNING_KEY is set without --rotate"; fi

cd "$(dirname "$0")/.."
. scripts/php.sh
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pubkey_of() { tr -d '\r' | sed -n "s/^define( 'PUZZLES_SR_UPDATE_PUBKEY', '\([^']*\)' );\$/\1/p"; } # stdin: a main file

# 1. The tag: one commit, locally and on origin, and on main.
if [ -z "$DRY" ]; then
  [[ "$(git remote get-url origin)" =~ github\.com[:/]$GH_REPO(\.git)?$ ]] || die "origin is not github.com/$GH_REPO"
fi
git fetch --quiet --no-tags origin main
COMMIT=$(git rev-parse --verify --quiet "refs/tags/$TAG^{commit}") || die "no local tag $TAG"
REMOTE=$(git ls-remote origin "refs/tags/$TAG" "refs/tags/$TAG^{}" | sort -k2 | tail -1 | cut -f1) # the peeled line sorts last
[ "$REMOTE" = "$COMMIT" ] || die "origin's $TAG is '${REMOTE:-missing}', the local one is $COMMIT"
git merge-base --is-ancestor "$COMMIT" origin/main || die "$TAG ($COMMIT) is not on origin/main"

# 2. The tag's raw tree, blob by blob.
T="$W/tree"; mkdir "$T"
while IFS= read -r -d '' e; do
  p="${e#*$'\t'}"; read -r mode _ sha <<<"${e%%$'\t'*}"
  [ "$mode" = 100644 ] || [ "$mode" = 100755 ] || die "$TAG has '$p' with mode $mode (a symlink or a submodule)"
  case "/$p/" in */../* | */./*) die "$TAG has the path '$p'" ;; esac
  mkdir -p "$T/$(dirname "$p")"
  git cat-file blob "$sha" >"$T/$p"
done < <(git ls-tree -r -z --full-tree "$COMMIT")
MAINF="$T/puzzles-site-reports.php"
[ -f "$MAINF" ] || die "$TAG has no puzzles-site-reports.php"
# The shipped PHP (the build's allowlist minus its three text files) names the key in the main file only, defined once.
HITS=$(cd "$T" && { grep -rliI PUZZLES_SR_UPDATE_PUBKEY puzzles-site-reports.php uninstall.php includes 2>/dev/null || true; })
[ "$HITS" = puzzles-site-reports.php ] || die "PUZZLES_SR_UPDATE_PUBKEY appears outside the main file in $TAG: $(echo $HITS)"
[ "$(grep -ciE '(define|const)[^;]*PUZZLES_SR_UPDATE_PUBKEY' "$MAINF")" = 1 ] || die "$TAG defines PUZZLES_SR_UPDATE_PUBKEY more than once"
NEWPUB=$(pubkey_of <"$MAINF")
[[ "$NEWPUB" =~ $KEY_RE ]] || die "$TAG's PUZZLES_SR_UPDATE_PUBKEY is not one base64 Ed25519 public key: '$NEWPUB'"
MAIN=$(tr -d '\r' <"$MAINF")
hdr() { sed -n "s/^ \* $1: *//p" <<<"$MAIN" | head -1; }
REQ="$(hdr 'Requires at least')"; REQPHP="$(hdr 'Requires PHP')"
[[ "$REQ" =~ $VER_RE && "$REQPHP" =~ $VER_RE ]] || die "bad Requires header: '$REQ' '$REQPHP'"

# 3. This checkout's build of that tree; the release zip must be the same bytes.
bash scripts/build.sh "$V" --src "$T" --out "$W/build" >/dev/null
BUILT=$(sha256sum "$W/build/puzzles-site-reports.zip" | cut -c1-64)
if [ -n "$DRY" ]; then ZIP=$DRY
else mkdir "$W/rel"; gh release download "$TAG" --pattern puzzles-site-reports.zip --dir "$W/rel"; ZIP="$W/rel/puzzles-site-reports.zip"; fi
SHA=$(sha256sum "$ZIP" | cut -c1-64)
[ "$SHA" = "$BUILT" ] || die "the release zip (sha256 $SHA) is not what this checkout builds from $TAG ($BUILT)"

# 4. The key and version sites have now: the latest promoted release's (none yet: the first release trusts its own key).
CURZIP=""; TRUSTED=""
if [ -n "$DRY" ]; then CURZIP=$TRUSTED_ZIP
elif CUR=$(gh api "repos/$GH_REPO/releases/latest" --jq .tag_name 2>"$W/gh-err"); then
  [[ "$CUR" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the latest release's tag is '$CUR'"
  mkdir "$W/cur"; gh release download "$CUR" --pattern puzzles-site-reports.zip --dir "$W/cur"; CURZIP="$W/cur/puzzles-site-reports.zip"
else
  grep -q 'HTTP 404' "$W/gh-err" || { cat "$W/gh-err" >&2; die "could not read the latest release"; }
  [ -z "$ROTATE" ] || die "--rotate, but no release was promoted yet"
  TRUSTED=$NEWPUB
fi
if [ -n "$CURZIP" ]; then # read as data: one file to stdout, nothing extracted
  CURMAIN=$(unzip -p "$CURZIP" puzzles-site-reports/puzzles-site-reports.php | tr -d '\r')
  TRUSTED=$(pubkey_of <<<"$CURMAIN")
  CURV=$(sed -n 's/^ \* Version: *//p' <<<"$CURMAIN" | head -1)
  [[ "$TRUSTED" =~ $KEY_RE && "$CURV" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "cannot read the latest release's key and version"
  [ "$V" != "$CURV" ] && [ "$(printf '%s\n' "$CURV" "$V" | sort -V | tail -1)" = "$V" ] \
    || die "$TAG is not newer than the latest release ($CURV)"
fi

# 5. Sign. stdin: the key, the new key (or an empty line), then the message exactly. Prints "<pub> <new pub or -> <sig>".
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
  echo "promote.sh: dry run without --trusted-zip: the key and version checks are skipped" >&2
fi
if [ -n "$DRY" ]; then # every release key this checkout's history ever carried
  KNOWN=$(git log -p --format= HEAD -- puzzles-site-reports.php | sed -n "s/^[-+]define( 'PUZZLES_SR_UPDATE_PUBKEY', '\([^']*\)' );.*/\1/p")
  ! grep -qxF "$PUB" <<<"$KNOWN" || die "dry run with a release key: use a throwaway key (scripts/keygen.sh)"
fi

printf '{"version":"%s","sha256":"%s","requires":"%s","requires_php":"%s","tested":"%s","signature":"%s"}\n' \
  "$V" "$SHA" "$REQ" "$REQPHP" "$TESTED" "$SIG" >"$W/manifest.json"
if [ -n "$DRY" ]; then cat "$W/manifest.json"; exit 0; fi
gh release upload "$TAG" "$W/manifest.json" --clobber
gh release edit "$TAG" --prerelease=false --latest
echo "promoted $TAG (sha256 $SHA)"
