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

# Hermetic: the update check reads a manifest served by this stack (http://wp/..., a 404 until case_update_offer writes
# one), never GitHub's. Present from here on, so no case can reach the real URL.
mu='<?php add_filter( "puzzles_site_reports_manifest_url", function () { return "http://wp/test-manifest.json"; } ); add_filter( "puzzles_site_reports_package_prefix", function () { return "http://wp/releases/download/"; } );'
b=$(printf '%s' "$mu" | base64 | tr -d '\n')
wpcli eval "wp_mkdir_p( WPMU_PLUGIN_DIR ); file_put_contents( WPMU_PLUGIN_DIR . '/psr-update.php', base64_decode( '$b' ) );"

# Apache may lag behind `core install` (which went through WP-CLI): wait until WordPress answers over HTTP.
for _ in $(seq 1 40); do
  curl -fs -o /dev/null http://localhost:8080/ && break
  sleep 3
done
curl -fs -o /dev/null http://localhost:8080/

# Git Bash on Windows ships no jq: run it from an image (stdin, or files under out/).
command -v jq >/dev/null || jq() { docker run -i --rm -e EXPECTED_VERSION -v "$(pwd -W 2>/dev/null || pwd)/out:/w/out" -w /w ghcr.io/jqlang/jq:1.7.1 "$@"; }

