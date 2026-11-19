#!/usr/bin/env bash
# The promotion launcher. The owner reviews THIS file by hand and installs it outside the repository (README, Release);
# it is the only promotion code that never comes from a commit. It never runs anything from the checkout it is given:
# it exports scripts/promote.sh, build.sh and php.sh, as git blobs, from the commit of the owner's last promotion
# recorded on this machine (refs/puzzles-sr/promoted/, written only by promote.sh) into a temp dir and runs that
# promote.sh. Promotion code a release changes therefore runs only on the promotion AFTER the one whose review showed it.
# Usage: wp-sr-promote --repo <checkout> [--trust-checkout <commit sha>] vX.Y.Z <tested> [promote.sh's options]
#   --trust-checkout <sha>  run that commit's scripts instead (a full 40-character sha, never a ref, which can move):
#                           needed when this machine has no record (its first promotion), and for a release whose
#                           build.sh changes the zip. Review the three scripts at that commit by hand first:
#                           git -C <checkout> show <sha>:scripts/promote.sh | cat -v   (and build.sh, php.sh)
# The keys (promote.sh's header) are copied and unset first, so no child but that promote.sh gets them.
KEY="${PUZZLES_SR_SIGNING_KEY:-}"; NEWKEY="${PUZZLES_SR_NEW_SIGNING_KEY:-}"
unset PUZZLES_SR_SIGNING_KEY PUZZLES_SR_NEW_SIGNING_KEY
set -euo pipefail
export GIT_NO_REPLACE_OBJECTS=1 # refs/replace/ never substitutes an object read here or by promote.sh
die() { echo "wp-sr-promote: $*" >&2; exit 1; }
REPO=""; FROM=""; ARGS=(); REC=refs/puzzles-sr/promoted
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo needs a checkout}"; shift ;;
    --trust-checkout) FROM="${2:?--trust-checkout needs a commit sha}"; shift ;;
    --dry-run) REC=refs/puzzles-sr/dry-run/promoted; ARGS+=("$1") ;; # a dry run keeps its own record (promote.sh)
    *) ARGS+=("$1") ;;
  esac
  shift
done
[ -n "$REPO" ] || die "usage: wp-sr-promote --repo <checkout> [--trust-checkout <commit sha>] vX.Y.Z <tested> [options]"
cd "$REPO"
# The record is a local ref: a fetch must not be able to write it.
while read -r k spec; do
  dst=${spec#*:}
  [ "$dst" = "$spec" ] || [ -z "$dst" ] || [[ "$dst" == refs/remotes/* || "$dst" == refs/tags/* ]] \
    || die "$k fetches into ${dst@Q}: only refs/remotes/ and refs/tags/ may be fetched into (the record is local)"
done <<<"$(git config --get-regexp '^remote\..*\.fetch$' || true)"
if [ -n "$FROM" ]; then
  [[ "$FROM" =~ ^[0-9a-f]{40}$ ]] || die "--trust-checkout takes a full 40-character commit sha, not ${FROM@Q}"
  C=$(git rev-parse --verify --quiet "$FROM^{commit}") || die "no commit $FROM in $REPO"
  DESC="$C (--trust-checkout)"
else
  LAST=$(git for-each-ref --sort=-version:refname --count=1 --format='%(refname)' "$REC")
  [ -n "$LAST" ] || die "no promotion is recorded on this machine ($REC/): pass --trust-checkout <sha> with the full sha of a
commit whose scripts you reviewed by hand: git -C ${REPO@Q} show <sha>:scripts/promote.sh | cat -v (and build.sh, php.sh)"
  C=$(git rev-parse --verify "$LAST^{commit}"); DESC="${LAST##*/}, your last promotion recorded on this machine ($C)"
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
for f in promote.sh build.sh php.sh; do
  git cat-file blob "$C:scripts/$f" >"$W/$f"
  [ "$(LC_ALL=C tr -d '\11\12\40-\176' <"$W/$f" | wc -c)" -eq 0 ] || die "$C's scripts/$f has a byte other than TAB, LF and printable ASCII"
done
PUZZLES_SR_SCRIPTS="$DESC" PUZZLES_SR_SIGNING_KEY="$KEY" PUZZLES_SR_NEW_SIGNING_KEY="$NEWKEY" bash "$W/promote.sh" "${ARGS[@]}"
