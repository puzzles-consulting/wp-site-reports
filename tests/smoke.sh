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
wpcli core version | tr -d '\r\n' > out/wp-version.txt # the release's `tested`: the WordPress this run is on

put_mu() { # put_mu <file> <php>: writes a must-use plugin (base64 through wp eval, so no shell quoting reaches PHP)
  local b; b=$(printf '%s' "$2" | base64 | tr -d '\n')
  wpcli eval "wp_mkdir_p( WPMU_PLUGIN_DIR ); file_put_contents( WPMU_PLUGIN_DIR . '/$1', base64_decode( '$b' ) );"
}
rm_mu() { wpcli eval "unlink( WPMU_PLUGIN_DIR . '/$1' );"; } # rm_mu <file>

# A throwaway Ed25519 keypair signs this run's manifests; the test-only filter swaps its public key in for the plugin's.
kp=$(wpcli eval '$k = sodium_crypto_sign_keypair(); echo base64_encode( $k ), " ", base64_encode( sodium_crypto_sign_publickey( $k ) );' | tr -d '\r\n')
KP=${kp% *}; PK=${kp#* }
[ "${#KP}" -eq 128 ] # base64 of the 96-byte keypair
[ "${#PK}" -eq 44 ]

# Hermetic: the update check reads a manifest served by this stack (http://wp/..., a 404 until case_update_offer writes
# one), never GitHub's. Present from here on, so no case can reach the real URL.
mu='<?php
add_filter( "puzzles_site_reports_manifest_url", function () { return "http://wp/test-manifest.json"; } );
add_filter( "puzzles_site_reports_package_prefix", function () { return "http://wp/releases/download/"; } );
add_filter( "puzzles_sr_update_pubkey", function () { return "__PK__"; } );
add_filter( "http_request_host_is_external", function ( $ok, $host ) { return "wp" === $host ? true : $ok; }, 10, 2 ); // download_url() refuses private hosts

/**
 * Writes the manifest the update check reads, signed with $kp (a base64 keypair; none when empty) over its five fields
 * joined by "\n", as scripts/promote.sh signs. $signed overrides fields before signing, $extra after.
 */
function puzzles_sr_test_manifest( $version, $sha, $kp, array $extra = array(), array $signed = array() ) {
	$m = array_merge( array( "version" => $version, "sha256" => $sha, "requires" => "5.8", "requires_php" => "7.4", "tested" => "6.9" ), $signed );
	if ( "" !== $kp ) {
		$msg            = implode( "\n", array( $m["version"], $m["sha256"], $m["requires"], $m["requires_php"], $m["tested"] ) );
		$m["signature"] = base64_encode( sodium_crypto_sign_detached( $msg, sodium_crypto_sign_secretkey( base64_decode( $kp ) ) ) );
	}
	file_put_contents( ABSPATH . "test-manifest.json", wp_json_encode( array_merge( $m, $extra ) ) );
}

/** The download hook called directly: "<sha256 of the file it returned> <temp files left>", or "<error code or false> <temp files left>". */
function puzzles_sr_test_download( $package ) {
	$r    = apply_filters( "upgrader_pre_download", false, $package, null, array() );
	$left = count( glob( get_temp_dir() . "puzzles-site-reports*" ) );
	if ( is_string( $r ) ) {
		$h = hash_file( "sha256", $r );
		unlink( $r );
		return "$h $left";
	}
	return ( is_wp_error( $r ) ? $r->get_error_code() : var_export( $r, true ) ) . " $left";
}'
put_mu psr-update.php "${mu//__PK__/$PK}"

# Apache may lag behind `core install` (which went through WP-CLI): wait until WordPress answers over HTTP.
for _ in $(seq 1 40); do
  curl -fs -o /dev/null http://localhost:8080/ && break
  sleep 3
done
curl -fs -o /dev/null http://localhost:8080/

# Git Bash on Windows ships no jq: run it from an image (stdin, or files under out/).
command -v jq >/dev/null || jq() { docker run -i --rm -e EXPECTED_VERSION -v "$(pwd -W 2>/dev/null || pwd)/out:/w/out" -w /w ghcr.io/jqlang/jq@sha256:096b83865ad59b5b02841f103f83f45c51318394331bf1995e187ea3be937432 "$@"; } # jq:1.7.1

base64url_decode() { # stdin -> stdout; re-pads and maps -_ to +/
  local s; s=$(tr -d '\r\n' | tr '_-' '/+')
  while [ $(( ${#s} % 4 )) -ne 0 ]; do s="$s="; done
  printf '%s' "$s" | base64 -d
}
connect() { wpcli puzzles-site-reports connect --porcelain | tr -d '\r\n'; } # prints the connection string
token_of() { local s="$1"; echo "${s#pzr1.}" | base64url_decode | jq -r .token; }
fresh_token() { token_of "$(connect)"; } # rotates the connection, prints the new token
call() { # call <route> [token] -> HTTP status; the body lands in out/<route>.json
  local h=(); [ -z "${2:-}" ] || h=(-H "X-Puzzles-Reports-Token: $2")
  curl -s -o "out/$1.json" -w '%{http_code}' "${h[@]}" "http://localhost:8080/?rest_route=/puzzles-reports/v1/$1&_=$(date +%s%N)"
}
delete_update_transients() { # forces the never-checked state
  for t in update_core update_plugins update_themes; do wpcli transient delete "$t" --network >/dev/null 2>&1 || true; done
}

# ---- cases (plain functions; run in the fixed order of CASES at the bottom) ----
# A negative check captures the command's output first (o=$(...)) and tests it after, so a failing command fails the
# case; `! grep ... || return 1` only on files (a bare `! x` never trips set -e).
case_plugin_active() {
  [ "$(wpcli plugin get puzzles-site-reports --field=status)" = "active" ]
  [ "$(wpcli plugin get puzzles-site-reports --field=version)" = "$EXPECTED_VERSION" ]
}

case_auth() {
  wpcli option delete puzzles_site_reports_token >/dev/null 2>&1 || true
  [ "$(call status)" = 401 ]                                      # no token, not connected
  [ "$(jq -r .code out/status.json)" = puzzles_reports_unauthorized ]
  s1=$(connect); t1=$(token_of "$s1")
  [ "$(call status "$t1")" = 200 ]
  [ "$(call status wrong)" = 401 ]
  [ "$(jq -r .code out/status.json)" = puzzles_reports_unauthorized ]
  s2=$(connect); t2=$(token_of "$s2")
  [ "$(call status "$t1")" = 401 ]                                 # rotated: the old one is dead at once
  [ "$(call status "$t2")" = 200 ]
  [ "${s2:0:5}" = "pzr1." ]
  [ "${#t2}" -eq 64 ]                                              # 64 hex
  site=$(echo "${s2#pzr1.}" | base64url_decode | jq -r .site); [ "$site" = "http://localhost:8080" ]
  o=$(wpcli option get puzzles_site_reports_token); [[ $o != *"$t2"* ]]   # only the hash is stored
  [ "$(wpcli option get puzzles_site_reports_token --format=json | jq -r .hash | tr -d '\r')" = "$(printf %s "$t2" | sha256sum | cut -c1-64)" ]
  # not in the public index (plain permalinks: /wp-json/ is the home page, so ask through rest_route)
  idx=$(curl -s 'http://localhost:8080/?rest_route=/')
  [ "$(echo "$idx" | jq -r '.namespaces | index("wp/v2") != null')" = true ]  # it is the real index
  [ "$(echo "$idx" | jq -r '[.namespaces[], (.routes | keys[])] | map(select(contains("puzzles-reports"))) | length')" = 0 ]
  curl -s -D - -o /dev/null "http://localhost:8080/?rest_route=/puzzles-reports/v1/status&_=1" -H "X-Puzzles-Reports-Token: $t2" | grep -qi '^cache-control:.*no-store'
  curl -s -D - -o /dev/null "http://localhost:8080/?rest_route=/puzzles-reports/v1/status&_=2" | grep -qi '^cache-control:.*no-store' # the 401 too
  o=$(wpcli puzzles-site-reports status)
  grep -q 'connected: yes' <<<"$o"
  [[ $o != *"$t2"* ]]
}

case_auth_locked_rest() { # another plugin refuses every unauthenticated REST request: our token must still work
  t=$(fresh_token)
  put_mu psr-lock.php '<?php add_filter( "rest_authentication_errors", function ( $r ) { return new WP_Error( "rest_not_logged_in", "x", array( "status" => 401 ) ); } );'
  [ "$(curl -s -o /dev/null -w '%{http_code}' 'http://localhost:8080/?rest_route=/wp/v2/users')" = 401 ]  # the lock is on
  [ "$(call status "$t")" = 200 ]
  # core matches routes case-insensitively: so do the token bypass and the no-store header
  ci='http://localhost:8080/?rest_route=/Puzzles-Reports/V1/status'
  [ "$(curl -s -o /dev/null -w '%{http_code}' -H "X-Puzzles-Reports-Token: $t" "$ci")" = 200 ]
  curl -s -D - -o /dev/null -H "X-Puzzles-Reports-Token: $t" "$ci" | grep -qi '^cache-control:.*no-store'
  # a missing or wrong token gets our own refusal, not the lock's, so the portal can tell the two apart
  [ "$(call status)" = 401 ]
  [ "$(jq -r .code out/status.json)" = puzzles_reports_unauthorized ]
  [ "$(call status wrong)" = 401 ]
  [ "$(jq -r .code out/status.json)" = puzzles_reports_unauthorized ]
  [ "$(curl -s -o /dev/null -w '%{http_code}' 'http://localhost:8080/?rest_route=/wp/v2/users')" = 401 ]  # nothing else loosened
  rm_mu psr-lock.php
}

case_deactivation_revokes() { # deactivating deletes the token; reactivating does not bring it back
  t=$(fresh_token); [ "$(call status "$t")" = 200 ]
  wpcli plugin deactivate puzzles-site-reports
  [ "$(wpcli eval 'var_export( get_option( "puzzles_site_reports_token" ) );' | tr -d '\r\n')" = false ]
  wpcli plugin activate puzzles-site-reports
  [ "$(call status "$t")" = 401 ]
}

case_status_fresh() { # no update check has run yet
  delete_update_transients
  t=$(fresh_token); [ "$(call status "$t")" = 200 ]
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
    file_put_contents( $d . "/index.php", "<?php // Silence is golden." );'
  put_mu psr-test-mu.php '<?php
/*
Plugin Name: PSR Test MU
Version: 1.2.3
*/'
  delete_update_transients
  wpcli eval 'wp_update_plugins(); wp_update_themes(); wp_version_check();'
  wpcli option update default_comment_status closed
  # No scan is run (too heavy): seed Wordfence's own store through its public API instead, so the reading path runs for real.
  # Issue 1 is open: a distinctive shortMsg that holds a server path (it must come back relative), a different longMsg,
  # a path in its private data. Issue 2 is ignored (its id is looked up, not assumed). Issue 3 is open, low severity, and
  # holds a path above the install root, a foreign Unix path and a Windows path: all three must go.
  wpcli eval '
    global $wpdb;
    $i = wfIssues::shared();
    $i->addIssue( "wfPluginUpgrade", 75, "a", "a", "PSR-short-marker &amp; <b>bold</b> in " . WP_CONTENT_DIR . "/plugins/x.php", "PSR-long-marker", array( "secret" => "/var/www/html/private-data" ) );
    $i->addIssue( "wfThemeUpgrade", 50, "b", "b", "ignored one", "long", array() );
    $i->addIssue( "wfPluginUpgrade", 25, "c", "c", "PSR-path-marker " . dirname( ABSPATH ) . "/wp-config.php and /etc/passwd and C:\\inetpub\\x.php end", "long", array() );
    $id = (int) $wpdb->get_var( "SELECT id FROM " . $i->getIssuesTable() . " WHERE type = \"wfThemeUpgrade\"" );
    if ( ! $id ) { exit( 1 ); }
    $i->updateIssue( $id, "ignoreP" );
    wfScanner::shared()->recordLastScanTime();'
  t=$(fresh_token); [ "$(call status "$t")" = 200 ]
  jq -e '.wordfence.ignored == 1 and (.wordfence.lastScanAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))' out/status.json
  jq -e '.wordfence.issues | length == 2 and .[0].type == "wfPluginUpgrade" and .[0].severity == 75 and .[0].shortMsg == "PSR-short-marker & bold in wp-content/plugins/x.php" and (.[0].firstSeenAt | type == "string") and (.[0] | keys | sort) == ["firstSeenAt","severity","shortMsg","type"]' out/status.json
  jq -e '.wordfence.issues[1] | .severity == 25 and .shortMsg == "PSR-path-marker wp-config.php and  and  end"' out/status.json
  ! grep -q 'PSR-long-marker' out/status.json || return 1               # shortMsg, never longMsg
  ! grep -q 'private-data' out/status.json || return 1                  # Wordfence's per-issue data never leaves
  ! grep -qE '/var/www|passwd|inetpub' out/status.json || return 1      # no server path anywhere
  jq -e '.wordpress.updatesCheckedAt != null' out/status.json
  jq -e '.plugins[] | select(.file == "akismet/akismet.php") | .active == false and .version == "5.0" and (.update | type == "string") and .autoUpdate == true' out/status.json
  jq -e '.plugins[] | select(.file == "puzzles-site-reports/puzzles-site-reports.php") | .autoUpdate == false' out/status.json
  jq -e '.themes[] | select(.stylesheet == "twentytwentyone") | (.update | type == "string") and .active == false and .parent == null' out/status.json
  jq -e '.themes[] | select(.stylesheet == "psr-child") | .parent == "twentytwentyone" and .active == false and .name == "PSR Child"' out/status.json
  jq -e '.mustUse[] | select(.file == "psr-test-mu.php") | . == {"file": "psr-test-mu.php", "name": "PSR Test MU", "version": "1.2.3"}' out/status.json
  jq -e '.comments.defaultStatus == "closed"' out/status.json
  jq -e '.wordfence.active == true and (.wordfence | keys | sort) == ["active","ignored","issues","lastScanAt","version"]' out/status.json
  # active but unreadable (forced through the test-only filter): null, while plugins[] still lists it active
  put_mu psr-wf.php '<?php add_filter( "puzzles_sr_wordfence_reader_ok", "__return_false" );'
  [ "$(call status "$t")" = 200 ]
  jq -e '.wordfence == null and ([.plugins[] | select(.file == "wordfence/wordfence.php" and .active == true)] | length == 1)' out/status.json
  rm_mu psr-wf.php
  wpcli plugin deactivate wordfence
  [ "$(call status "$t")" = 200 ]
  # installed but inactive: still reported, its classes are not loaded, so nothing is read, no fatal
  jq -e '.wordfence.active == false and .wordfence.issues == [] and .wordfence.ignored == 0 and .wordfence.lastScanAt == null' out/status.json
  # Left for later cases: Wordfence (inactive, seeded), akismet 5.0 (inactive), twentytwentyone 1.0, filled update transients.
  rm_mu psr-test-mu.php
  wpcli theme delete psr-child
  wpcli plugin auto-updates disable akismet
  wpcli option update default_comment_status open
}

case_seo_without_rank_math() {
  t=$(fresh_token); [ "$(call seo "$t")" = 200 ]
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
  # the same process reports the pages it read, so the memory figure is of a real report
  o=$(wpcli eval '$b = memory_get_usage(); $r = puzzles_sr_seo(); echo $r["types"]["page"]["items"], " ", memory_get_peak_usage() - $b;' | tr -d '\r\n')
  echo "seo: ${o% *} pages, peak memory over baseline ${o#* } bytes"
  [ "${o% *}" = 306 ]
  [ "${o#* }" -lt 33554432 ] # under 32 MB; loading the seeded meta alone would be ~60 MB

  t=$(fresh_token); [ "$(call seo "$t")" = 200 ]
  jq -e '.plugin.name == "rank_math" and (.plugin.version | type == "string" and length > 0)' out/seo.json
  jq -e --argjson a "$a" '.items[] | select(.id == $a) | .focusKeywords == ["roofing miami","roof repair"] and .seoScore == 81 and .noindex == true and .metaTitle == null and .type == "page" and .title == "About" and (.url | type == "string")' out/seo.json
  jq -e --argjson b "$b" '.items[] | select(.id == $b) | .focusKeywords == [] and .seoScore == null and .noindex == null' out/seo.json
  jq -e --argjson c "$c" '.items[] | select(.id == $c) | .noindex == false' out/seo.json
  jq -e --argjson d "$d" '.items[] | select(.id == $d) | .title == "Tom & Jerry'"'"'s Show"' out/seo.json
  jq -e --argjson e "$e" '.items[] | select(.id == $e) | .metaTitle == "Best & Roofing | Acme" and .metaDescription == "Fast \"repairs\" & more" and .focusKeywords == ["a","b"]' out/seo.json
  jq -e --argjson p "$p" '.items[] | select(.id == $p) | .type == "post" and .title == "News"' out/seo.json
  jq -e '[.items[] | select(.title == "Draft")] | length == 0' out/seo.json
  jq -e '[.items[] | .url == null or (.url | type == "string")] | all' out/seo.json
  jq -e '.types.page.truncated == false and .types.page.items == 306 and (.types | has("product") | not)' out/seo.json
  jq -e '([.items[] | select(.type == "page")] | length) == .types.page.items and (.items | length) == (.types.page.items + .types.post.items)' out/seo.json
  # Left for later cases: Rank Math active and the hand-made posts; the 300 seeded pages are deleted to keep the site light.
  wpcli eval 'foreach ( get_posts( array( "post_type" => "page", "post_status" => "any", "meta_key" => "psr_seed", "numberposts" => -1, "fields" => "ids" ) ) as $id ) { wp_delete_post( $id, true ); }'
}

case_update_offer() { # manifests signed by this run's throwaway key, served by the wp container (reached as http://wp)
  ours=puzzles-site-reports/puzzles-site-reports.php
  sha=$(sha256sum ../dist/puzzles-site-reports.zip | cut -c1-64)
  pkg="puzzles-sr://9.9.9/$sha"                    # the offer's package: a sentinel only our download hook can fetch
  bad=$(printf x | sha256sum | cut -c1-64)        # a sha256 the zip does not have
  kp2=$(wpcli eval 'echo base64_encode( sodium_crypto_sign_keypair() );' | tr -d '\r\n') # another key
  # the release asset: this run's own zip, so the real update at the end reinstalls the same plugin
  wpcli eval "wp_mkdir_p( ABSPATH . 'releases/download/v9.9.9' ); copy( '/dist/puzzles-site-reports.zip', ABSPATH . 'releases/download/v9.9.9/puzzles-site-reports.zip' );"
  [ "$(curl -fs http://localhost:8080/releases/download/v9.9.9/puzzles-site-reports.zip | sha256sum | cut -c1-64)" = "$sha" ]

  manifest() { # manifest <version> <sha256> [keypair; '' = unsigned] [PHP array items set after signing] [... before signing]
    wpcli eval "puzzles_sr_test_manifest( '$1', '$2', '${3-$KP}', array( ${4:-} ), array( ${5:-} ) );"
  }
  check() { wpcli transient delete update_plugins --network; wpcli eval 'wp_update_plugins();'; }
  offered() { wpcli plugin list --name=puzzles-site-reports --field=update_version | tr -d '\r\n'; }
  filter() { # filter <installed-version> <plugin-file>: our update filter called directly; "input" is what core handed in
    wpcli eval "echo wp_json_encode( puzzles_sr_update_offer( 'input', array( 'Version' => '$1' ), '$2', array() ) );" | tr -d '\r\n'
  }
  download() { wpcli eval "echo puzzles_sr_test_download( '${1:-$pkg}' );" | tr -d '\r\n'; } # see the setup mu-plugin
  not_offered() { # neither the update check nor the filter called directly (which api.wordpress.org cannot mask) offers anything
    check
    local o f; o=$(offered); f=$(filter 1.0.0 "$ours")
    [ -z "$o" ]
    [ "$f" = '"input"' ]
  }
  marker() { wpcli eval 'echo (int) file_exists( WP_PLUGIN_DIR . "/puzzles-site-reports/psr-marker" );' | tr -d '\r\n'; } # 1 until an install replaces the folder
  update_fails() { # a real `wp plugin update` fails and installs nothing; its output lands in out/update.log
    if wpcli plugin update puzzles-site-reports >out/update.log 2>&1; then cat out/update.log; return 1; fi
    [ "$(marker)" = 1 ]
    [ "$(wpcli plugin get puzzles-site-reports --field=status)" = active ]
  }

  not_offered # no manifest yet (WordPress answers its 404)

  # signed: offered, and the package is the sentinel of the signed version and sha256 (a `package` field is ignored)
  manifest 9.9.9 "$sha" "$KP" "'package' => 'http://evil.example/x.zip'"
  check
  o=$(offered); [ "$o" = 9.9.9 ]
  o=$(wpcli eval 'echo get_site_transient( "update_plugins" )->response["puzzles-site-reports/puzzles-site-reports.php"]->package;' | tr -d '\r\n')
  [ "$o" = "$pkg" ]
  f=$(filter 1.0.0 "$ours"); [ "$f" != '"input"' ]; [[ $f != *evil* ]]   # the offer is real...
  f=$(filter 99.0.0 "$ours"); [ "$f" = '"input"' ]                        # ...but not when the installed version is not older
  f=$(filter 1.0.0 akismet/akismet.php); [ "$f" = '"input"' ]             # ...and never for another plugin's file
  wpcli eval 'echo (int) apply_filters("auto_update_plugin", false, (object) ["plugin" => "puzzles-site-reports/puzzles-site-reports.php"]);' | grep -qx 1
  wpcli eval 'echo (int) apply_filters("auto_update_plugin", false, (object) ["plugin" => "akismet/akismet.php"]);' | grep -qx 0
  # the download hook maps the sentinel to the release zip and accepts it (one temp file, handed to core); a malformed
  # sentinel is refused; any other package is core's
  o=$(download); [ "$o" = "$sha 1" ]
  o=$(download 'puzzles-sr://9.9.9/nothex'); [ "$o" = "puzzles_sr_bad_package 0" ]
  o=$(download http://wp/releases/download/v9.9.9/puzzles-site-reports.zip); [ "$o" = "false 0" ]

  # nothing is offered unless the key signed exactly these five fields, all well formed
  manifest 9.9.9 "$sha" ''; not_offered                                                    # unsigned
  manifest 9.9.9 "$sha" "$KP" "'signature' => str_repeat( 'A', 86 ) . '=='"; not_offered  # well formed, does not verify
  manifest 9.9.9 "$sha" "$KP" "'signature' => 'AAAA'"; not_offered                        # wrong length
  manifest 9.9.9 "$sha" "$kp2"; not_offered                                                 # signed by another key
  manifest 9.9.9 "$sha" "$KP" "'version' => '9.9.10'"; not_offered                         # signed for another version
  manifest 9.9.9 "$sha" "$KP" "'tested' => '6.10'"; not_offered                            # a signed field changed after signing
  manifest 9.9.9 "$sha" "$KP" "'requires_php' => '5.6'"; not_offered                       # another one
  manifest 9.9.9 "$sha" "$KP" "'requires' => null"; not_offered                            # a signed field missing
  manifest 9.9.9 "$sha" "$KP" "" "'tested' => 'latest'"; not_offered                       # signed, but not a version
  manifest 9.9.9-beta "$sha"; not_offered                                                   # not X.Y.Z, though signed
  manifest 9.9.9 "$(tr a-f A-F <<<"$sha")"; not_offered                                     # not lowercase hex, though signed
  wpcli eval 'file_put_contents( ABSPATH . "test-manifest.json", "not json" );'; not_offered

  wpcli eval 'touch( WP_PLUGIN_DIR . "/puzzles-site-reports/psr-marker" );'
  # a signed sha256 the zip does not have: offered, but the download is refused, its temp file deleted, and the update fails
  manifest 9.9.9 "$bad"
  check; o=$(offered); [ "$o" = 9.9.9 ]
  o=$(download "puzzles-sr://9.9.9/$bad"); [ "$o" = "puzzles_sr_bad_package 0" ]
  update_fails
  grep -q 'does not match its signed manifest' out/update.log

  # without our download hook (the plugin not loaded while core runs the offer) core cannot fetch the sentinel: fails closed
  put_mu psr-nohook.php '<?php add_action( "plugins_loaded", function () { remove_filter( "upgrader_pre_download", "puzzles_sr_pre_download", 10 ); } );'
  manifest 9.9.9 "$sha"; check; o=$(offered); [ "$o" = 9.9.9 ]
  o=$(download); [ "$o" = "false 0" ] # the hook is really gone
  update_fails
  rm_mu psr-nohook.php

  # end to end: core installs the signed zip through the hook; the connection survives (core deactivates silently to update)
  t=$(fresh_token)
  manifest 9.9.9 "$sha"; check
  wpcli plugin update puzzles-site-reports
  [ "$(marker)" = 0 ] # the folder was replaced
  [ "$(wpcli plugin get puzzles-site-reports --field=status)" = active ]
  [ "$(call status "$t")" = 200 ]
  wpcli eval 'unlink( ABSPATH . "test-manifest.json" );'
}

# Fixed order (Task rulings). A new case is added to BOTH the function list and this one;
# the check below fails on any mismatch, so a case can never be silently skipped.
CASES=(case_plugin_active case_auth case_auth_locked_rest case_deactivation_revokes case_status_fresh case_status_wordfence_and_updates case_seo_without_rank_math case_seo_with_rank_math case_update_offer)

for c in "${CASES[@]}"; do
  declare -F "$c" >/dev/null || { echo "FAIL: listed case $c is not defined" >&2; exit 1; }
done
while read -r _ _ f; do
  case "$f" in case_*)
    [[ " ${CASES[*]} " == *" $f "* ]] || { echo "FAIL: defined case $f is not in CASES" >&2; exit 1; } ;;
  esac
done < <(declare -F)

for case_fn in "${CASES[@]}"; do # not $c: the cases set globals (case_seo_with_rank_math has its own $c)
  echo "== $case_fn"
  "$case_fn"
  echo "ok $case_fn"
done
echo "smoke: all ${#CASES[@]} cases passed"