base64url_decode() { # stdin -> stdout; re-pads and maps -_ to +/
  local s; s=$(tr -d '\r\n' | tr '_-' '/+')
  while [ $(( ${#s} % 4 )) -ne 0 ]; do s="$s="; done
  printf '%s' "$s" | base64 -d
}
connect() { wpcli puzzles-site-reports connect --porcelain | tr -d '\r\n'; } # prints the connection string
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
  [ "$(wpcli option get puzzles_site_reports_token --format=json | jq -r .hash | tr -d '\r')" = "$(printf %s "$t2" | sha256sum | cut -c1-64)" ]
  # not in the public index (plain permalinks: /wp-json/ is the home page, so ask through rest_route)
  idx=$(curl -s 'http://localhost:8080/?rest_route=/')
  [ "$(echo "$idx" | jq -r '.namespaces | index("wp/v2") != null')" = true ]  # it is the real index
  [ "$(echo "$idx" | jq -r '[.namespaces[], (.routes | keys[])] | map(select(contains("puzzles-reports"))) | length')" = 0 ]
  curl -s -D - -o /dev/null "http://localhost:8080/?rest_route=/puzzles-reports/v1/status&_=1" -H "X-Puzzles-Reports-Token: $t2" | grep -qi '^cache-control:.*no-store'
  curl -s -D - -o /dev/null "http://localhost:8080/?rest_route=/puzzles-reports/v1/status&_=2" | grep -qi '^cache-control:.*no-store' # the 401 too
  wpcli puzzles-site-reports status | grep -q 'connected: yes'
  ! wpcli puzzles-site-reports status | grep -q "$t2" || return 1
}

case_auth_locked_rest() { # another plugin refuses every unauthenticated REST request: our token must still work
  s=$(connect); t=$(token_of "$s")
  mu='<?php add_filter( "rest_authentication_errors", function ( $r ) { return new WP_Error( "rest_not_logged_in", "x", array( "status" => 401 ) ); } );'
  b=$(printf '%s' "$mu" | base64 | tr -d '\n')
  wpcli eval "wp_mkdir_p( WPMU_PLUGIN_DIR ); file_put_contents( WPMU_PLUGIN_DIR . '/psr-lock.php', base64_decode( '$b' ) );"
  [ "$(curl -s -o /dev/null -w '%{http_code}' 'http://localhost:8080/?rest_route=/wp/v2/users')" = 401 ]  # the lock is on
  [ "$(call status "$t")" = 200 ]
  [ "$(call status)" = 401 ]
  [ "$(curl -s -o /dev/null -w '%{http_code}' 'http://localhost:8080/?rest_route=/wp/v2/users')" = 401 ]  # nothing else loosened
  wpcli eval "unlink( WPMU_PLUGIN_DIR . '/psr-lock.php' );"
}

case_status_fresh() { # no update check has run yet: delete the three transients to force that state
  for t in update_core update_plugins update_themes; do wpcli transient delete "$t" --network >/dev/null 2>&1 || true; done
  t=$(token_of "$(connect)"); [ "$(call status "$t")" = 200 ]
  jq -e '.companion.version == env.EXPECTED_VERSION' out/status.json
  jq -e '.wordpress.updatesCheckedAt == null and ([.plugins[].update] | all(. == null))' out/status.json
  jq -e '.php.version | test("^8\\.3\\.")' out/status.json
  jq -e '.plugins[] | select(.file == "puzzles-site-reports/puzzles-site-reports.php") | .active == true' out/status.json
  jq -e '.wordfence == null and .comments.defaultStatus == "open"' out/status.json
  ! grep -q '/var/www' out/status.json || return 1
}

case_status_wordfence_and_updates() {
  wpcli plugin install wordfence --activate
  wpcli plugin install akismet --version=5.0 --force
  wpcli plugin deactivate akismet || true
  wpcli plugin auto-updates enable akismet
  wpcli theme install twentytwentyone --version=1.0 --force
  # a child theme (parent), and a must-use plugin (exactly file/name/version)
  wpcli eval '
    $d = get_theme_root() . "/psr-child"; wp_mkdir_p( $d );
    file_put_contents( $d . "/style.css", "/*\nTheme Name: PSR Child\nTemplate: twentytwentyone\nVersion: 0.1\n*/" );
    file_put_contents( $d . "/index.php", "<?php // Silence is golden." );
    wp_mkdir_p( WPMU_PLUGIN_DIR );
    file_put_contents( WPMU_PLUGIN_DIR . "/psr-test-mu.php", "<?php\n/*\nPlugin Name: PSR Test MU\nVersion: 1.2.3\n*/" );'
  for t in update_core update_plugins update_themes; do wpcli transient delete "$t" --network >/dev/null 2>&1 || true; done
  wpcli eval 'wp_update_plugins(); wp_update_themes(); wp_version_check();'
  wpcli option update default_comment_status closed
  # No scan is run (too heavy): seed Wordfence's own store through its public API instead, so the reading path runs for real.
  # Issue 1 is open: a distinctive shortMsg that holds a server path (it must come back relative), a different longMsg,
  # a path in its private data. Issue 2 is ignored (its id is looked up, not assumed).
  wpcli eval '
    global $wpdb;
    $i = wfIssues::shared();
    $i->addIssue( "wfPluginUpgrade", 75, "a", "a", "PSR-short-marker in " . WP_CONTENT_DIR . "/plugins/x.php", "PSR-long-marker", array( "secret" => "/var/www/html/private-data" ) );
    $i->addIssue( "wfThemeUpgrade", 50, "b", "b", "ignored one", "long", array() );
    $id = (int) $wpdb->get_var( "SELECT id FROM " . $i->getIssuesTable() . " WHERE type = \"wfThemeUpgrade\"" );
    if ( ! $id ) { exit( 1 ); }
    $i->updateIssue( $id, "ignoreP" );
    wfScanner::shared()->recordLastScanTime();'
  t=$(token_of "$(connect)"); [ "$(call status "$t")" = 200 ]
  jq -e '.wordfence.ignored == 1 and (.wordfence.lastScanAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))' out/status.json
  jq -e '.wordfence.issues | length == 1 and .[0].type == "wfPluginUpgrade" and .[0].severity == 75 and .[0].shortMsg == "PSR-short-marker in wp-content/plugins/x.php" and (.[0].firstSeenAt | type == "string") and (.[0] | keys | sort) == ["firstSeenAt","severity","shortMsg","type"]' out/status.json
  ! grep -q 'PSR-long-marker' out/status.json || return 1               # shortMsg, never longMsg
  ! grep -q 'private-data' out/status.json || return 1                  # Wordfence's per-issue data never leaves
  jq -e '.wordpress.updatesCheckedAt != null' out/status.json
  jq -e '.plugins[] | select(.file == "akismet/akismet.php") | .active == false and .version == "5.0" and (.update | type == "string") and .autoUpdate == true' out/status.json
  jq -e '.plugins[] | select(.file == "puzzles-site-reports/puzzles-site-reports.php") | .autoUpdate == false' out/status.json
  jq -e '.themes[] | select(.stylesheet == "twentytwentyone") | (.update | type == "string") and .active == false and .parent == null' out/status.json
  jq -e '.themes[] | select(.stylesheet == "psr-child") | .parent == "twentytwentyone" and .active == false and .name == "PSR Child"' out/status.json
  jq -e '.mustUse[] | select(.file == "psr-test-mu.php") | . == {"file": "psr-test-mu.php", "name": "PSR Test MU", "version": "1.2.3"}' out/status.json
  jq -e '.wordfence.active == true and (.wordfence.issues | type == "array") and (.wordfence | has("lastScanAt"))' out/status.json
  jq -e '.comments.defaultStatus == "closed"' out/status.json
  jq -e '(.wordfence | keys | sort) == ["active","ignored","issues","lastScanAt","version"]' out/status.json
  ! grep -q '/var/www' out/status.json || return 1
  wpcli plugin deactivate wordfence
  [ "$(call status "$t")" = 200 ]
  # installed but inactive: still reported, its classes are not loaded, so nothing is read, no fatal
  jq -e '.wordfence.active == false and .wordfence.issues == [] and .wordfence.ignored == 0 and .wordfence.lastScanAt == null' out/status.json
  # State left for later cases: the test mu-plugin, child theme and akismet auto-update are removed and the comment default is
  # back to "open"; still there: Wordfence (installed, inactive, with its two seeded issues), akismet 5.0 (inactive),
  # twentytwentyone 1.0, filled update transients, and the current connection token.
  wpcli eval 'unlink( WPMU_PLUGIN_DIR . "/psr-test-mu.php" );'
  wpcli theme delete psr-child
  wpcli plugin auto-updates disable akismet
  wpcli option update default_comment_status open
}

case_seo_without_rank_math() {
  t=$(token_of "$(connect)"); [ "$(call seo "$t")" = 200 ]
  jq -e '.plugin == null and .items == []' out/seo.json
}

case_seo_with_rank_math() {
  wpcli plugin install seo-by-rank-math --activate
  a=$(wpcli post create --post_type=page --post_status=publish --post_title=About --porcelain | tr -d '\r\n')
  wpcli post meta update "$a" rank_math_focus_keyword 'roofing miami, roof repair'
  wpcli post meta update "$a" rank_math_seo_score 81
  wpcli post meta update "$a" rank_math_robots '["noindex"]' --format=json
  b=$(wpcli post create --post_type=page --post_status=publish --post_title=Contact --post_name=contact-us --porcelain | tr -d '\r\n')
  wpcli post meta update "$b" rank_math_focus_keyword '   '
  wpcli post create --post_type=page --post_status=draft --post_title=Draft
  c=$(wpcli post create --post_type=page --post_status=publish --post_title=Services --porcelain | tr -d '\r\n')
  wpcli post meta update "$c" rank_math_robots '["index","nofollow"]' --format=json
  d=$(wpcli post create --post_type=page --post_status=publish --post_title="Tom & Jerry's <em>Show</em>" --porcelain | tr -d '\r\n')
  e=$(wpcli post create --post_type=page --post_status=publish --post_title=Pricing --porcelain | tr -d '\r\n')
  wpcli post meta update "$e" rank_math_title 'Best &amp; <b>Roofing</b> | Acme'
  wpcli post meta update "$e" rank_math_description 'Fast &quot;repairs&quot; &amp; <i>more</i>'
  wpcli post meta update "$e" rank_math_focus_keyword 'a,,b'
  p=$(wpcli post create --post_type=post --post_status=publish --post_title=News --porcelain | tr -d '\r\n')

  # A page-builder site: 300 pages that each carry ~200 KB of unrelated meta. Reading the report must not load it.
  wpcli eval 'for ( $i = 0; $i < 300; $i++ ) {
    $id = wp_insert_post( array( "post_type" => "page", "post_status" => "publish", "post_title" => "Seed $i", "post_content" => str_repeat( "x", 20000 ) ) );
    update_post_meta( $id, "_elementor_data", str_repeat( "x", 200000 ) );
    update_post_meta( $id, "psr_seed", 1 );
  }'
  mem=$(wpcli eval '$b = memory_get_usage(); psr_seo(); echo memory_get_peak_usage() - $b;' | tr -d '\r\n')
  echo "seo peak memory over baseline: $mem bytes"
  [ "$mem" -lt 33554432 ] # under 32 MB; loading the seeded meta alone would be ~60 MB

  t=$(token_of "$(connect)"); [ "$(call seo "$t")" = 200 ]
  jq -e '.plugin.name == "rank_math" and (.plugin.version | type == "string" and length > 0)' out/seo.json
  jq -e --argjson a "$a" '.items[] | select(.id == $a) | .focusKeywords == ["roofing miami","roof repair"] and .seoScore == 81 and .noindex == true and .metaTitle == null and .type == "page" and .title == "About" and (.url | type == "string")' out/seo.json
  jq -e --argjson b "$b" '.items[] | select(.id == $b) | .focusKeywords == [] and .seoScore == null and .noindex == null' out/seo.json
  jq -e --argjson c "$c" '.items[] | select(.id == $c) | .noindex == false' out/seo.json
  jq -e --argjson d "$d" '.items[] | select(.id == $d) | .title == "Tom & Jerry'"'"'s Show"' out/seo.json
  jq -e --argjson e "$e" '.items[] | select(.id == $e) | .metaTitle == "Best & Roofing | Acme" and .metaDescription == "Fast \"repairs\" & more" and .focusKeywords == ["a","b"]' out/seo.json
  jq -e --argjson p "$p" '.items[] | select(.id == $p) | .type == "post" and .title == "News"' out/seo.json
  jq -e '[.items[] | select(.title == "Draft")] | length == 0' out/seo.json
  jq -e '.types.page.truncated == false and .types.page.items == 306 and (.types | has("product") | not)' out/seo.json
  jq -e '([.items[] | select(.type == "page")] | length) == .types.page.items and (.items | length) == (.types.page.items + .types.post.items)' out/seo.json
  # State left for later cases: Rank Math active; pages About, Contact, Services, the "Tom & Jerry" page and Pricing, one post
  # (News) and one draft remain; the 300 seeded pages are deleted so the site stays light.
  wpcli eval 'foreach ( get_posts( array( "post_type" => "page", "post_status" => "any", "meta_key" => "psr_seed", "numberposts" => -1, "fields" => "ids" ) ) as $id ) { wp_delete_post( $id, true ); }'
}

case_update_offer() { # a local manifest (served by the wp container, reached as http://wp) offers 9.9.9
  ours=puzzles-site-reports/puzzles-site-reports.php
  pkg=http://wp/releases/download/v9.9.9/puzzles-site-reports.zip
  manifest() { # manifest <version> <package>: written into the wp container's web root
    wpcli eval "file_put_contents( ABSPATH . 'test-manifest.json', json_encode( array( 'version' => '$1', 'package' => '$2', 'requires' => '5.8', 'requires_php' => '7.4', 'tested' => '6.9' ) ) );"
  }
  check() { wpcli transient delete update_plugins --network; wpcli eval 'wp_update_plugins();'; }
  offered() { wpcli plugin list --name=puzzles-site-reports --field=update_version | tr -d '\r\n'; }
  filter() { # filter <installed-version> <plugin-file>: our update filter called directly; "input" is what core handed in
    wpcli eval "echo wp_json_encode( psr_update_offer( 'input', array( 'Version' => '$1' ), '$2', array() ) );" | tr -d '\r\n'
  }

  # no manifest file yet (the setup mu-plugin points at it; WordPress answers its 404): nothing is offered, the input comes back
  check; [ -z "$(offered)" ]
  [ "$(filter 1.0.0 "$ours")" = '"input"' ]

  manifest 9.9.9 "$pkg"
  curl -fs http://localhost:8080/test-manifest.json | grep -q '9.9.9'
  check
  [ "$(offered)" = "9.9.9" ]
  wpcli eval '$u = get_site_transient( "update_plugins" ); echo $u->response["puzzles-site-reports/puzzles-site-reports.php"]->package;' | grep -qx "$pkg"
  [ "$(filter 1.0.0 "$ours")" != '"input"' ]                  # the offer is real...
  [ "$(filter 99.0.0 "$ours")" = '"input"' ]                  # ...but not when the installed version is not older
  [ "$(filter 1.0.0 akismet/akismet.php)" = '"input"' ]       # ...and never for another plugin's file
  wpcli eval 'echo (int) apply_filters("auto_update_plugin", false, (object) ["plugin" => "puzzles-site-reports/puzzles-site-reports.php"]);' | grep -qx 1
  wpcli eval 'echo (int) apply_filters("auto_update_plugin", false, (object) ["plugin" => "akismet/akismet.php"]);' | grep -qx 0

  # nothing is offered unless the package is exactly this version's release asset, the version is X.Y.Z, and the body is a manifest
  manifest 9.9.9 http://wp/releases/download/../../x/v9.9.9/puzzles-site-reports.zip; check; [ -z "$(offered)" ]
  manifest 9.9.9 http://wp/releases/download/v9.9.8/puzzles-site-reports.zip; check; [ -z "$(offered)" ]
  manifest 9.9.9 http://wp/other/v9.9.9/puzzles-site-reports.zip; check; [ -z "$(offered)" ]
  manifest 9.9.9-beta http://wp/releases/download/v9.9.9-beta/puzzles-site-reports.zip; check; [ -z "$(offered)" ]
  wpcli eval 'file_put_contents( ABSPATH . "test-manifest.json", "not json" );'; check; [ -z "$(offered)" ]
  wpcli eval 'unlink( ABSPATH . "test-manifest.json" );'
}

# Fixed order (Task rulings). A new case is added to BOTH the function list and this one;
# the check below fails on any mismatch, so a case can never be silently skipped.
CASES=(case_plugin_active case_auth case_auth_locked_rest case_status_fresh case_status_wordfence_and_updates case_seo_without_rank_math case_seo_with_rank_math case_update_offer)

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
