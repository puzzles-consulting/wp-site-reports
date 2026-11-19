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

# ---- cases (plain functions; run in this fixed order, only the ones defined) ----
case_plugin_active() {
  [ "$(wpcli plugin get puzzles-site-reports --field=status)" = "active" ]
  [ "$(wpcli plugin get puzzles-site-reports --field=version)" = "$EXPECTED_VERSION" ]
}

for c in case_plugin_active case_auth case_status_fresh case_status_wordfence_and_updates \
  case_seo_without_rank_math case_seo_with_rank_math case_update_offer; do
  declare -F "$c" >/dev/null || continue
  echo "== $c"
  "$c"
  echo "ok $c"
done
echo "smoke: all cases passed"
