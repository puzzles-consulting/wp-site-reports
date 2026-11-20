<?php
/**
 * Plugin Name:       Puzzles Site Reports
 * Plugin URI:        https://github.com/puzzles-consulting/wp-site-reports
 * Description:       Read-only status and SEO reports of this WordPress site for Puzzles' client reports.
 * Version:           1.0.1
 * Requires at least: 5.8
 * Requires PHP:      7.4
 * Author:            Puzzles
 * Author URI:        https://puzzles.consulting
 * License:           GPL-2.0-or-later
 * License URI:       https://www.gnu.org/licenses/gpl-2.0.html
 * Update URI:        https://github.com/puzzles-consulting/wp-site-reports
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

define( 'PUZZLES_SITE_REPORTS_VERSION', '1.0.1' );
define( 'PUZZLES_SITE_REPORTS_OPTION', 'puzzles_site_reports_token' );
define( 'PUZZLES_SITE_REPORTS_NAMESPACE', 'puzzles-reports/v1' );
// The self-update's constants ("Self-update" below), defined before any other file is loaded, so that none can define
// them first. No filter changes them: the smoke test builds its own zip with other values (scripts/build.sh
// --test-overrides).
define( 'PUZZLES_SITE_REPORTS_MANIFEST_URL', 'https://github.com/puzzles-consulting/wp-site-reports/releases/latest/download/manifest.json' );
define( 'PUZZLES_SITE_REPORTS_PACKAGE_PREFIX', 'https://github.com/puzzles-consulting/wp-site-reports/releases/download/' );
// The most the update download reads, in bytes; the zip is well under 1 MB.
define( 'PUZZLES_SITE_REPORTS_MAX_PACKAGE', 5242880 );
// Base64 Ed25519 public key of the release signing key. A new key means a release that ships the new public key, signed
// with the old one (README, Release).
define( 'PUZZLES_SR_UPDATE_PUBKEY', 'FRx/KzeXTPzD6VBigvVottDDryTawD19IRq0FQ8uMXc=' );

/** Plain text for the portal: no markup, entities decoded, trimmed; null when nothing is left. */
function puzzles_sr_plain( $v ): ?string {
	if ( ! is_scalar( $v ) ) {
		return null;
	}
	$s = trim( html_entity_decode( wp_strip_all_tags( (string) $v ), ENT_QUOTES | ENT_HTML5, 'UTF-8' ) );
	return '' === $s ? null : $s;
}

/** Whether a REST route (as requested) is this plugin's namespace or below it. Core matches routes case-insensitively, so this does too. */
function puzzles_sr_is_our_route( string $route ): bool {
	return 0 === stripos( '/' . trim( $route, '/' ) . '/', '/' . PUZZLES_SITE_REPORTS_NAMESPACE . '/' );
}

require_once __DIR__ . '/includes/status.php';
require_once __DIR__ . '/includes/seo.php';

/** Rotates the token. Returns the connection string, or a WP_Error if it could not be stored. Only the SHA-256 hash is stored. */
function puzzles_sr_create_connection() {
	$token = bin2hex( random_bytes( 32 ) );
	$saved = update_option(
		PUZZLES_SITE_REPORTS_OPTION,
		array(
			'hash'      => hash( 'sha256', $token ),
			'createdAt' => puzzles_sr_iso( time() ),
		),
		false
	);
	if ( ! $saved ) {
		return new WP_Error( 'puzzles_reports_not_saved', 'The connection could not be saved.' );
	}
	$payload = wp_json_encode( array( 'site' => home_url(), 'token' => $token ), JSON_UNESCAPED_SLASHES );
	return 'pzr1.' . rtrim( strtr( base64_encode( $payload ), '+/', '-_' ), '=' );
}

