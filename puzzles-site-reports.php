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

define( 'PSR_OPTION', 'puzzles_site_reports_token' );
define( 'PSR_NAMESPACE', 'puzzles-reports/v1' );

/** Rotates the token and returns the connection string. Only the SHA-256 hash is stored. */
function psr_create_connection() {
	$token = bin2hex( random_bytes( 32 ) );
	update_option(
		PSR_OPTION,
		array(
			'hash'      => hash( 'sha256', $token ),
			'createdAt' => gmdate( 'c' ),
		),
		false
	);
	$payload = wp_json_encode( array( 'site' => home_url(), 'token' => $token ), JSON_UNESCAPED_SLASHES );
	return 'pzr1.' . rtrim( strtr( base64_encode( $payload ), '+/', '-_' ), '=' );
}

function psr_disconnect() {
	delete_option( PSR_OPTION );
}

/** The stored { hash, createdAt }, or null when not connected. */
function psr_connection() {
	$o = get_option( PSR_OPTION );
	return is_array( $o ) && isset( $o['hash'] ) && is_string( $o['hash'] ) ? $o : null;
}

function psr_authorized( $request ) {
	$c     = psr_connection();
	$token = $request->get_header( 'X-Puzzles-Reports-Token' );
	// One fixed refusal for every cause (no token, wrong token, not connected).
	if ( $c && is_string( $token ) && '' !== $token && hash_equals( $c['hash'], hash( 'sha256', $token ) ) ) {
		return true;
	}
	return new WP_Error( 'puzzles_reports_unauthorized', 'Not authorized.', array( 'status' => 401 ) );
}

function psr_register_route( $route, $callback ) {
	register_rest_route(
		PSR_NAMESPACE,
		$route,
		array(
			'methods'             => 'GET',
			'show_in_index'       => false,
			'permission_callback' => 'psr_authorized',
			'callback'            => function ( $request ) use ( $callback ) {
				try {
					return call_user_func( $callback, $request );
				} catch ( Throwable $e ) {
					return new WP_Error( 'puzzles_reports_failed', 'The report could not be built.', array( 'status' => 500 ) );
				}
			},
		)
	);
}

add_filter(
	'rest_post_dispatch',
	function ( $result, $server, $request ) {
		if ( 0 === strpos( $request->get_route(), '/' . PSR_NAMESPACE ) ) {
			$result->header( 'Cache-Control', 'no-store' );
		}
		return $result;
	},
	10,
	3
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

function psr_admin_page() {
	if ( ! current_user_can( 'manage_options' ) ) {
		wp_die( 'Not allowed.' );
	}
	$string = '';
	if ( 'POST' === $_SERVER['REQUEST_METHOD'] && isset( $_POST['psr_action'] ) ) {
		if ( 'connect' === $_POST['psr_action'] ) {
			check_admin_referer( 'psr_connect' );
			$string = psr_create_connection();
		} elseif ( 'disconnect' === $_POST['psr_action'] ) {
			check_admin_referer( 'psr_disconnect' );
			psr_disconnect();
		}
	}
	$c = psr_connection();
	echo '<div class="wrap"><h1>Puzzles Site Reports</h1>';
	echo '<p>Version ' . esc_html( PUZZLES_SITE_REPORTS_VERSION ) . '</p>';
	echo '<p>' . ( $c ? 'Connected since ' . esc_html( isset( $c['createdAt'] ) ? $c['createdAt'] : '' ) : 'Not connected' ) . '</p>';
	if ( $string ) {
		echo '<p><input type="text" id="psr-string" class="large-text code" readonly value="' . esc_attr( $string ) . '"> ';
		echo '<button type="button" class="button" onclick="navigator.clipboard.writeText(document.getElementById(\'psr-string\').value)">Copy</button></p>';
		echo '<p>This string is shown once. Paste it into the portal\'s Report setup.</p>';
	}
	echo '<form method="post">';
	wp_nonce_field( 'psr_connect' );
	echo '<input type="hidden" name="psr_action" value="connect"><button class="button button-primary">Create connection</button></form>';
	if ( $c ) {
		echo '<form method="post" style="margin-top:8px">';
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
			if ( ! empty( $assoc['porcelain'] ) ) {
				WP_CLI::line( $s );
				return;
			}
			WP_CLI::line( $s );
			WP_CLI::warning( 'Shown once. Paste it into the portal\'s Report setup.' );
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
