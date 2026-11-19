<?php
/**
 * Plugin Name:       Puzzles Site Reports
 * Plugin URI:        https://github.com/puzzles-consulting/wp-site-reports
 * Description:       Read-only status and SEO reports of this WordPress site for Puzzles' client reports.
 * Version:           0.0.0-dev
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

define( 'PUZZLES_SITE_REPORTS_VERSION', '0.0.0-dev' );
define( 'PUZZLES_SITE_REPORTS_OPTION', 'puzzles_site_reports_token' );
define( 'PUZZLES_SITE_REPORTS_NAMESPACE', 'puzzles-reports/v1' );

/** Rotates the token. Returns the connection string, or a WP_Error if it could not be stored. Only the SHA-256 hash is stored. */
function psr_create_connection() {
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

function psr_disconnect(): void {
	delete_option( PUZZLES_SITE_REPORTS_OPTION );
}

/** The stored { hash, createdAt }, or null when not connected. */
function psr_connection(): ?array {
	$o = get_option( PUZZLES_SITE_REPORTS_OPTION );
	return is_array( $o ) && isset( $o['hash'] ) && is_string( $o['hash'] ) ? $o : null;
}

function psr_token_valid( $token ): bool {
	$c = psr_connection();
	return $c && is_string( $token ) && '' !== $token && hash_equals( $c['hash'], hash( 'sha256', $token ) );
}

/** @return true|WP_Error */
function psr_authorized( WP_REST_Request $request ) {
	// One fixed refusal for every cause (no token, wrong token, not connected).
	if ( psr_token_valid( $request->get_header( 'X-Puzzles-Reports-Token' ) ) ) {
		return true;
	}
	return new WP_Error( 'puzzles_reports_unauthorized', 'Not authorized.', array( 'status' => 401 ) );
}

function psr_register_route( string $route, callable $callback ): void {
	register_rest_route(
		PUZZLES_SITE_REPORTS_NAMESPACE,
		$route,
		array(
			'methods'             => 'GET',
			'show_in_index'       => false,
			'permission_callback' => 'psr_authorized',
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
		if ( $result instanceof WP_HTTP_Response && 0 === strpos( $request->get_route(), '/' . PUZZLES_SITE_REPORTS_NAMESPACE ) ) {
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
				if ( 0 === strpos( $r, '/puzzles-reports' ) ) {
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
		$route = '/' . trim( $route, '/' );
		$ns    = '/' . PUZZLES_SITE_REPORTS_NAMESPACE;
		$token = isset( $_SERVER['HTTP_X_PUZZLES_REPORTS_TOKEN'] ) ? $_SERVER['HTTP_X_PUZZLES_REPORTS_TOKEN'] : '';
		if ( ( $route === $ns || 0 === strpos( $route, $ns . '/' ) ) && psr_token_valid( $token ) ) {
			return true;
		}
		return $result;
	},
	999
);

add_action(
	'rest_api_init',
	function () {
		// Until the status report lands this answers {}.
		psr_register_route( '/status', function () {
			return (object) array();
		} );
	}
);

// ---- Admin page: Tools > Site Reports ----
add_action(
	'admin_menu',
	function () {
		add_management_page( 'Puzzles Site Reports', 'Site Reports', 'manage_options', 'puzzles-site-reports', 'psr_admin_page' );
	}
);

function psr_admin_page(): void {
	if ( ! current_user_can( 'manage_options' ) ) {
		wp_die( 'Not allowed.' );
	}
	$string = '';
	$notice = '';
	if ( 'POST' === $_SERVER['REQUEST_METHOD'] && isset( $_POST['psr_action'] ) ) {
		if ( 'connect' === $_POST['psr_action'] ) {
			check_admin_referer( 'psr_connect' );
			$cur  = psr_connection();
			$now  = $cur && isset( $cur['createdAt'] ) ? (string) $cur['createdAt'] : '';
			$seen = isset( $_POST['psr_seen'] ) ? sanitize_text_field( wp_unslash( $_POST['psr_seen'] ) ) : '';
			if ( $seen !== $now ) { // a reload or a second click: the string already pasted into the portal stays valid
				$notice = 'A connection was already created; create a new one?';
			} else {
				$r = psr_create_connection();
				if ( is_wp_error( $r ) ) {
					$notice = $r->get_error_message();
				} else {
					$string = $r;
				}
			}
		} elseif ( 'disconnect' === $_POST['psr_action'] ) {
			check_admin_referer( 'psr_disconnect' );
			psr_disconnect();
		}
	}
	$c = psr_connection();
	echo '<div class="wrap"><h1>Puzzles Site Reports</h1>';
	echo '<p>Version ' . esc_html( PUZZLES_SITE_REPORTS_VERSION ) . '</p>';
	echo '<p>' . ( $c ? 'Connected since ' . esc_html( isset( $c['createdAt'] ) ? $c['createdAt'] : '' ) : 'Not connected' ) . '</p>';
	if ( $notice ) {
		echo '<div class="notice notice-warning inline"><p>' . esc_html( $notice ) . '</p></div>';
	}
	if ( $string ) {
		echo '<p><input type="text" id="psr-string" class="large-text code" readonly value="' . esc_attr( $string ) . '"> ';
		echo '<button type="button" class="button" onclick="navigator.clipboard.writeText(document.getElementById(\'psr-string\').value)">Copy</button></p>';
		echo '<p>This string is shown once. Paste it into the portal\'s Report setup.</p>';
	}
	$seen = $c && isset( $c['createdAt'] ) ? (string) $c['createdAt'] : '';
	$ask  = $c ? ' onsubmit="return confirm(' . esc_attr( wp_json_encode( 'This disconnects the current portal connection.' ) ) . ')"' : '';
	echo '<form method="post"' . $ask . '>';
	wp_nonce_field( 'psr_connect' );
	echo '<input type="hidden" name="psr_action" value="connect"><input type="hidden" name="psr_seen" value="' . esc_attr( $seen ) . '"><button class="button button-primary">Create connection</button></form>';
	if ( $c ) {
		echo '<form method="post" style="margin-top:8px" onsubmit="return confirm(' . esc_attr( wp_json_encode( 'Disconnect this site from the portal?' ) ) . ')">';
		wp_nonce_field( 'psr_disconnect' );
		echo '<input type="hidden" name="psr_action" value="disconnect"><button class="button">Disconnect</button></form>';
	}
	echo '</div>';
}

// ---- WP-CLI ----
if ( defined( 'WP_CLI' ) && WP_CLI ) {
	class PSR_CLI {
		/**
		 * Creates a connection (rotating any previous one) and prints the string.
		 *
		 * [--porcelain]
		 * : Print only the connection string.
		 */
		public function connect( $args, $assoc ) {
			$s = psr_create_connection();
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
			$c = psr_connection();
			WP_CLI::line( 'version: ' . PUZZLES_SITE_REPORTS_VERSION );
			WP_CLI::line( 'connected: ' . ( $c ? 'yes' : 'no' ) );
			if ( $c && isset( $c['createdAt'] ) ) {
				WP_CLI::line( 'createdAt: ' . $c['createdAt'] );
			}
		}
	}
	WP_CLI::add_command( 'puzzles-site-reports', 'PSR_CLI' );
}
