<?php
/**
 * Plugin Name:       Puzzles Site Reports
 * Plugin URI:        https://github.com/puzzles-consulting/wp-site-reports
 * Description:       Read-only status and SEO reports of this WordPress site for Puzzles' client reports.
 * Version:           1.0.0
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

define( 'PUZZLES_SITE_REPORTS_VERSION', '1.0.0' );
define( 'PUZZLES_SITE_REPORTS_OPTION', 'puzzles_site_reports_token' );
define( 'PUZZLES_SITE_REPORTS_NAMESPACE', 'puzzles-reports/v1' );

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
	$route = '/' . trim( $route, '/' );
	$ns    = '/' . PUZZLES_SITE_REPORTS_NAMESPACE;
	return 0 === strcasecmp( $route, $ns ) || 0 === strncasecmp( $route, $ns . '/', strlen( $ns ) + 1 );
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
			'createdAt' => gmdate( 'c' ),
		),
		false
	);
	if ( ! $saved ) {
		return new WP_Error( 'puzzles_reports_not_saved', 'The connection could not be saved.' );
	}
	$payload = wp_json_encode( array( 'site' => home_url(), 'token' => $token ), JSON_UNESCAPED_SLASHES );
	return 'pzr1.' . rtrim( strtr( base64_encode( $payload ), '+/', '-_' ), '=' );
}

function puzzles_sr_disconnect(): void {
	delete_option( PUZZLES_SITE_REPORTS_OPTION );
}

/** The stored { hash, createdAt }, or null when not connected. */
function puzzles_sr_connection(): ?array {
	$o = get_option( PUZZLES_SITE_REPORTS_OPTION );
	return is_array( $o ) && isset( $o['hash'] ) && is_string( $o['hash'] ) ? $o : null;
}

function puzzles_sr_token_valid( $token ): bool {
	$c = puzzles_sr_connection();
	return $c && is_string( $token ) && '' !== $token && hash_equals( $c['hash'], hash( 'sha256', $token ) );
}