/** Deletes the token; a network deactivation deletes every site's of this network. */
function puzzles_sr_disconnect( $network_wide = false ): void {
	if ( $network_wide ) { // true only on a multisite
		foreach ( get_sites( array( 'fields' => 'ids', 'number' => 0, 'network_id' => get_current_network_id() ) ) as $id ) {
			switch_to_blog( $id );
			delete_option( PUZZLES_SITE_REPORTS_OPTION );
			restore_current_blog();
		}
		return;
	}
	delete_option( PUZZLES_SITE_REPORTS_OPTION );
}
// Deactivating the plugin revokes the connection. (Core deactivates silently while it updates a plugin: no hook runs, the token survives.)
register_deactivation_hook( __FILE__, 'puzzles_sr_disconnect' );

/** The stored { hash, createdAt }, or null when not connected. */
function puzzles_sr_connection(): ?array {
	$o = get_option( PUZZLES_SITE_REPORTS_OPTION );
	return is_array( $o ) && is_string( $o['hash'] ?? null ) && is_string( $o['createdAt'] ?? null ) ? $o : null;
}

function puzzles_sr_token_valid( $token ): bool {
	$c = puzzles_sr_connection();
	return $c && is_string( $token ) && hash_equals( $c['hash'], hash( 'sha256', $token ) );
}

/** One fixed refusal for every cause (no token, wrong token, not connected). */
function puzzles_sr_unauthorized(): WP_Error {
	return new WP_Error( 'puzzles_reports_unauthorized', 'Not authorized.', array( 'status' => 401 ) );
}

/** `_` is 32 lowercase hex, fresh per request, so an edge cache keyed by URL never serves a report to another (contract). */
function puzzles_sr_cache_key_ok( $v ): bool {
	return is_string( $v ) && 1 === preg_match( '/^[0-9a-f]{32}\z/', $v );
}

/** @return true|WP_Error */
function puzzles_sr_authorized( WP_REST_Request $request ) {
	return puzzles_sr_cache_key_ok( $request->get_query_params()['_'] ?? null )
		&& puzzles_sr_token_valid( $request->get_header( 'X-Puzzles-Reports-Token' ) ) ? true : puzzles_sr_unauthorized();
}

function puzzles_sr_register_route( string $route, callable $callback ): void {
	register_rest_route(
		PUZZLES_SITE_REPORTS_NAMESPACE,
		$route,
		array(
			'methods'             => 'GET',
			'show_in_index'       => false,
			'permission_callback' => 'puzzles_sr_authorized',
			'callback'            => function ( $request ) use ( $callback ) {
				try {
					require_once ABSPATH . 'wp-admin/includes/plugin.php'; // REST requests do not load it
					return $callback( $request );
				} catch ( Throwable $e ) {
					error_log( 'Puzzles Site Reports: ' . get_class( $e ) . ' in ' . $request->get_route() ); // class and route only, never the message
					return new WP_Error( 'puzzles_reports_failed', 'The report could not be built.', array( 'status' => 500 ) );
				}
			},
		)
	);
}

add_filter(
	'rest_post_dispatch',
	function ( $result, $server, $request ) {
		if ( $result instanceof WP_HTTP_Response && puzzles_sr_is_our_route( $request->get_route() ) ) {
			$result->header( 'Cache-Control', 'no-store' );
		}
		return $result;
	},
	10,
	3
);

// Core's index lists every namespace, and the namespace's own index route (/puzzles-reports/v1, which core registers
// with the first route), even when our routes are hidden (show_in_index => false): drop both. (A direct request to
// /puzzles-reports/v1 without a valid token gets our 401, which still tells it apart from a site without the plugin.)
add_filter(
	'rest_index',
	function ( $response ) {
		if ( ! $response instanceof WP_HTTP_Response ) {
			return $response;
		}
		$d = $response->get_data();
		if ( is_array( $d['namespaces'] ?? null ) ) {
			$d['namespaces'] = array_values( array_diff( $d['namespaces'], array( PUZZLES_SITE_REPORTS_NAMESPACE ) ) );
		}
		unset( $d['routes'][ '/' . PUZZLES_SITE_REPORTS_NAMESPACE ] );
		$response->set_data( $d );
		return $response;
	}
);

/**
 * A report is for the token holder only: page caches must never store one (LiteSpeed Cache caches REST answers for a
 * week by default, and serves them to anyone). DONOTCACHEPAGE is the convention most page caches honour.
 */
