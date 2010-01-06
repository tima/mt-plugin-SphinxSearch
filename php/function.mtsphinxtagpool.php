<?php
# Movable Type (r) (C) 2001-2009 Six Apart, Ltd. All Rights Reserved.
# This code cannot be redistributed without permission from www.sixapart.com.
# For more information, consult your Movable Type license.
#
# $Id$

function smarty_function_mtsphinxtagpool($args, &$ctx) {

	if( !empty($args['div']) )
		$div = $args['div'];
	else
		$div = 'tagpool';

	$cats = $args['category'];

	if( !empty($args['limit']) )
		$limit = $args['limit'];
	else
		$limit = 10;

	if( !empty($args['template']) )
		$tmpl = $args['template'];
	else
		$tmpl = 'tagcloud';

	if( !empty($args['searchall']) )
		$searchall = $args['searchall'];
	else
		$searchall = '1';

	if( !empty($args['include_blogs']) )
		$blogs = $args['include_blogs'];
	else if( !empty($args['blog_ids']) )
	 	$blogs = $args['blog_ids'];
	else if( !empty($args['blog_id']) )
	 	$blogs = $args['blog_id'];
	else
		$blogs = '';

	if( !empty($args['jquery']) )
		$load_jquery = $args['jquery'];
	else
		$load_jquery = '0';
	
	if($load_jquery != '0')
		$load_jquery = '<script type="text/javascript" src="http://code.jquery.com/jquery-latest.pack.js"></script>';

	if($load_jquery == '0')
		$load_jquery = '';

	global $mt;
	$script = $ctx->mt->config('SearchScript');

	$cgi_path = $mt->config('CGIPath')."/$script";

	$html = <<<HTML

	$load_jquery
	<div id="tagpool">
	<div id="waiting">...</div>
	</div>
	<script type="text/javascript">
	\$(document).ready(function(){
	        \$.get("$cgi_path", { IncludeBlogs: "$blogs", index: "tag", Template: "$tmpl", searchall: "$searchall", category: "$cats", sort_by: "entry_count", limit: "$limit" },
	          function(data){
	            // alert("Data Loaded: " + data);
	                \$("#$div").html(data);
	          });
	});
	</script>
HTML;

	return $html;
}
