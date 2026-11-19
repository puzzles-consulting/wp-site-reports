#!/usr/bin/env bash
# Signs and promotes a release. Run by the owner on their own machine, never in CI (the signing key never lives in GitHub).
# Usage: bash scripts/promote.sh vX.Y.Z <tested> [--dry-run <zip>]
#   PUZZLES_SR_SIGNING_KEY  the base64 secret key (scripts/keygen.sh) in the environment, e.g. under the owner's secret runner.
#   <tested>                the WordPress the release's smoke test ran on (its release notes say which).
#   --dry-run <zip>         signs that local zip and prints the manifest; no GitHub call.
# Downloads the pre-release zip, writes manifest.json { version, sha256, requires, requires_php, tested, signature }
# (signature: Ed25519 over "<version>\n<sha256>"), uploads it and marks the release latest: sites take it on their next check.
# PHP runs the crypto; set PHP to another command (e.g. a docker run that passes -e PUZZLES_SR_SIGNING_KEY) when php is not on PATH.
set -euo pipefail
die() { echo "promote.sh: $*" >&2; exit 1; }
TAG="${1:-}"; TESTED="${2:-}"
[[ "$TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || die "usage: promote.sh vX.Y.Z <tested> [--dry-run <zip>]"
V="${BASH_REMATCH[1]}"
[[ "$TESTED" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "bad tested: '$TESTED'"
DRY=""
if [ "${3:-}" = "--dry-run" ]; then DRY="${4:?--dry-run needs a zip}"; elif [ -n "${3:-}" ]; then die "unknown argument: $3"; fi
[ -n "${PUZZLES_SR_SIGNING_KEY:-}" ] || die "PUZZLES_SR_SIGNING_KEY is not set"
read -ra PHPCMD <<<"${PHP:-php}"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
ZIP="$W/puzzles-site-reports.zip"
if [ -n "$DRY" ]; then cp "$DRY" "$ZIP"; else gh release download "$TAG" --pattern puzzles-site-reports.zip --dir "$W"; fi
SHA=$(sha256sum "$ZIP" | cut -c1-64)

MAIN=$(unzip -p "$ZIP" puzzles-site-reports/puzzles-site-reports.php | tr -d '\r')
hdr() { sed -n "s/^ \* $1: *//p" <<<"$MAIN" | head -1; }
[ "$(hdr Version)" = "$V" ] || die "the zip is version '$(hdr Version)', not $V"
REQ="$(hdr 'Requires at least')"; REQPHP="$(hdr 'Requires PHP')"
[[ "$REQ" =~ ^[0-9.]+$ && "$REQPHP" =~ ^[0-9.]+$ ]] || die "bad Requires header: '$REQ' '$REQPHP'"

# Prints "<public key> <signature>" (both base64); the secret key is read from the environment only.
OUT=$("${PHPCMD[@]}" -r '
$k = base64_decode( (string) getenv( "PUZZLES_SR_SIGNING_KEY" ), true );
if ( ! is_string( $k ) || SODIUM_CRYPTO_SIGN_SECRETKEYBYTES !== strlen( $k ) ) { fwrite( STDERR, "PUZZLES_SR_SIGNING_KEY is not a base64 Ed25519 secret key\n" ); exit( 1 ); }
$msg = $argv[1] . "\n" . $argv[2];
$sig = sodium_crypto_sign_detached( $msg, $k );
$pk  = sodium_crypto_sign_publickey_from_secretkey( $k );
if ( ! sodium_crypto_sign_verify_detached( $sig, $msg, $pk ) ) { exit( 1 ); }
echo base64_encode( $pk ), " ", base64_encode( $sig );
' "$V" "$SHA")
PUB="${OUT%% *}"; SIG="${OUT#* }"

# Sites verify with the key compiled into the plugin: signing with any other key would ship nothing.
ZIPPUB=$(sed -n "s/^define( 'PUZZLES_SR_UPDATE_PUBKEY', '\([^']*\)' );.*/\1/p" <<<"$MAIN")
if [ "$PUB" != "$ZIPPUB" ]; then
  [ -n "$DRY" ] || die "the signing key's public key ($PUB) is not the zip's PUZZLES_SR_UPDATE_PUBKEY ('$ZIPPUB')"
  echo "dry run: the signing key's public key is not the zip's PUZZLES_SR_UPDATE_PUBKEY ('$ZIPPUB'); sites would reject this manifest" >&2
fi

printf '{"version":"%s","sha256":"%s","requires":"%s","requires_php":"%s","tested":"%s","signature":"%s"}\n' \
  "$V" "$SHA" "$REQ" "$REQPHP" "$TESTED" "$SIG" > "$W/manifest.json"
if [ -n "$DRY" ]; then cat "$W/manifest.json"; exit 0; fi
gh release upload "$TAG" "$W/manifest.json" --clobber
gh release edit "$TAG" --prerelease=false --latest
echo "promoted $TAG (sha256 $SHA)"