function puzzles_sr_no_page_cache(): void {
	if ( ! defined( 'DONOTCACHEPAGE' ) ) {
		define( 'DONOTCACHEPAGE', true );
	}
	do_action( 'litespeed_control_set_nocache', 'puzzles-site-reports' );
}

// Another plugin or snippet may refuse every unauthenticated REST request (it runs before permission_callback). Our
// routes answer to the token alone: a request for our namespace passes with a valid token and gets our own fixed 401
// without one, whatever an earlier filter returned, so the portal can tell "bad token" from "this site blocks REST".
// Nothing else is touched. A filter running after priority 999 can still override this.
add_filter(
	'rest_authentication_errors',
	function ( $result ) {
		if ( ! puzzles_sr_is_our_route( (string) ( $GLOBALS['wp']->query_vars['rest_route'] ?? '' ) ) ) {
			return $result;
		}
		puzzles_sr_no_page_cache();
		return puzzles_sr_cache_key_ok( $_GET['_'] ?? null ) && puzzles_sr_token_valid( $_SERVER['HTTP_X_PUZZLES_REPORTS_TOKEN'] ?? '' )
			? true : puzzles_sr_unauthorized();
	},
	999
);

add_action(
	'rest_api_init',
	function () {
		puzzles_sr_register_route( '/status', 'puzzles_sr_status' );
		puzzles_sr_register_route( '/seo', 'puzzles_sr_seo' );
	}
);

// ---- Self-update from GitHub Releases, signed ----
// Core runs the offer only inside its own update check (cron or admin), never on a front-end request, and caches the
// answer in the update_plugins transient, so nothing is cached here. Any failure means no offer for this plugin.
// A manifest counts only when its Ed25519 signature over all its fields verifies with PUZZLES_SR_UPDATE_PUBKEY (top of
// this file), and the package is installed only when it hashes to the signed sha256. The signing key never lives in
// GitHub (README, Release): write access to the repository alone cannot ship a zip to the sites.

/**
 * The manifest when every signed field is well formed and the signature verifies, else null. The signed message is the
 * fields below joined by "\n", in this order (scripts/wp-sr-promote builds the same string).
 */
function puzzles_sr_verified_manifest( string $body ): ?array {
	$m = json_decode( $body, true );
	if ( ! is_array( $m ) || ! is_string( $m['signature'] ?? null ) ) {
		return null;
	}
	$ver     = '/^\d+\.\d+(\.\d+)?\z/';
	$formats = array(
		'version'      => '/^\d+\.\d+\.\d+\z/',
		'sha256'       => '/^[0-9a-f]{64}\z/',
		'requires'     => $ver,
		'requires_php' => $ver,
		'tested'       => $ver,
	);
	$signed = array();
	foreach ( $formats as $field => $re ) {
		if ( ! is_string( $m[ $field ] ?? null ) || ! preg_match( $re, $m[ $field ] ) ) {
			return null;
		}
		$signed[] = $m[ $field ];
	}
	// Wrong lengths are refused before sodium: sodium_compat (WordPress' fallback when ext-sodium is missing) throws on them.
	$key = base64_decode( PUZZLES_SR_UPDATE_PUBKEY, true );
	$sig = base64_decode( $m['signature'], true );
	if ( ! is_string( $key ) || 32 !== strlen( $key ) || ! is_string( $sig ) || 64 !== strlen( $sig ) ) {
		return null;
	}
	try {
		return sodium_crypto_sign_verify_detached( $sig, implode( "\n", $signed ), $key ) ? $m : null;
	} catch ( Throwable $e ) {
		return null;
	}
}

/**
 * Core's `update_plugins_github.com` filter (the header's Update URI host). For this plugin it answers our verified offer
 * or none (false), never what an earlier filter put in $update; every other plugin's answer passes through.
 */
