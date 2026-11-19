<?php
/**
 * GET /status. Reads what WordPress already knows; never triggers an update check or a Wordfence scan,
 * and never branches on the current user (a cookie-logged-in browser can still be the current user here).
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/** ISO 8601 UTC ("Z") of a unix time, or null when there is none. */
function puzzles_sr_iso( $ts ): ?string {
	return is_numeric( $ts ) && $ts > 0 ? gmdate( 'Y-m-d\TH:i:s\Z', (int) $ts ) : null;
}

/**
 * The oldest last_checked of the three update checks, or null until each has succeeded once: a failed check still
 * stamps last_checked but stores no data (core: no `updates`; plugins and themes: no `checked`). After a later failure
 * the time is that of the failed check and the data is older.
 */
function puzzles_sr_updates_checked_at( $core, $plugins, $themes ): ?string {
	if ( empty( $core->updates ) || empty( $plugins->checked ) || empty( $themes->checked )
		|| empty( $core->last_checked ) || empty( $plugins->last_checked ) || empty( $themes->last_checked ) ) {
		return null;
	}
	return puzzles_sr_iso( min( (int) $core->last_checked, (int) $plugins->last_checked, (int) $themes->last_checked ) );
}

/**
 * $s without server paths: the content dir becomes "wp-content", the install root and its parent disappear (a root
 * counts only at a path boundary: followed by a separator or where the path ends). Then any other absolute path (Unix,
 * or Windows with a drive or a UNC prefix) not preceded by a letter or a digit goes, and every URL goes whole except an
 * http(s) one, which keeps its scheme and host (group 1) and loses a path only where it starts after a non-alphanumeric.
 */
function puzzles_sr_scrub_paths( string $s ): string {
	$s = (string) preg_replace( '~' . preg_quote( WP_CONTENT_DIR, '~' ) . '(?=[/\\\\\s"\'<>:;,)\]]|\z)~', 'wp-content', $s );
	foreach ( array( untrailingslashit( ABSPATH ), untrailingslashit( (string) realpath( ABSPATH ) ), dirname( ABSPATH ) ) as $root ) {
		if ( strlen( $root ) > 1 ) { // never "/" or "": that would eat every slash
			$s = (string) preg_replace( '~' . preg_quote( $root, '~' ) . '(?:[/\\\\]|(?=[\s"\'<>:;,)\]]|\z))~', '', $s );
		}
	}
	return (string) preg_replace( '~((?i:https?)://[^\s"\'<>/\\\\]*)|(?<![A-Za-z0-9])(?:[A-Za-z][A-Za-z0-9+.-]*:(?=//))?(?:[A-Za-z]:)?[\\\\/][^\s"\'<>]+~', '$1', $s );
}

/**
 * A Wordfence shortMsg for the portal: plain text without server paths, cut to 300 characters. Tags become a space
 * first, so a path right after one ("Found<code>/etc/passwd") still starts a word and is removed.
 */
function puzzles_sr_short_msg( $v ): string {
	$s = puzzles_sr_plain( is_scalar( $v ) ? preg_replace( '/\s*<[^>]*>\s*/', ' ', (string) $v ) : null );
	return mb_substr( trim( puzzles_sr_scrub_paths( (string) $s ) ), 0, 300 );
}

/** Wordfence's own open issues, ignored count and last scan; null when it is not installed, or active but unreadable. Never starts a scan. */
function puzzles_sr_wordfence( array $plugins ): ?array {
	$file = 'wordfence/wordfence.php';
	if ( ! isset( $plugins[ $file ] ) ) {
		return null;
	}
	$out = array(
		'version'    => (string) $plugins[ $file ]['Version'],
		'active'     => is_plugin_active( $file ),
		'lastScanAt' => null,
		'issues'     => array(),
		'ignored'    => 0,
	);
	if ( ! $out['active'] ) {
		return $out; // its classes are not loaded: nothing to read
	}
	// Active but unreadable (a Wordfence change) is null, never "no issues". The filter is for tests: it can only force that
	// path (null), never make anything else readable.
	if ( ! class_exists( 'wfIssues' ) || ! class_exists( 'wfScanner' ) || ! apply_filters( 'puzzles_sr_wordfence_reader_ok', true ) ) {
		return null;
	}
	// Wordfence's public wfIssues / wfScanner methods instead of its tables. getIssues() hydrates each issue (including its
	// per-issue `data`): only four fields leave here. Its own query is LIMIT 200.
	try {
		$issues = new wfIssues();
		$found  = $issues->getIssues( 0, 200, 0, 0 );
		$counts = $issues->getIssueCounts();
		if ( ! is_array( $found['new'] ?? null ) || ! is_array( $counts ) ) {
			return null;
		}
		$out['lastScanAt'] = puzzles_sr_iso( wfScanner::shared()->lastScanTime() );
		foreach ( $found['new'] as $i ) {
			$out['issues'][] = array(
				'type'        => (string) $i['type'],
				'severity'    => (int) $i['severity'], // Wordfence's own: 100 critical, 75 high, 50 medium, 25 low
				'shortMsg'    => puzzles_sr_short_msg( $i['shortMsg'] ),
				'detectedAt'  => puzzles_sr_iso( $i['time'] ?? null ), // the last full scan that stored the issue
			);
		}
		$out['ignored'] = (int) ( $counts['ignoreP'] ?? 0 ) + (int) ( $counts['ignoreC'] ?? 0 );
	} catch ( Throwable $e ) {
		return null;
	}
	return $out;
}

function puzzles_sr_status(): array {
	$core_t      = get_site_transient( 'update_core' );
	$plugins_t    = get_site_transient( 'update_plugins' );
	$themes_t     = get_site_transient( 'update_themes' );
	$plugin_offer = $plugins_t->response ?? array();
	$theme_offer  = $themes_t->response ?? array();

	$core_update = null;
	foreach ( is_array( $core_t->updates ?? null ) ? $core_t->updates : array() as $offer ) { // the first real upgrade offer, wherever it sits in the list
		$version = is_object( $offer ) && 'upgrade' === ( $offer->response ?? null ) ? ( $offer->current ?? $offer->version ?? null ) : null;
		if ( is_string( $version ) && '' !== $version ) {
			$core_update = $version;
			break;
		}
	}

	$all  = get_plugins();
	$auto = (array) get_site_option( 'auto_update_plugins', array() );
	$list = array();
	foreach ( $all as $file => $p ) {
		$offer  = $plugin_offer[ $file ]->new_version ?? null;
		$list[] = array(
			'file'       => (string) $file,
			'name'       => (string) $p['Name'],
			'version'    => (string) $p['Version'],
			'active'     => is_plugin_active( $file ), // network-active counts
			'update'     => null === $offer ? null : (string) $offer,
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
		$stylesheet = (string) $stylesheet; // a numeric folder name is an integer array key
		$entry   = (array) ( $theme_offer[ $stylesheet ] ?? array() ); // core stores arrays, a third-party updater may store objects
		$offer    = is_scalar( $entry['new_version'] ?? null ) ? (string) $entry['new_version'] : null;
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
			'updatesCheckedAt' => puzzles_sr_updates_checked_at( $core_t, $plugins_t, $themes_t ),
		),
		'php'        => array( 'version' => PHP_VERSION ),
		'plugins'    => $list,
		'mustUse'    => $mu,
		'themes'     => $themes,
		'wordfence'  => puzzles_sr_wordfence( $all ),
		'comments'   => array( 'defaultStatus' => (string) get_option( 'default_comment_status' ) ),
	);
}
