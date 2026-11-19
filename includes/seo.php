<?php
/**
 * GET /seo. Reads Rank Math's own post meta; nothing is derived or resolved, and it never branches on the current user.
 *
 * Memory: page-builder sites keep megabytes of meta (and long content) per post. Only Rank Math's five keys are read,
 * in chunks, and each post leaves the object cache as soon as its item is built; a fatal out-of-memory cannot be caught.
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

const PSR_SEO_LIMIT = 500;
const PSR_SEO_CHUNK = 100;
const PSR_SEO_KEYS  = array( 'rank_math_focus_keyword', 'rank_math_seo_score', 'rank_math_title', 'rank_math_description', 'rank_math_robots' );

/** true / false when the post sets its own Rank Math robots, null when it follows Rank Math's defaults. */
function psr_noindex( $raw ): ?bool {
	$r = is_string( $raw ) ? maybe_unserialize( $raw ) : $raw; // an array; a serialized string is read too
	if ( is_string( $r ) && '' !== $r ) {
		$r = array( $r );
	}
	return is_array( $r ) && $r ? in_array( 'noindex', $r, true ) : null;
}

/** Rank Math's own meta for some posts: [ post_id => [ meta_key => raw value ] ], first row of a key wins (as get_post_meta does). */
function psr_seo_meta( array $ids ): array {
	global $wpdb;
	$out  = array();
	$rows = $wpdb->get_results(
		$wpdb->prepare(
			'SELECT post_id, meta_key, meta_value FROM ' . $wpdb->postmeta
			. ' WHERE post_id IN (' . implode( ',', array_fill( 0, count( $ids ), '%d' ) ) . ')'
			. ' AND meta_key IN (' . implode( ',', array_fill( 0, count( PSR_SEO_KEYS ), '%s' ) ) . ') ORDER BY meta_id',
			array_merge( $ids, PSR_SEO_KEYS )
		)
	);
	foreach ( (array) $rows as $r ) {
		if ( ! isset( $out[ (int) $r->post_id ][ $r->meta_key ] ) ) {
			$out[ (int) $r->post_id ][ $r->meta_key ] = $r->meta_value;
		}
	}
	return $out;
}

function psr_seo(): array {
	require_once ABSPATH . 'wp-admin/includes/plugin.php'; // REST requests do not load it

	if ( ! class_exists( 'RankMath' ) || ! psr_plugin_active( 'seo-by-rank-math/rank-math.php' ) ) {
		return array( 'plugin' => null, 'types' => (object) array(), 'items' => array() );
	}

	$types = array( 'page', 'post' );
	if ( post_type_exists( 'product' ) ) {
		$types[] = 'product';
	}

	$summary = array();
	$items   = array();
	foreach ( $types as $type ) {
		// ids only, one more than the cap to know whether the list was cut
		$ids = get_posts(
			array(
				'post_type'        => $type,
				'post_status'      => 'publish',
				'numberposts'      => PSR_SEO_LIMIT + 1,
				'orderby'          => array( 'date' => 'DESC', 'ID' => 'DESC' ),
				'fields'           => 'ids',
				'suppress_filters' => true,
			)
		);
		$truncated        = count( $ids ) > PSR_SEO_LIMIT;
		$ids              = array_slice( array_map( 'intval', $ids ), 0, PSR_SEO_LIMIT );
		$summary[ $type ] = array( 'items' => count( $ids ), 'truncated' => $truncated );

		foreach ( array_chunk( $ids, PSR_SEO_CHUNK ) as $chunk ) {
			$meta = psr_seo_meta( $chunk );
			_prime_post_caches( $chunk, true, false ); // the chunk's posts in one query, with their terms (a %category% permalink), without any meta
			foreach ( $chunk as $id ) {
				$m       = isset( $meta[ $id ] ) ? $meta[ $id ] : array();
				$kw      = psr_plain( isset( $m['rank_math_focus_keyword'] ) ? $m['rank_math_focus_keyword'] : null );
				$link    = get_permalink( $id );
				$score   = isset( $m['rank_math_seo_score'] ) ? trim( (string) $m['rank_math_seo_score'] ) : '';
				$items[] = array(
					'id'              => $id,
					'type'            => $type,
					'url'             => is_string( $link ) && '' !== $link ? $link : null,
					'title'           => (string) psr_plain( get_post_field( 'post_title', $id, 'raw' ) ),
					'focusKeywords'   => null === $kw ? array() : array_values( array_filter( array_map( 'trim', explode( ',', $kw ) ), 'strlen' ) ),
					'seoScore'        => is_numeric( $score ) ? (int) $score : null,
					'metaTitle'       => psr_plain( isset( $m['rank_math_title'] ) ? $m['rank_math_title'] : null ),
					'metaDescription' => psr_plain( isset( $m['rank_math_description'] ) ? $m['rank_math_description'] : null ),
					'noindex'         => psr_noindex( isset( $m['rank_math_robots'] ) ? $m['rank_math_robots'] : null ),
				);
				// A page builder's content can be megabytes: drop the post from the object cache now.
				// (Not clean_post_cache(): for pages it runs one extra query per post to find children.)
				wp_cache_delete( $id, 'posts' );
				wp_cache_delete( $id, 'post_meta' ); // a post_link filter may have called get_post_meta, which loads every row
			}
		}
	}

	return array(
		'plugin' => array( 'name' => 'rank_math', 'version' => defined( 'RANK_MATH_VERSION' ) ? (string) RANK_MATH_VERSION : null ),
		'types'  => $summary,
		'items'  => $items,
	);
}
