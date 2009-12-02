
package SphinxSearch::Tags;

use strict;
use warnings;

sub search_results_page_loop_container_tag {
    my ( $ctx, $args, $cond ) = @_;

    require MT::Request;
    my $r            = MT::Request->instance;
    my $number_pages = $r->stash('sphinx_pages_number');
    my $current_page = $r->stash('sphinx_pages_current');
    my $limit        = $r->stash('sphinx_pages_limit');
    my $builder      = $ctx->stash('builder');
    my $tokens       = $ctx->stash('tokens');

    my $res   = '';
    my $glue  = $args->{glue} || '';
    my $lastn = $args->{lastn};
    $lastn = 0 if ( 2 * $lastn + 1 > $number_pages );
    my $low_end =
       !$lastn                     ? 1
      : $current_page - $lastn > 0 ? $current_page - $lastn
      :                              1;
    my $high_end =
       !$lastn                                 ? $number_pages
      : $current_page + $lastn > $number_pages ? $number_pages
      :                                          $current_page + $lastn;
    my @pages = ( $low_end .. $high_end );

    while ( $lastn && scalar @pages < 2 * $lastn + 1 ) {
        unshift @pages, $pages[0] - 1 if ( $pages[0] > 1 );
        push @pages, $pages[$#pages] + 1 if ( $pages[$#pages] < $number_pages );
    }

    local $ctx->{__stash}{sphinx_page_loop_first} = $pages[0];
    local $ctx->{__stash}{sphinx_page_loop_last}  = $pages[$#pages];
    for my $page (@pages) {
        local $ctx->{__stash}{sphinx_page_number} = $page;

        # offset is 0 for page 1, limit for page 2, limit * 2 for page 3, ...
        local $ctx->{__stash}{sphinx_pages_offset} = ( $page - 1 ) * $limit;
        defined(
            my $out = $builder->build(
                $ctx, $tokens,
                {
                    %$cond,
                    IfCurrentSearchResultsPage => ( $page == $current_page ),
                }
            )
        ) or return $ctx->error( $builder->errstr );
        $res .= $glue if $res ne '';
        $res .= $out;
    }
    $res;
}

sub search_results_limit_tag {
    my ( $ctx, $args ) = @_;

    require MT::Request;
    my $r = MT::Request->instance;

    return $r->stash('sphinx_pages_limit') || 0;
}

sub search_results_offset_tag {
    my ( $ctx, $args ) = @_;

    my $offset = $ctx->stash('sphinx_pages_offset');
    return $offset if defined $offset;

    require MT::Request;
    my $r = MT::Request->instance;
    return $r->stash('sphinx_pages_offset') || 0;
}

sub search_results_page_tag {
    my ( $ctx, $args ) = @_;
    my $page_number = $ctx->stash('sphinx_page_number');
    return $page_number if $page_number;

    require MT::Request;
    my $r = MT::Request->instance;
    return $r->stash('sphinx_pages_current') || 0;
}

sub search_sort_mode_tag {
    my ( $ctx, $args ) = @_;

    require MT::App;
    my $app = MT::App->instance;
    my $mode = $app->param('sort_mode') || 'descend';
    return $mode;
}

sub search_match_mode_tag {
    my ( $ctx, $args ) = @_;

    require MT::App;
    my $app = MT::App->instance;
    my $mode = $app->param('match_mode') || 'all';
    return $mode;
}

sub if_current_search_results_page_conditional_tag {
    $_[2]->{ifcurrentsearchresultspage};
}

sub if_multiple_search_results_pages_conditional_tag {
    require MT::Request;
    my $r            = MT::Request->instance;
    my $number_pages = $r->stash('sphinx_pages_number');
    return $number_pages > 1;
}

sub search_result_excerpt_tag {
    my ( $ctx, $args ) = @_;

    my $entry = $ctx->stash('entry')
      or return $ctx->_no_entry_error('MTSearchResultExcerpt');

    require MT::App;
    my $app           = MT::App->instance;
    my $search_string = $app->{search_string};
    my $plugin = MT->component ('sphinxsearch');
    my $words = $plugin->get_config_value( 'search_excerpt_words', 'system' );

    require MT::Util;
  TEXT_FIELD:
    for my $text ( $entry->text, $entry->text_more ) {
        $text = MT::Util::remove_html($text);
        if (   $text
            && $text =~
/(((([\w']+)\b\W*){0,$words})$search_string\b\W*((([\w']+)\b\W*){0,$words}))/ims
          )
        {
            my ( $excerpt, $pre, $post ) = ( $1, $2, $5 );
            $excerpt =~ s{($search_string)}{<b>$1</b>}ig;
            $entry->excerpt($excerpt);
            last TEXT_FIELD;
        }

    }

    my ($handler) = $ctx->handler_for('EntryExcerpt');
    return $handler->( $ctx, $args );
}

sub next_search_results_page {
    my ( $ctx, $args, $cond ) = @_;
    require MT::Request;
    my $r            = MT::Request->instance;
    my $number_pages = $r->stash('sphinx_pages_number');
    my $current_page = $r->stash('sphinx_pages_current');

    $current_page == $number_pages ? '' : $current_page + 1;
}

sub previous_search_results_page {
    my ( $ctx, $args, $cond ) = @_;
    require MT::Request;
    my $r            = MT::Request->instance;
    my $number_pages = $r->stash('sphinx_pages_number');
    my $current_page = $r->stash('sphinx_pages_current');

    $current_page == 1 ? '' : $current_page - 1;
}

sub search_all_result_tag {
    require MT::App;
    MT::App->instance->param('searchall') ? 1 : 0;
}

sub search_total_pages_tag {
    require MT::Request;
    MT::Request->instance->stash('sphinx_pages_number');
}

sub search_next_page_tag {
    my ( $ctx, $args, $cond ) = @_;
    require MT::Request;
    my $r            = MT::Request->instance;
    my $current_page = $r->stash('sphinx_pages_current');
    my $number_pages = $r->stash('sphinx_pages_number');

    return '' if ( $current_page >= $number_pages );

    my $page = $current_page + 1;

    my $limit   = $r->stash('sphinx_pages_limit');
    my $builder = $ctx->stash('builder');
    my $tokens  = $ctx->stash('tokens');

    local $ctx->{__stash}{sphinx_page_number} = $page;

    # offset is 0 for page 1, limit for page 2, limit * 2 for page 3, ...
    local $ctx->{__stash}{sphinx_pages_offset} = ( $page - 1 ) * $limit;
    defined(
        my $out = $builder->build(
            $ctx, $tokens,
            {
                %$cond,
                IfCurrentSearchResultsPage => ( $page == $current_page ),
            }
        )
    ) or return $ctx->error( $builder->errstr );
    $out;
}

sub search_previous_page_tag {
    my ( $ctx, $args, $cond ) = @_;
    require MT::Request;
    my $r            = MT::Request->instance;
    my $current_page = $r->stash('sphinx_pages_current');

    return '' if ( $current_page <= 1 );

    my $page = $current_page - 1;

    my $limit   = $r->stash('sphinx_pages_limit');
    my $builder = $ctx->stash('builder');
    my $tokens  = $ctx->stash('tokens');

    local $ctx->{__stash}{sphinx_page_number} = $page;

    # offset is 0 for page 1, limit for page 2, limit * 2 for page 3, ...
    local $ctx->{__stash}{sphinx_pages_offset} = ( $page - 1 ) * $limit;
    defined(
        my $out = $builder->build(
            $ctx, $tokens,
            {
                %$cond,
                IfCurrentSearchResultsPage => ( $page == $current_page ),
            }
        )
    ) or return $ctx->error( $builder->errstr );
    $out;
}

sub if_first_search_results_page_conditional_tag {
    my ( $ctx, $args ) = @_;
    if ( my $first = $ctx->stash('sphinx_page_loop_first') ) {
        return $ctx->stash('sphinx_page_number') == $first;
    }
    else {
        require MT::Request;
        my $current_page = MT::Request->instance->stash('sphinx_pages_current');
        return $current_page == 1;
    }
}

sub if_last_search_results_page_conditional_tag {
    my ( $ctx, $args ) = @_;
    if ( my $last = $ctx->stash('sphinx_page_loop_last') ) {
        return $ctx->stash('sphinx_page_number') == $last;
    }
    else {
        require MT::Request;
        my $r            = MT::Request->instance;
        my $current_page = $r->stash('sphinx_pages_current');
        my $number_pages = $r->stash('sphinx_pages_number');
        return $current_page == $number_pages;
    }
}

sub search_categories_container_tag {
    my ( $ctx, $args, $cond ) = @_;

    require MT::Request;
    my $cats = $ctx->stash('sphinx_search_categories');
    return '' if ( !$cats );
    require MT::Placement;

    my @cats    = sort { $a->label cmp $b->label } @$cats;
    my $res     = '';
    my $builder = $ctx->stash('builder');
    my $tokens  = $ctx->stash('tokens');
    my $glue    = exists $args->{glue} ? $args->{glue} : '';
    ## In order for this handler to double as the handler for
    ## <MTArchiveList archive_type="Category">, it needs to support
    ## the <$MTArchiveLink$> and <$MTArchiveTitle$> tags
    local $ctx->{inside_mt_categories} = 1;
    for my $cat (@cats) {
        local $ctx->{__stash}{category} = $cat;

# Don't think we need all these bits right now
# local $ctx->{__stash}{entries};
# local $ctx->{__stash}{category_count};
# local $ctx->{__stash}{blog_id} = $cat->blog_id;
# local $ctx->{__stash}{blog} = MT::Blog->load($cat->blog_id, { cached_ok => 1 });
# my @args = (
#     { blog_id => $cat->blog_id,
#       status => MT::Entry::RELEASE() },
#     { 'join' => [ 'MT::Placement', 'entry_id',
#                   { category_id => $cat->id } ],
#       'sort' => 'created_on',
#       direction => 'descend', });
# $ctx->{__stash}{category_count} = MT::Entry->count(@args);
# next unless $ctx->{__stash}{category_count} || $args->{show_empty};

        defined( my $out = $builder->build( $ctx, $tokens, $cond ) )
          or return $ctx->error( $builder->errstr );
        $res .= $glue if $res ne '';
        $res .= $out;
    }
    $res;
}

sub if_index_searched_conditional_tag {
    my ( $ctx, $args ) = @_;
    my $index = $args->{name} || $args->{index};
    my %i = map { $_ => 1 } split( /\s*,\s*/, $index );
    return 0 if ( !$index );
    require MT::Request;
    my $indexes = MT::Request->instance->stash('sphinx_searched_indexes');
    return $indexes && scalar grep { exists $i{$_} } @$indexes;
}

sub if_search_filtered_conditional_tag {
    my ( $ctx, $args ) = @_;
    my $filter_name = $args->{name} || $args->{filter};
    if ($filter_name) {
        return $ctx->stash("sphinx_filter_$filter_name") ? 1 : 0;
    }
    else {
        require MT::Request;
        return MT::Request->instance->stash('sphinx_filters');
    }
}

sub search_filter_value_tag {
    my ( $ctx, $args ) = @_;
    my $filter_name = $args->{name} || $args->{filter}
      or return $ctx->error('filter or name required');
    my $filter_value = $ctx->stash("sphinx_filter_$filter_name");
    return $filter_value ? $filter_value : '';
}

sub if_search_sorted_by_conditional_tag {
    my ( $ctx, $args ) = @_;
    my $sort_arg = $args->{sort} or return 0;
    require MT::Request;
    my $sort_by = MT::Request->instance->stash('sphinx_sort_by');
    return $sort_by eq $sort_arg;
}

sub search_parameters_tag {
    my ( $ctx, $args ) = @_;

    my %skips = map { $_ => 1 } split( /,/, $args->{skip} );
    require MT::App;
    my $app    = MT::App->instance;
    my %params = $app->param_hash;
    require MT::Util;
    return join( '&',
        map    { $_ . '=' . MT::Util::encode_url( $params{$_} ) }
          grep { !exists $skips{$_} } keys %params );
}

sub if_search_date_start_conditional_tag {
    require MT::App;
    my $app = MT::App->instance;
    return defined $app->param('date_start');
}

sub if_search_date_end_conditional_tag {
    require MT::App;
    my $app = MT::App->instance;
    return defined $app->param('date_end');
}

sub search_date_start_tag {
    require MT::App;
    my $app = MT::App->instance;
    local $_[0]->{current_timestamp} = $app->param('date_start') . '0000';

    require MT::Template::ContextHandlers;
    MT::Template::Context::_hdlr_date(@_);
}

sub search_date_end_tag {
    require MT::App;
    my $app = MT::App->instance;
    local $_[0]->{current_timestamp} = $app->param('date_end') . '0000';

    require MT::Template::ContextHandlers;
    MT::Template::Context::_hdlr_date(@_);
}

sub if_not_current_search_results_page {
    !if_current_search_results_page_conditional_tag(@_);
}

sub if_single_search_results_page {
    !if_multiple_search_results_pages_conditional_tag(@_);
}

sub if_first_search_results_page {
    !previous_search_results_page(@_);
}

sub if_last_search_results_page {
    !next_search_results_page(@_);
}

1;
