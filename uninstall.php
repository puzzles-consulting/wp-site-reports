<?php
if ( ! defined( 'WP_UNINSTALL_PLUGIN' ) ) {
	exit;
}

if ( is_multisite() ) { // every site's token, not only the current one's
	foreach ( get_sites( array( 'fields' => 'ids', 'number' => 0 ) ) as $puzzles_sr_site ) {
		switch_to_blog( $puzzles_sr_site );
		delete_option( 'puzzles_site_reports_token' );
		restore_current_blog();
	}
} else {
	delete_option( 'puzzles_site_reports_token' );
}
