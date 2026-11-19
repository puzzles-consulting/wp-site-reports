#!/usr/bin/env bash
# Boots a throwaway WordPress, installs dist/puzzles-site-reports.zip and runs every case_* below.
# Usage: bash scripts/build.sh <version> && bash tests/smoke.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1 # Git Bash on Windows would rewrite /dist/... arguments passed to docker

cd "$(dirname "$0")"
EXPECTED_VERSION="$(cat ../dist/VERSION)" # written by scripts/build.sh
export EXPECTED_VERSION

mkdir -p out && chmod 777 out # the cli container writes here as www-data
dc() { docker compose -f docker-compose.yml "$@"; }
wpcli() { dc run --rm -T cli wp "$@"; }
trap 'dc --profile cli down -v >/dev/null 2>&1 || true' EXIT

dc up -d db wp

# wait for the wp container to write wp-config.php and for the database to answer
for _ in $(seq 1 60); do
  wpcli db check >/dev/null 2>&1 && break
  sleep 3
done
wpcli db check >/dev/null

wpcli core install --url=http://localhost:8080 --title=Smoke --admin_user=admin \
  --admin_password=admin --admin_email=admin@example.com --skip-email
wpcli plugin install /dist/puzzles-site-reports.zip --activate --force

# Apache may lag behind `core install` (which went through WP-CLI): wait until WordPress answers over HTTP.
for _ in $(seq 1 40); do
  curl -fs -o /dev/null http://localhost:8080/ && break
  sleep 3
done
curl -fs -o /dev/null http://localhost:8080/

# Git Bash on Windows ships no jq: run it from an image (stdin, or files under out/).
command -v jq >/dev/null || jq() { docker run -i --rm -v "$(pwd -W 2>/dev/null || pwd)/out:/w/out" -w /w ghcr.io/jqlang/jq:1.7.1 "$@"; }

base64url_decode() { # stdin -> stdout; re-pads and maps -_ to +/
  local s; s=$(tr -d '
' | tr '_-' '/+')
  while [ $(( ${#s} % 4 )) -ne 0 ]; do s="$s="; done
  printf '%s' "$s" | base64 -d
}
connect() { wpcli puzzles-site-reports connect --porcelain | tr -d '
'; } # prints the connection string
token_of() { local s="$1"; echo "${s#pzr1.}" | base64url_decode | jq -r .token; }
call() { # call <route> [token] -> HTTP status; the body lands in out/<route>.json
  local h=(); [ -z "${2:-}" ] || h=(-H "X-Puzzles-Reports-Token: $2")
  curl -s -o "out/$1.json" -w '%{http_code}' "${h[@]}" "http://localhost:8080/?rest_route=/puzzles-reports/v1/$1&_=$(date +%s%N)"
}

# ---- cases (plain functions; run in this fixed order, only the ones defined) ----
case_plugin_active() {
  [ "$(wpcli plugin get puzzles-site-reports --field=status)" = "active" ]
  [ "$(wpcli plugin get puzzles-site-reports --field=version)" = "$EXPECTED_VERSION" ]
}

case_auth() { # `! x || return 1`: a bare `! x` never trips set -e
  wpcli option delete puzzles_site_reports_token >/dev/null 2>&1 || true
  [ "$(call status)" = 401 ]                                      # no token, not connected
  [ "$(jq -r .code out/status.json)" = puzzles_reports_unauthorized ]
  s1=$(connect); t1=$(token_of "$s1")
  [ "$(call status "$t1")" = 200 ]
  [ "$(call status wrong)" = 401 ]
  s2=$(connect); t2=$(token_of "$s2")
  [ "$(call status "$t1")" = 401 ]                                 # rotated: the old one is dead at once
  [ "$(call status "$t2")" = 200 ]
  [ "${s2:0:5}" = "pzr1." ]
  [ "${#t2}" -eq 64 ]                                              # 64 hex
  site=$(echo "${s2#pzr1.}" | base64url_decode | jq -r .site); [ "$site" = "http://localhost:8080" ]
  ! wpcli option get puzzles_site_reports_token | grep -q "$t2" || return 1   # only the hash is stored
  [ "$(wpcli option get puzzles_site_reports_token --format=json | jq -r .hash | tr -d '')" = "$(printf %s "$t2" | sha256sum | cut -c1-64)" ]
  ! curl -s http://localhost:8080/wp-json/ | grep -q puzzles-reports || return 1  # not in the public index
  curl -s -D - -o /dev/null "http://localhost:8080/?rest_route=/puzzles-reports/v1/status&_=1" -H "X-Puzzles-Reports-Token: $t2" | grep -qi '^cache-control:.*no-store'
  curl -s -D - -o /dev/null "http://localhost:8080/?rest_route=/puzzles-reports/v1/status&_=2" | grep -qi '^cache-control:.*no-store' # the 401 too
  wpcli puzzles-site-reports status | grep -q 'connected: yes'
  ! wpcli puzzles-site-reports status | grep -q "$t2" || return 1
}

# Fixed order (Task rulings). A new case is added to BOTH the function list and this one;
# the check below fails on any mismatch, so a case can never be silently skipped.
CASES=(case_plugin_active case_auth)
# add, in this order, as their tasks land: case_status_fresh case_status_wordfence_and_updates
#   case_seo_without_rank_math case_seo_with_rank_math case_update_offer

for c in "${CASES[@]}"; do
  declare -F "$c" >/dev/null || { echo "FAIL: listed case $c is not defined" >&2; exit 1; }
done
while read -r _ _ f; do
  case "$f" in case_*)
    [[ " ${CASES[*]} " == *" $f "* ]] || { echo "FAIL: defined case $f is not in CASES" >&2; exit 1; } ;;
  esac
done < <(declare -F)
[ "${#CASES[@]}" -gt 0 ] || { echo "FAIL: no cases" >&2; exit 1; }

ran=0
for c in "${CASES[@]}"; do
  echo "== $c"
  "$c"
  echo "ok $c"
  ran=$((ran + 1))
done
[ "$ran" -gt 0 ] || { echo "FAIL: zero cases ran" >&2; exit 1; }
echo "smoke: all $ran cases passed"