function puzzles_sr_update_offer( $update, $plugin_data, $plugin_file ) {
	if ( plugin_basename( __FILE__ ) !== $plugin_file ) {
		return $update;
	}
	$res = wp_remote_get( PUZZLES_SITE_REPORTS_MANIFEST_URL, array( 'timeout' => wp_doing_cron() ? 10 : 3, 'limit_response_size' => 4096 ) );
	if ( is_wp_error( $res ) || 200 !== (int) wp_remote_retrieve_response_code( $res ) ) {
		return false;
	}
	$m = puzzles_sr_verified_manifest( wp_remote_retrieve_body( $res ) );
	if ( ! $m || ! version_compare( $m['version'], (string) $plugin_data['Version'], '>' ) ) {
		return false;
	}
	return array(
		'slug'         => 'puzzles-site-reports',
		'version'      => $m['version'],
		// Not a URL core can fetch: only puzzles_sr_pre_download() turns it into the download, checked against the signed
		// sha256 it carries. Without that hook (plugin inactive, the offer installed from elsewhere) the update fails closed.
		'package'      => 'puzzles-sr://' . $m['version'] . '/' . $m['sha256'],
		'requires'     => $m['requires'],
		'requires_php' => $m['requires_php'],
		'tested'       => $m['tested'],
		'url'          => 'https://github.com/puzzles-consulting/wp-site-reports',
	);
}
add_filter( 'update_plugins_github.com', 'puzzles_sr_update_offer', 10, 3 );

/**
 * Core's download step for this plugin's sentinel package: the release zip, returned only if it hashes to the signed
 * sha256. At most PUZZLES_SITE_REPORTS_MAX_PACKAGE bytes are read (a bigger answer is cut there and fails the hash).
 * Any other package for this plugin is refused; every other plugin's download is left to core.
 */
function puzzles_sr_pre_download( $reply, $package, $upgrader = null, $hook_extra = array() ) {
	$ours = isset( $hook_extra['plugin'] ) && plugin_basename( __FILE__ ) === $hook_extra['plugin'];
	if ( is_wp_error( $reply ) || ( isset( $hook_extra['plugin'] ) && ! $ours ) ) {
		return $reply;
	}
	if ( ! is_string( $package ) || 0 !== strpos( $package, 'puzzles-sr://' ) ) {
		return $ours ? new WP_Error( 'puzzles_sr_not_signed', 'This plugin installs only its own signed updates.' ) : $reply;
	}
	if ( ! preg_match( '~^puzzles-sr://(\d+\.\d+\.\d+)/([0-9a-f]{64})\z~', $package, $p ) ) {
		return new WP_Error( 'puzzles_sr_bad_package', 'The update package does not match its signed manifest.' );
	}
	require_once ABSPATH . 'wp-admin/includes/file.php';
	$file = wp_tempnam( 'puzzles-site-reports.zip' );
	$res  = wp_safe_remote_get(
		PUZZLES_SITE_REPORTS_PACKAGE_PREFIX . 'v' . $p[1] . '/puzzles-site-reports.zip',
		array(
			'timeout'             => 60, // a hostile, slow asset cannot hold the update longer
			'stream'              => true,
			'filename'            => $file,
			'limit_response_size' => PUZZLES_SITE_REPORTS_MAX_PACKAGE,
		)
	);
	if ( is_wp_error( $res ) || 200 !== (int) wp_remote_retrieve_response_code( $res ) ) {
		wp_delete_file( $file );
		return new WP_Error( 'puzzles_sr_download_failed', 'The update package could not be downloaded.' );
	}
	if ( ! hash_equals( $p[2], (string) hash_file( 'sha256', $file ) ) ) {
		wp_delete_file( $file );
		return new WP_Error( 'puzzles_sr_bad_package', 'The update package does not match its signed manifest.' );
	}
	return $file;
}
add_filter( 'upgrader_pre_download', 'puzzles_sr_pre_download', 10, 4 );

// Sites install this plugin's own signed updates themselves; any other offer for it, and every other plugin, keeps
// whatever core decided.
add_filter(
	'auto_update_plugin',
	function ( $update, $item ) {
		return is_object( $item ) && plugin_basename( __FILE__ ) === ( $item->plugin ?? null )
			&& is_string( $item->package ?? null ) && 0 === strpos( $item->package, 'puzzles-sr://' ) ? true : $update;
	},
	10,
	2
);

