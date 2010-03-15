<?php
#############################################################################
# Copyright © 2006-2010 Six Apart Ltd.
# This program is free software: you can redistribute it and/or modify it
# under the terms of version 2 of the GNU General Public License as published
# by the Free Software Foundation, or (at your option) any later version.
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# version 2 for more details.  You should have received a copy of the GNU
# General Public License version 2 along with this program. If not, see
# <http://www.gnu.org/licenses/>

function smarty_function_mtsphinxtagpool($args, &$ctx) {

	if( !empty($args['div']) )
		$div = $args['div'];
	else
		$div = 'tagpool';

	$cats = $args['category'];

	if( !empty($args['template']) )
		$tmpl = $args['template'];
	else
		$tmpl = 'tagcloud';

	if( !empty($args['searchall']) )
		$searchall = $args['searchall'];
	else
		$searchall = '1';

	if( !empty($args['searchterm']) )
		$searchterm = $args['searchterm'];
	else
		$searchterm = '';

	if( !empty($args['loading']) )
		$loading = $args['loading'];
	else
		$loading = 'loading...';

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
	<div id="waiting">$loading</div>
	</div>
	<script type="text/javascript">
	\$(document).ready(function(){
	        \$.get("$cgi_path", { IncludeBlogs: "$blogs", index: "tag", Template: "$tmpl", searchall: "$searchall", category: "$cats", sort_by: "entry_count", search: "$searchterm" },
	          function(data){
            	// alert("Data Loaded: " + data);
                \$("#$div").html(data);
				// Fix the category argument in the Tag search URL
				jQuery.each(\$("#tagpool a"), function(i, val) {
					this.href = this.href + '&category=$cats';
				});
	          });
	});
	</script>
HTML;

	return $html;
}
