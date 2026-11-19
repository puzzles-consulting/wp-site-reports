<?php
/**
 * GET /seo. Reads Rank Math's own post meta; nothing is derived or resolved, and it never branches on the current user.
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

const PSR_SEO_LIMIT = 500;

/** A meta value as a trimmed string, or null when it is empty. */
function psr_meta_text( int $id, string $key ): ?string {
	$v = get_post_meta( $id, $key, true );
	$v = is_scalar( $v ) ? trim( (string) $v ) : '';
	return '' === $v ? null : $v;
}

/** true / false when the post sets its own Rank Math robots, null when it follows Rank Math's defaults. */
function psr_noindex( int $id ): ?bool {
	$r = maybe_unserialize( get_post_meta( $id, 'rank_math_robots', true ) ); // an array; a serialized string is read too
	if ( is_string( $r ) && '' !== $r ) {
		$r = array( $r );
	}
	return is_array( $r ) && $r ? in_array( 'noindex', $r, true ) : null;
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
				'orderby'          => 'date',
				'order'            => 'DESC',
				'fields'           => 'ids',
				'suppress_filters' => true,
			)
		);
		$truncated = count( $ids ) > PSR_SEO_LIMIT;
		$ids       = array_slice( $ids, 0, PSR_SEO_LIMIT );
		if ( $ids ) {
			update_meta_cache( 'post', $ids );
			_prime_post_caches( $ids, false, false ); // one query for the posts, so title and url below cost none
		}
		$summary[ $type ] = array( 'items' => count( $ids ), 'truncated' => $truncated );

		foreach ( $ids as $id ) {
			$id    = (int) $id;
			$kw    = psr_meta_text( $id, 'rank_math_focus_keyword' );
			$score = psr_meta_text( $id, 'rank_math_seo_score' );
			$items[] = array(
				'id'              => $id,
				'type'            => $type,
				'url'             => get_permalink( $id ),
				'title'           => html_entity_decode( get_the_title( $id ), ENT_QUOTES, 'UTF-8' ),
				'focusKeywords'   => null === $kw ? array() : array_values( array_filter( array_map( 'trim', explode( ',', $kw ) ), 'strlen' ) ),
				'seoScore'        => null !== $score && is_numeric( $score ) ? (int) $score : null,
				'metaTitle'       => psr_meta_text( $id, 'rank_math_title' ),
				'metaDescription' => psr_meta_text( $id, 'rank_math_description' ),
				'noindex'         => psr_noindex( $id ),
			);
		}
	}

	return array(
		'plugin' => array( 'name' => 'rank_math', 'version' => defined( 'RANK_MATH_VERSION' ) ? (string) RANK_MATH_VERSION : '' ),
		'types'  => $summary,
		'items'  => $items,
	);
}