// No email when an automatic update run only updated this plugin, successfully (routine, and every site would mail its
// admin); a failure, or a batch with another plugin, is mailed as core decides.
add_filter(
	'auto_plugin_update_send_email',
	function ( $enabled, $results ) {
		foreach ( (array) $results as $r ) {
			if ( plugin_basename( __FILE__ ) !== ( $r->item->plugin ?? null ) || true !== ( $r->result ?? null ) ) {
				return $enabled;
			}
		}
		return $results ? false : $enabled;
	},
	10,
	2
);

// ---- Update-check freshness ----
// Why: no transient shape tells an answered update check from a failed one, and any filter can rewrite stored offers
// that a failed check then saves back. What: when api.wordpress.org answers core's own check (HTTP 200, the JSON key it
// expects, the request made by wp_update_plugins/wp_update_themes/wp_version_check itself), the next save of that
// transient, once, carries the time (`puzzles_sr_checked`) and its offers (`puzzles_sr_offers`): properties of core's
// own transient, no option of ours. status.php reads them past the transient filters (contract: updatesCheckedAt).
( function () {
	$check = array( 'plugins' => 'wp_update_plugins', 'themes' => 'wp_update_themes', 'core' => 'wp_version_check' );
	$at    = array(); // [ type => when core's check of it was answered, in this request ], until its next save
	add_action(
		'http_api_debug',
		function ( $response, $context, $class, $args, $url ) use ( &$at, $check ) {
			if ( 'response' !== $context || 200 !== (int) wp_remote_retrieve_response_code( $response )
				|| ! preg_match( '~^https?://api\.wordpress\.org/(plugins|themes|core)/(?:update|version)-check/~', (string) $url, $m ) ) {
				return;
			}
			$body = json_decode( wp_remote_retrieve_body( $response ), true );
			if ( ! isset( $body[ 'core' === $m[1] ? 'offers' : $m[1] ] ) ) {
				return;
			}
			// The request must be core's own: the caller of the innermost wp_remote_post/get is core's check function.
			$trace = debug_backtrace( DEBUG_BACKTRACE_IGNORE_ARGS );
			foreach ( $trace as $i => $frame ) {
				if ( in_array( $frame['function'], array( 'wp_remote_post', 'wp_remote_get' ), true ) ) {
					if ( ( $trace[ $i + 1 ]['function'] ?? '' ) === $check[ $m[1] ] ) {
						$at[ $m[1] ] = time();
					}
					return;
				}
			}
		},
		10,
		5
	);
	foreach ( array_keys( $check ) as $type ) {
		add_filter(
			"pre_set_site_transient_update_{$type}",
			function ( $value ) use ( &$at, $type ) {
				if ( isset( $at[ $type ] ) && is_object( $value ) ) {
					$value->puzzles_sr_checked = $at[ $type ];
					$value->puzzles_sr_offers  = puzzles_sr_offer_versions( $type, $value );
				}
				unset( $at[ $type ] ); // once: never a transient rebuilt after the answer's save
				return $value;
			},
			PHP_INT_MAX
		);
	}
} )();

// ---- Admin page: Tools > Site Reports ----
/** On a multisite only a network admin: a sub-site admin must not read network-wide data. */
function puzzles_sr_capability(): string {
	return is_multisite() ? 'manage_network_options' : 'manage_options';
}

add_action(
	'admin_menu',
	function () {
		// Core refuses the page to anyone without the capability before the callback runs.
		add_management_page( 'Puzzles Site Reports', 'Site Reports', puzzles_sr_capability(), 'puzzles-site-reports', 'puzzles_sr_admin_page' );
	}
);

