#!/usr/bin/env bash
# Creates the release signing keypair (Ed25519). Prints ONLY the public key (base64) on stdout: it goes into the
# plugin's PUZZLES_SR_UPDATE_PUBKEY. The secret key (base64) goes to file descriptor 3 and nowhere else, so it can be
# piped straight into a secret store without touching disk, e.g.:
#   bash scripts/keygen.sh 3>&1 1>&2 | <store-secret-from-stdin>     # the public key shows on the terminal
# PHP (scripts/php.sh: php on PATH, else a pinned image with no log) prints the keypair into a pipe to this script, and
# this script, on the host, writes the secret key to fd 3.
set -euo pipefail
{ true >&3; } 2>/dev/null || { echo "keygen.sh: open fd 3 for the secret key (see the header)" >&2; exit 1; }
. "$(dirname "$0")/php.sh"
KP=$(php_run -r '$k = sodium_crypto_sign_keypair(); echo base64_encode( sodium_crypto_sign_publickey( $k ) ), " ", base64_encode( sodium_crypto_sign_secretkey( $k ) );')
printf '%s' "${KP#* }" >&3
printf '%s\n' "${KP%% *}"
