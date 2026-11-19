#!/usr/bin/env bash
# Signs and promotes a release. Run by the owner on their own machine, never in CI (the signing key never lives in GitHub).
# Usage: bash scripts/promote.sh vX.Y.Z <tested> [--rotate] [--dry-run <zip>]
#   PUZZLES_SR_SIGNING_KEY  the base64 secret key (scripts/keygen.sh), in the environment only (e.g. the owner's secret
#                           runner). It is read once and removed from the environment before anything else runs.
#   <tested>                the WordPress version the release's smoke test ran on, typed by the owner (the release notes
#                           say which). Never paste a command from release notes: anyone with write access can edit them.
#   --rotate                the release ships a new PUZZLES_SR_UPDATE_PUBKEY (README, Release: rotating the key).
#   --dry-run <zip>         every check, with <zip> standing in for the release's asset; prints the manifest, no GitHub
#                           call. Refuses any key that is or was the plugin's release key: dry runs use a throwaway key.
# Before signing: the tag is the same commit locally and on origin, that commit is on origin/main, and the release zip
# has exactly the contents (names and bytes) of a zip built here from that commit. Then manifest.json
# { version, sha256, requires, requires_php, tested, signature } is signed (Ed25519 over the five fields joined by "\n"),
# uploaded, and the release marked latest: sites take it on their next check.
set -euo pipefail
die() { echo "promote.sh: $*" >&2; exit 1; }
VER_RE='^[0-9]+\.[0-9]+(\.[0-9]+)?$'
TAG="${1:-}"; TESTED="${2:-}"
[[ "$TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || die "usage: promote.sh vX.Y.Z <tested> [--rotate] [--dry-run <zip>]"
V="${BASH_REMATCH[1]}"
[[ "$TESTED" =~ $VER_RE ]] || die "bad tested: '$TESTED'"
shift 2
ROTATE=""; DRY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rotate) ROTATE=1 ;;
    --dry-run) DRY="${2:?--dry-run needs a zip}"; shift ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
# The key lives in this shell only: no child process (git, gh, unzip, docker...) inherits it; PHP gets it on stdin.
KEY="${PUZZLES_SR_SIGNING_KEY:-}"
unset PUZZLES_SR_SIGNING_KEY
[ -n "$KEY" ] || die "PUZZLES_SR_SIGNING_KEY is not set"
[ -z "$DRY" ] || DRY=$(realpath "$DRY")

cd "$(dirname "$0")/.."
. scripts/php.sh
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pubkey_of() { tr -d '\r' | sed -n "s/^define( 'PUZZLES_SR_UPDATE_PUBKEY', '\([^']*\)' );.*/\1/p"; } # stdin: the main file

# 1. The tag: one commit, locally and on origin, and on main.
git fetch --quiet --no-tags origin main
COMMIT=$(git rev-parse --verify --quiet "refs/tags/$TAG^{commit}") || die "no local tag $TAG"
REMOTE=$(git ls-remote origin "refs/tags/$TAG" "refs/tags/$TAG^{}" | sort -k2 | tail -1 | cut -f1) # the peeled line sorts last
[ "$REMOTE" = "$COMMIT" ] || die "origin's $TAG is '${REMOTE:-missing}', the local one is $COMMIT"
git merge-base --is-ancestor "$COMMIT" origin/main || die "$TAG ($COMMIT) is not on origin/main"

# 2. The release zip must be exactly what that commit builds (zip timestamps aside).
mkdir "$W/src" "$W/rel"
git archive "$COMMIT" | tar -x -C "$W/src"
bash "$W/src/scripts/build.sh" "$V" >/dev/null
BUILT="$W/src/dist/puzzles-site-reports.zip"
if [ -n "$DRY" ]; then cp "$DRY" "$W/rel/puzzles-site-reports.zip"
else gh release download "$TAG" --pattern puzzles-site-reports.zip --dir "$W/rel"; fi
ZIP="$W/rel/puzzles-site-reports.zip"
NAMES=$(unzip -Z1 "$BUILT" | sort)
[ "$(unzip -Z1 "$ZIP" | sort)" = "$NAMES" ] || die "the release zip's entries differ from a build of $TAG"
while IFS= read -r n; do # each entry's stored bytes, compared without extracting (no symlink or path tricks)
  cmp -s <(unzip -p "$ZIP" "$n") <(unzip -p "$BUILT" "$n") || die "$n in the release zip differs from a build of $TAG"