function puzzles_sr_admin_page(): void {
	$string = '';
	$notice = '';
	$action = $_POST['puzzles_sr_action'] ?? '';
	if ( 'POST' === $_SERVER['REQUEST_METHOD'] && '' !== $action && current_user_can( puzzles_sr_capability() ) ) {
		if ( 'connect' === $action ) {
			check_admin_referer( 'puzzles_sr_connect' );
			$seen = sanitize_text_field( wp_unslash( $_POST['puzzles_sr_seen'] ?? '' ) );
			if ( $seen !== ( puzzles_sr_connection()['createdAt'] ?? '' ) ) { // a reload or a second click: the string already pasted into the portal stays valid
				$notice = 'A connection was already created; create a new one?';
			} else {
				$r = puzzles_sr_create_connection();
				if ( is_wp_error( $r ) ) {
					$notice = $r->get_error_message();
				} else {
					$string = $r;
				}
			}
		} elseif ( 'disconnect' === $action ) {
			check_admin_referer( 'puzzles_sr_disconnect' );
			puzzles_sr_disconnect();
		}
	}
	$c    = puzzles_sr_connection();
	$seen = $c['createdAt'] ?? '';
	echo '<div class="wrap"><h1>Puzzles Site Reports</h1>';
	echo '<p>Version ' . esc_html( PUZZLES_SITE_REPORTS_VERSION ) . '</p>';
	echo '<p>' . ( $c ? 'Connected since ' . esc_html( $seen ) : 'Not connected' ) . '</p>';
	if ( ! is_ssl() ) {
		echo '<div class="notice notice-warning inline"><p>This page is not on HTTPS: the connection string, and the token in it, would travel unencrypted. The portal refuses sites without HTTPS.</p></div>';
	}
	if ( $notice ) {
		echo '<div class="notice notice-warning inline"><p>' . esc_html( $notice ) . '</p></div>';
	}
	if ( $string ) {
		echo '<p><input type="text" class="large-text code" readonly value="' . esc_attr( $string ) . '"></p>';
		echo '<p>This string is shown once. Paste it into the portal\'s Report setup.</p>';
	}
	$ask = $c ? ' onsubmit="return confirm(' . esc_attr( wp_json_encode( 'This disconnects the current portal connection.' ) ) . ')"' : '';
	echo '<form method="post"' . $ask . '>';
	wp_nonce_field( 'puzzles_sr_connect' );
	echo '<input type="hidden" name="puzzles_sr_action" value="connect"><input type="hidden" name="puzzles_sr_seen" value="' . esc_attr( $seen ) . '"><button class="button button-primary">Create connection</button></form>';
	if ( $c ) {
		echo '<form method="post" style="margin-top:8px" onsubmit="return confirm(' . esc_attr( wp_json_encode( 'Disconnect this site from the portal?' ) ) . ')">';
		wp_nonce_field( 'puzzles_sr_disconnect' );
		echo '<input type="hidden" name="puzzles_sr_action" value="disconnect"><button class="button">Disconnect</button></form>';
	}
	echo '</div>';
}

// ---- WP-CLI ----
if ( defined( 'WP_CLI' ) && WP_CLI ) {
	class Puzzles_SR_CLI {
		/**
		 * Creates a connection (rotating any previous one) and prints the string.
		 *
		 * [--porcelain]
		 * : Print only the connection string.
		 */
		public function connect( $args, $assoc ) {
			$s = puzzles_sr_create_connection();
			if ( is_wp_error( $s ) ) {
				WP_CLI::error( $s->get_error_message() );
			}
			WP_CLI::line( $s );
			if ( empty( $assoc['porcelain'] ) ) {
				WP_CLI::warning( 'Shown once. Paste it into the portal\'s Report setup.' );
			}
		}

		/** Shows the version and whether a connection exists (never the token). */
		public function status() {
			$c = puzzles_sr_connection();
			WP_CLI::line( 'version: ' . PUZZLES_SITE_REPORTS_VERSION );
			WP_CLI::line( 'connected: ' . ( $c ? 'yes' : 'no' ) );
			if ( $c ) {
				WP_CLI::line( 'createdAt: ' . $c['createdAt'] );
			}
		}
	}
	WP_CLI::add_command( 'puzzles-site-reports', 'Puzzles_SR_CLI' );
}
