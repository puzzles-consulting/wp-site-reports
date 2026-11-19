<?php
/**
 * GET /status. Reads what WordPress already knows; never triggers an update check or a Wordfence scan,
 * and never branches on the current user (a cookie-logged-in browser can still be the current user here).
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/** ISO 8601 UTC ("Z") of a unix time, or null when there is none. */
function psr_iso( $ts ): ?string {
	return is_numeric( $ts ) && $ts > 0 ? gmdate( 'Y-m-d\TH:i:s\Z', (int) $ts ) : null;
}

/** The oldest last_checked of the three update transients; null if any never ran. */
function psr_updates_checked_at( array $transients ): ?string {
	$oldest = null;
	foreach ( $transients as $t ) {
		if ( ! is_object( $t ) || empty( $t->last_checked ) ) {
			return null;
		}
		$oldest = null === $oldest ? (int) $t->last_checked : min( $oldest, (int) $t->last_checked );
	}
	return psr_iso( $oldest );
}

/** Wordfence's own open issues, ignored count and last scan; null when it is not installed. Never starts a scan. */
function psr_wordfence( array $plugins ): ?array {
	$file = 'wordfence/wordfence.php';
	if ( ! isset( $plugins[ $file ] ) ) {
		return null;
	}
	$out = array(
		'version'    => (string) $plugins[ $file ]['Version'],
		'active'     => psr_plugin_active( $file ),
		'lastScanAt' => null,
		'issues'     => array(),
		'ignored'    => 0,
	);
	// Wordfence's classes exist only while it is active and loaded; its public wfIssues / wfScanner methods
	// are used instead of its tables. getIssues() hydrates each issue (including its per-issue `data`): only four fields leave here.
	if ( $out['active'] && class_exists( 'wfIssues' ) && class_exists( 'wfScanner' ) ) {
		try {
			$out['lastScanAt'] = psr_iso( wfScanner::shared()->lastScanTime() );
			$issues            = new wfIssues();
			$found             = $issues->getIssues( 0, 200, 0, 0 );
			foreach ( isset( $found['new'] ) ? (array) $found['new'] : array() as $i ) {
				if ( count( $out['issues'] ) >= 200 ) {
					break;
				}
				$out['issues'][] = array(
					'type'        => (string) $i['type'],
					'severity'    => (int) $i['severity'], // Wordfence's own: 100 critical, 75 high, 50 medium, 25 low
					'shortMsg'    => mb_substr( (string) $i['shortMsg'], 0, 300 ),
					'firstSeenAt' => psr_iso( $i['time'] ),
				);
			}
			$counts         = $issues->getIssueCounts();
			$out['ignored'] = (int) ( isset( $counts['ignoreP'] ) ? $counts['ignoreP'] : 0 ) + (int) ( isset( $counts['ignoreC'] ) ? $counts['ignoreC'] : 0 );
		} catch ( Throwable $e ) {
			return null;
		}
	}
	return $out;
}

function psr_plugin_active( string $file ): bool {
	return is_plugin_active( $file ) || is_plugin_active_for_network( $file );
}

function psr_status(): array {
	require_once ABSPATH . 'wp-admin/includes/plugin.php'; // REST requests do not load it

	$core_t    = get_site_transient( 'update_core' );
	$plugins_t = get_site_transient( 'update_plugins' );
	$themes_t  = get_site_transient( 'update_themes' );

	$core_update = null;
	if ( is_object( $core_t ) && ! empty( $core_t->updates ) && is_array( $core_t->updates ) ) {
		$first = $core_t->updates[0];
		if ( is_object( $first ) && isset( $first->response ) && 'upgrade' === $first->response ) {
			$core_update = (string) ( isset( $first->current ) ? $first->current : $first->version );
		}
	}

	$all  = get_plugins();
	$auto = (array) get_site_option( 'auto_update_plugins', array() );
	$list = array();
	foreach ( $all as $file => $p ) {
		$offer  = is_object( $plugins_t ) && isset( $plugins_t->response[ $file ]->new_version ) ? (string) $plugins_t->response[ $file ]->new_version : null;
		$list[] = array(
			'file'       => (string) $file,
			'name'       => (string) $p['Name'],
			'version'    => (string) $p['Version'],
			'active'     => psr_plugin_active( $file ),
			'update'     => $offer,
			'autoUpdate' => in_array( $file, $auto, true ),
		);
	}

	$mu = array();
	foreach ( get_mu_plugins() as $file => $p ) {
		$mu[] = array(
			'file'    => (string) $file,
			'name'    => (string) $p['Name'],
			'version' => (string) $p['Version'],
		);
	}

	$themes = array();
	$active = get_stylesheet();
	foreach ( wp_get_themes() as $stylesheet => $t ) {
		$offer    = is_object( $themes_t ) && isset( $themes_t->response[ $stylesheet ]['new_version'] ) ? (string) $themes_t->response[ $stylesheet ]['new_version'] : null;
		$template = $t->get_template();
		$themes[] = array(
			'stylesheet' => (string) $stylesheet,
			'name'       => (string) $t->get( 'Name' ),
			'version'    => (string) $t->get( 'Version' ),
			'active'     => (string) $stylesheet === $active,
			'parent'     => $template !== $stylesheet ? (string) $template : null,
			'update'     => $offer,
		);
	}

	return array(
		'companion'  => array( 'version' => PUZZLES_SITE_REPORTS_VERSION ),
		'wordpress'  => array(
			'version'          => get_bloginfo( 'version' ),
			'update'           => $core_update,
			'updatesCheckedAt' => psr_updates_checked_at( array( $core_t, $plugins_t, $themes_t ) ),
		),
		'php'        => array( 'version' => PHP_VERSION ),
		'plugins'    => $list,
		'mustUse'    => $mu,
		'themes'     => $themes,
		'wordfence'  => psr_wordfence( $all ),
		'comments'   => array( 'defaultStatus' => (string) get_option( 'default_comment_status' ) ),
	);
}