done <<<"$NAMES"
SHA=$(sha256sum "$ZIP" | cut -c1-64) # the bytes sites will download

MAIN=$(unzip -p "$ZIP" puzzles-site-reports/puzzles-site-reports.php | tr -d '\r')
hdr() { sed -n "s/^ \* $1: *//p" <<<"$MAIN" | head -1; }
REQ="$(hdr 'Requires at least')"; REQPHP="$(hdr 'Requires PHP')"
[[ "$REQ" =~ $VER_RE && "$REQPHP" =~ $VER_RE ]] || die "bad Requires header: '$REQ' '$REQPHP'"
NEWPUB=$(pubkey_of <<<"$MAIN")

# 3. Sign: stdin carries the key (first line) and the message (the rest, exactly). Prints "<public key> <signature>".
MSG="$V"$'\n'"$SHA"$'\n'"$REQ"$'\n'"$REQPHP"$'\n'"$TESTED"
OUT=$(printf '%s\n%s' "$KEY" "$MSG" | php_run -r '
$k = base64_decode( trim( (string) fgets( STDIN ) ), true );
if ( ! is_string( $k ) || SODIUM_CRYPTO_SIGN_SECRETKEYBYTES !== strlen( $k ) ) { fwrite( STDERR, "PUZZLES_SR_SIGNING_KEY is not a base64 Ed25519 secret key\n" ); exit( 1 ); }
echo base64_encode( sodium_crypto_sign_publickey_from_secretkey( $k ) ), " ", base64_encode( sodium_crypto_sign_detached( stream_get_contents( STDIN ), $k ) );
' | tr -d '\r')
KEY=""
PUB="${OUT%% *}"; SIG="${OUT#* }"
[[ "$PUB" =~ ^[A-Za-z0-9+/]{43}=$ && "$SIG" =~ ^[A-Za-z0-9+/]{86}==$ ]] || die "signing failed"

if [ -n "$DRY" ]; then
  # Every release key the plugin ever carried (this tag's, and any in the history of main and HEAD).
  KNOWN=$(git log -p --format= "$COMMIT" origin/main HEAD -- puzzles-site-reports.php \
    | sed -n "s/^[-+]define( 'PUZZLES_SR_UPDATE_PUBKEY', '\([^']*\)' );.*/\1/p"; echo "$NEWPUB")
  ! grep -qxF "$PUB" <<<"$KNOWN" || die "dry run with a release key: use a throwaway key (scripts/keygen.sh)"
else
  # Sites verify with the key in the release they run now: the latest promoted one (none yet: this zip's).
  if CUR=$(gh api 'repos/{owner}/{repo}/releases/latest' --jq .tag_name 2>"$W/gh-err"); then
    [[ "$CUR" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the latest release's tag is '$CUR'"
    mkdir "$W/cur"; gh release download "$CUR" --pattern puzzles-site-reports.zip --dir "$W/cur"
    TRUSTED=$(unzip -p "$W/cur/puzzles-site-reports.zip" puzzles-site-reports/puzzles-site-reports.php | pubkey_of)
  else
    grep -q 'HTTP 404' "$W/gh-err" || { cat "$W/gh-err" >&2; die "could not read the latest release"; }
    TRUSTED="$NEWPUB"
  fi
  [ "$PUB" = "$TRUSTED" ] || die "the signing key's public key ($PUB) is not the one sites trust now ('$TRUSTED')"
  if [ "$NEWPUB" != "$PUB" ]; then
    [ -n "$ROTATE" ] || die "$TAG changes the release key to '$NEWPUB'; pass --rotate if that is intended"
    echo "promote.sh: rotating: after $TAG, sites trust only '$NEWPUB'" >&2
  fi
fi

printf '{"version":"%s","sha256":"%s","requires":"%s","requires_php":"%s","tested":"%s","signature":"%s"}\n' \
  "$V" "$SHA" "$REQ" "$REQPHP" "$TESTED" "$SIG" > "$W/manifest.json"
if [ -n "$DRY" ]; then cat "$W/manifest.json"; exit 0; fi
gh release upload "$TAG" "$W/manifest.json" --clobber
gh release edit "$TAG" --prerelease=false --latest
echo "promoted $TAG (sha256 $SHA)"