/** @return true|WP_Error */
function puzzles_sr_authorized( WP_REST_Request $request ) {
	// One fixed refusal for every cause (no token, wrong token, not connected).
	if ( puzzles_sr_token_valid( $request->get_header( 'X-Puzzles-Reports-Token' ) ) ) {
		return true;
	}
	return new WP_Error( 'puzzles_reports_unauthorized', 'Not authorized.', array( 'status' => 401 ) );
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
					return call_user_func( $callback, $request );
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

// Core's index lists every namespace even when its routes are hidden: drop ours. (A direct request to
// /puzzles-reports/v1 is still answered by core, so the plugin's presence is not fully hidden.)
add_filter(
	'rest_index',
	function ( $response ) {
		if ( ! $response instanceof WP_HTTP_Response ) {
			return $response;
		}
		$d = $response->get_data();
		if ( isset( $d['namespaces'] ) && is_array( $d['namespaces'] ) ) {
			$d['namespaces'] = array_values( array_diff( $d['namespaces'], array( PUZZLES_SITE_REPORTS_NAMESPACE ) ) );
		}
		if ( isset( $d['routes'] ) && is_array( $d['routes'] ) ) {
			foreach ( array_keys( $d['routes'] ) as $r ) {
				if ( puzzles_sr_is_our_route( (string) $r ) ) {
					unset( $d['routes'][ $r ] );
				}
			}
		}
		$response->set_data( $d );
		return $response;
	}
);

// Another plugin or snippet may refuse every unauthenticated REST request (it runs before permission_callback).
// Our routes answer to the token alone: pass only a request for our namespace that carries a valid token; never touch anything else.
add_filter(
	'rest_authentication_errors',
	function ( $result ) {
		$route = isset( $GLOBALS['wp']->query_vars['rest_route'] ) ? (string) $GLOBALS['wp']->query_vars['rest_route'] : '';
		$token = isset( $_SERVER['HTTP_X_PUZZLES_REPORTS_TOKEN'] ) ? $_SERVER['HTTP_X_PUZZLES_REPORTS_TOKEN'] : '';
		if ( puzzles_sr_is_our_route( $route ) && puzzles_sr_token_valid( $token ) ) {
			return true;
		}
		return $result;
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

// ---- Self-update from GitHub Releases ----
// Core runs this only inside its own update check (cron or admin), never on a front-end request, and caches the
// answer in the update_plugins transient, so nothing is cached here. Any failure leaves WordPress' answer untouched.
define( 'PUZZLES_SITE_REPORTS_MANIFEST_URL', 'https://github.com/puzzles-consulting/wp-site-reports/releases/latest/download/manifest.json' );
define( 'PUZZLES_SITE_REPORTS_PACKAGE_PREFIX', 'https://github.com/puzzles-consulting/wp-site-reports/releases/download/' );

/** A filtered string, or the default when a filter returns anything else. */
function puzzles_sr_filtered_string( string $hook, string $default ): string {
	$v = apply_filters( $hook, $default );
	return is_string( $v ) && '' !== $v ? $v : $default;
}

/** Core's `update_plugins_github.com` filter (the header's Update URI host). Only answers for this plugin. */
function puzzles_sr_update_offer( $update, $plugin_data, $plugin_file ) {
	if ( plugin_basename( __FILE__ ) !== $plugin_file || ! is_array( $plugin_data ) || ! isset( $plugin_data['Version'] ) ) {
		return $update;
	}
	$res = wp_remote_get( puzzles_sr_filtered_string( 'puzzles_site_reports_manifest_url', PUZZLES_SITE_REPORTS_MANIFEST_URL ), array( 'timeout' => wp_doing_cron() ? 10 : 3 ) );
	if ( is_wp_error( $res ) || 200 !== (int) wp_remote_retrieve_response_code( $res ) ) {
		return $update;
	}
	$m = json_decode( wp_remote_retrieve_body( $res ), true );
	if ( ! is_array( $m ) || ! isset( $m['version'], $m['package'] ) || ! is_string( $m['version'] ) || ! is_string( $m['package'] ) || ! preg_match( '/^\d+\.\d+\.\d+\z/', $m['version'] ) ) {
		return $update;
	}
	// The package is exactly the asset this release's tag publishes: no other path, no dot segments.
	$prefix = puzzles_sr_filtered_string( 'puzzles_site_reports_package_prefix', PUZZLES_SITE_REPORTS_PACKAGE_PREFIX );
	if ( $m['package'] !== $prefix . 'v' . $m['version'] . '/puzzles-site-reports.zip' || ! version_compare( $m['version'], (string) $plugin_data['Version'], '>' ) ) {
		return $update;
	}
	$opt = function ( $k ) use ( $m ) {
		return isset( $m[ $k ] ) && is_string( $m[ $k ] ) ? $m[ $k ] : '';
	};
	return array(
		'slug'         => 'puzzles-site-reports',
		'version'      => $m['version'],
		'package'      => $m['package'],
		'requires'     => $opt( 'requires' ),
		'requires_php' => $opt( 'requires_php' ),
		'tested'       => $opt( 'tested' ),
		'url'          => 'https://github.com/puzzles-consulting/wp-site-reports',
	);
}
add_filter( 'update_plugins_github.com', 'puzzles_sr_update_offer', 10, 3 );

// Sites install this plugin's updates themselves; every other plugin keeps whatever core decided.
add_filter(
	'auto_update_plugin',
	function ( $update, $item ) {
		return is_object( $item ) && isset( $item->plugin ) && plugin_basename( __FILE__ ) === $item->plugin ? true : $update;
	},
	10,
	2
);

// ---- Admin page: Tools > Site Reports ----
add_action(
	'admin_menu',
	function () {
		add_management_page( 'Puzzles Site Reports', 'Site Reports', 'manage_options', 'puzzles-site-reports', 'puzzles_sr_admin_page' );
	}
);

function puzzles_sr_admin_page(): void {
	if ( ! current_user_can( 'manage_options' ) ) {
		wp_die( 'Not allowed.' );
	}
	$string = '';
	$notice = '';
	if ( 'POST' === $_SERVER['REQUEST_METHOD'] && isset( $_POST['puzzles_sr_action'] ) ) {
		if ( 'connect' === $_POST['puzzles_sr_action'] ) {
			check_admin_referer( 'puzzles_sr_connect' );
			$cur  = puzzles_sr_connection();
			$now  = $cur && isset( $cur['createdAt'] ) ? (string) $cur['createdAt'] : '';
			$seen = isset( $_POST['puzzles_sr_seen'] ) ? sanitize_text_field( wp_unslash( $_POST['puzzles_sr_seen'] ) ) : '';
			if ( $seen !== $now ) { // a reload or a second click: the string already pasted into the portal stays valid
				$notice = 'A connection was already created; create a new one?';
			} else {
				$r = puzzles_sr_create_connection();
				if ( is_wp_error( $r ) ) {
					$notice = $r->get_error_message();
				} else {
					$string = $r;
				}
			}
		} elseif ( 'disconnect' === $_POST['puzzles_sr_action'] ) {
			check_admin_referer( 'puzzles_sr_disconnect' );
			puzzles_sr_disconnect();
		}
	}
	$c = puzzles_sr_connection();
	echo '<div class="wrap"><h1>Puzzles Site Reports</h1>';
	echo '<p>Version ' . esc_html( PUZZLES_SITE_REPORTS_VERSION ) . '</p>';
	echo '<p>' . ( $c ? 'Connected since ' . esc_html( isset( $c['createdAt'] ) ? $c['createdAt'] : '' ) : 'Not connected' ) . '</p>';
	if ( $notice ) {
		echo '<div class="notice notice-warning inline"><p>' . esc_html( $notice ) . '</p></div>';
	}
	if ( $string ) {
		echo '<p><input type="text" id="puzzles-sr-string" class="large-text code" readonly value="' . esc_attr( $string ) . '"> ';
		echo '<button type="button" class="button" onclick="navigator.clipboard.writeText(document.getElementById(\'puzzles-sr-string\').value)">Copy</button></p>';
		echo '<p>This string is shown once. Paste it into the portal\'s Report setup.</p>';
	}
	$seen = $c && isset( $c['createdAt'] ) ? (string) $c['createdAt'] : '';
	$ask  = $c ? ' onsubmit="return confirm(' . esc_attr( wp_json_encode( 'This disconnects the current portal connection.' ) ) . ')"' : '';
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
			if ( $c && isset( $c['createdAt'] ) ) {
				WP_CLI::line( 'createdAt: ' . $c['createdAt'] );
			}
		}
	}
	WP_CLI::add_command( 'puzzles-site-reports', 'Puzzles_SR_CLI' );
}
