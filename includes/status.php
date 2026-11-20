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

/** A site transient as stored, past the site_transient_* filters (contract: updatesCheckedAt). */
function puzzles_sr_raw_transient( string $name ) {
	return wp_using_ext_object_cache() ? wp_cache_get( $name, 'site-transient' ) : get_site_option( '_site_transient_' . $name );
}

/** The oldest `puzzles_sr_checked` of the named transients as stored, or null (contract: updatesCheckedAt). */
function puzzles_sr_checked_at( string ...$names ): ?string {
	$times = array();
	foreach ( $names as $n ) {
		$t = puzzles_sr_raw_transient( $n );
		if ( ! is_object( $t ) || empty( $t->puzzles_sr_checked ) ) {
			return null;
		}
		$times[] = (int) $t->puzzles_sr_checked;
	}
	return puzzles_sr_iso( min( $times ) );
}

/**
 * The offered versions in an update transient: plugins and themes [ file or stylesheet => new_version ], core the
 * list of versions it offers as upgrades, in its order. Strings only.
 */
function puzzles_sr_offer_versions( string $type, $t ): array {
	$out = array();
	if ( 'core' === $type ) {
		foreach ( (array) ( $t->updates ?? array() ) as $o ) {
			$v = is_object( $o ) && 'upgrade' === ( $o->response ?? null ) ? ( $o->current ?? $o->version ?? null ) : null;
			if ( is_string( $v ) && '' !== $v ) {
				$out[] = $v;
			}
		}
		return $out;
	}
	foreach ( (array) ( $t->response ?? array() ) as $key => $o ) {
		$o = (array) $o; // core stores plugins' as objects and themes' as arrays; a third-party updater may do either
		if ( is_scalar( $o['new_version'] ?? null ) ) {
			$out[ $key ] = (string) $o['new_version'];
		}
	}
	return $out;
}

/** Whether version $a is above $b, a leading "v" or "V" on either left out (contract). */
function puzzles_sr_above( string $a, string $b ): bool {
	return version_compare( preg_replace( '/^v/i', '', $a ), preg_replace( '/^v/i', '', $b ), '>' );
}

/** An offered version, as given, only when it is above the installed one (contract). */
function puzzles_sr_newer( ?string $offer, string $installed ): ?string {
	return null !== $offer && puzzles_sr_above( $offer, $installed ) ? $offer : null;
}

/**
 * Offers: the snapshot taken when core's check was last answered and the filtered read, the higher per item (a filter
 * can add or raise an offer, never hide one); without a snapshot, the filtered read alone (contract).
 */
function puzzles_sr_offers( string $type ): array {
	$raw  = puzzles_sr_raw_transient( 'update_' . $type );
	$out  = ! empty( $raw->puzzles_sr_checked ) && is_array( $raw->puzzles_sr_offers ?? null ) ? $raw->puzzles_sr_offers : array();
	$read = puzzles_sr_offer_versions( $type, get_site_transient( 'update_' . $type ) );
	if ( 'core' === $type ) {
		return array_merge( $out, $read );
	}
	foreach ( $read as $key => $v ) {
		if ( ! isset( $out[ $key ] ) || puzzles_sr_above( $v, (string) $out[ $key ] ) ) {
			$out[ $key ] = $v;
		}
	}
	return $out;
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

// Wordfence builds these issues' shortMsg from a user_login (wfScanEngine): a fixed text leaves instead.
const PUZZLES_SR_WF_GENERIC = array(
	'easyPassword'         => 'A user has an easy password.',
	'suspiciousAdminUsers' => 'An admin user was created outside WordPress or has a suspicious username.',
);

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
				'shortMsg'    => PUZZLES_SR_WF_GENERIC[ (string) $i['type'] ] ?? puzzles_sr_short_msg( $i['shortMsg'] ),
				'detectedAt'  => puzzles_sr_iso( $i['time'] ?? null ), // when Wordfence last re-stored the issue (contract)
			);
		}
		$out['ignored'] = (int) ( $counts['ignoreP'] ?? 0 ) + (int) ( $counts['ignoreC'] ?? 0 );
	} catch ( Throwable $e ) {
		return null;
	}
	return $out;
}

function puzzles_sr_status(): array {
	$plugin_offer = puzzles_sr_offers( 'plugins' );
	$theme_offer  = puzzles_sr_offers( 'themes' );
	$wp_version   = get_bloginfo( 'version' );
	$core_update  = null; // the highest upgrade offered above the running version, snapshot or read
	foreach ( puzzles_sr_offers( 'core' ) as $v ) {
		if ( version_compare( $v, $core_update ?? $wp_version, '>' ) ) {
			$core_update = $v;
		}
	}

	$all    = get_plugins();
	$auto   = (array) get_site_option( 'auto_update_plugins', array() );
	$auto[] = plugin_basename( dirname( __DIR__ ) . '/puzzles-site-reports.php' ); // it always installs its own signed updates
	$list   = array();
	foreach ( $all as $file => $p ) {
		$list[] = array(
			'file'       => (string) $file,
			'name'       => (string) $p['Name'],
			'version'    => (string) $p['Version'],
			'active'     => is_plugin_active( $file ), // network-active counts
			'update'     => puzzles_sr_newer( $plugin_offer[ $file ] ?? null, (string) $p['Version'] ),
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
		$template   = (string) $t->get_template(); // older WordPress gives a numeric folder name as an integer here too
		$themes[] = array(
			'stylesheet' => $stylesheet,
			'name'       => (string) $t->get( 'Name' ),
			'version'    => (string) $t->get( 'Version' ),
			'active'     => $stylesheet === $active,
			'parent'     => $template !== $stylesheet ? $template : null,
			'update'     => puzzles_sr_newer( $theme_offer[ $stylesheet ] ?? null, (string) $t->get( 'Version' ) ),
		);
	}

	return array(
		'companion'        => array( 'version' => PUZZLES_SITE_REPORTS_VERSION ),
		'wordpress'        => array(
			'version'          => $wp_version,
			'update'           => $core_update,
			'updatesCheckedAt' => puzzles_sr_checked_at( 'update_core' ),
		),
		'php'              => array( 'version' => PHP_VERSION ),
		'plugins'          => $list,
		'mustUse'          => $mu,
		'themes'           => $themes,
		'updatesCheckedAt' => puzzles_sr_checked_at( 'update_plugins', 'update_themes' ),
		'wordfence'        => puzzles_sr_wordfence( $all ),
		'comments'         => array( 'defaultStatus' => (string) get_option( 'default_comment_status' ) ),
	);
}
