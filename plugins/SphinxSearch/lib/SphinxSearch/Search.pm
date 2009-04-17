
package SphinxSearch::Search;

use strict;
use warnings;

use MT::Util qw( ts2epoch );
use POSIX;

require MT;
my $plugin = MT->component('sphinxsearch');

sub init_app {
    my ( $cb, $app ) = @_;
    if ( $app->id eq 'search' ) {
        local $SIG{__WARN__} = sub { };
        *MT::App::Search::_straight_search = \&straight_sphinx_search;
        *MT::App::Search::_tag_search      = \&straight_sphinx_search;
        *MT::App::Search::Context::_hdlr_result_count = \&result_count_tag;
        my $orig_results = \&MT::App::Search::Context::_hdlr_results;
        *MT::App::Search::Context::_hdlr_results = sub {
            _resort_sphinx_results(@_);
            $orig_results->(@_);
        };

        # we need to short-circuit this as the search string has been stuffed
        # in the case of searchall=1
        my $orig_search_string =
          \&MT::App::Search::Context::_hdlr_search_string;
        *MT::App::Search::Context::_hdlr_search_string = sub {
            $app->param('searchall') ? '' : $orig_search_string->(@_);
        };

        my $orig_init = \&MT::App::Search::Context::init;
        *MT::App::Search::Context::init = sub {
            my $res = $orig_init->(@_);
            _sphinx_search_context_init(@_);
            return $res;
          }
    }
    elsif ( $app->id eq 'new_search' ) {
        local $SIG{__WARN__} = sub { };
        *MT::App::Search::execute = sub {
            require SphinxSearch::Util;
            my $results = _get_sphinx_results( $_[0] );
            return $_[0]->error( "Error querying searchd: "
                  . ( SphinxSearch::Util::_get_sphinx_error() || $_[0]->errstr )
            ) unless ( $results && $results->{result_objs} );
            my @results = ( @{ $results->{result_objs} } );
            return ( $results->{query_results}->{total},
                sub { shift @results } );
        };
        my $orig_search_terms = \&MT::App::Search::search_terms;
        *MT::App::Search::search_terms = sub {
            if ($_[0]->param ('searchall')) {
                $app->param ('search', '');
                return ('');
            }
            return $orig_search_terms->(@_);
        };
        my $orig_prep_context = \&MT::App::Search::prepare_context;
        *MT::App::Search::prepare_context = sub {
            my $ctx = $orig_prep_context->(@_);
            _sphinx_search_context_init($ctx);
            return $ctx;
          };
    }

}

sub init_request {
    my ($cb, $app) = @_;
    
    if (!$app->param ('search') && $app->param ('searchall')) {
        $app->param ('search', 'SPHINX_SEARCH_SEARCHALL');
    }
}

sub straight_sphinx_search {
    my $app = shift;

# Skip out unless either there *is* a search term, or we're explicitly searching all
    return 1
      unless ( $app->{search_string} =~ /\S/ || $app->param('searchall') );

    my (%hits);
    my $results = _get_sphinx_results(
        $app,
        sub {
            my ( $o, $i ) = @_;
            my $blog_id = $o->blog_id;
            $o->{__sphinx_search_index} = $i;
            $app->_store_hit_data( $o->blog, $o, $hits{$blog_id}++ );
        }
    );
    1;
}

sub _get_sphinx_results {
    my $app = shift;
    my ($res_callback) = @_;
    require MT::Log;
    my $blog_id;
    if ( $app->{searchparam}{IncludeBlogs}
        && scalar( keys %{ $app->{searchparam}{IncludeBlogs} } ) == 1 )
    {
        ($blog_id) = keys %{ $app->{searchparam}{IncludeBlogs} };
    }

    require SphinxSearch::Index;
    my %indexes = %{ SphinxSearch::Index::_get_sphinx_indexes() };
    my @indexes = split( /,/, $app->param('index') || 'entry' );
    my @classes;
    foreach my $index (@indexes) {
        my $class = $indexes{$index}->{class};
        eval("require $class;");
        if ($@) {
            return $app->error( "Error loading $class ($index): " . $@ );
        }
        push @classes, $class;
    }

    my %classes = map { $_ => 1 } @classes;

    # if MT::Entry is in there, it should be first, just in case
    @classes =
      ( delete $classes{'MT::Entry'} ? ('MT::Entry') : (), keys %classes );

    my $index = $app->param('index') || 'entry';
    my $class = $indexes{$index}->{class};

    my $sort_mode       = {};
    my $sort_mode_param = $app->param('sort_mode') || 'descend';
    my $sort_by_param   = $app->param('sort_by')
      || ( $index =~ /\bentry\b/ ? 'authored_on' : 'created_on' );

    if ( $sort_mode_param eq 'descend' ) {
        $sort_mode = { Descend => $sort_by_param };
    }
    elsif ( $sort_mode_param eq 'ascend' ) {
        $sort_mode = { Ascend => $sort_by_param };
    }
    elsif ( $sort_mode_param eq 'relevance' ) {
        $sort_mode = {};
    }
    elsif ( $sort_mode_param eq 'extended' ) {
        if ( my $extended_sort = $app->param('extended_sort') ) {
            $sort_mode = { Extended => $extended_sort };
        }
    }
    elsif ( $sort_mode_param eq 'segments' ) {
        $sort_mode = { Segments => 'authored_on' };
    }

    my @blog_ids      = keys %{ $app->{searchparam}{IncludeBlogs} };
    my $filters       = { blog_id => \@blog_ids, };
    my $filter_stash  = {};
    my $range_filters = {};
    my $vars          = {};

    $app->run_callbacks( 'sphinx_search.tag', $app, $filters, $range_filters,
        $filter_stash )
      if ( $app->mode eq 'tag' );
    $app->run_callbacks( 'sphinx_search.category', $app, $filters,
        $range_filters, $filter_stash )
      if ( $app->param('category') || $app->param('category_basename') );
    $app->run_callbacks( 'sphinx_search.date', $app, $filters, $range_filters,
        $filter_stash )
      if ( $app->param('date')
        || $app->param('date_start')
        || $app->param('date_end') );
    $app->run_callbacks( 'sphinx_search.author', $app, $filters, $range_filters,
        $filter_stash, $vars );

    $filter_stash->{"sphinx_filter_$_"} = join( ',', @{ $range_filters->{$_} } )
      foreach ( keys %$range_filters );
    $filter_stash->{"sphinx_filter_$_"} = join( ',', @{ $filters->{$_} } )
      foreach ( keys %$filters );

    # General catch-all for filters
    my %params = $app->param_hash;
    for my $filter ( map { s/^filter_//; $_ } grep { /^filter_/ } keys %params )
    {
        if ( my $lookup = $indexes{ $indexes[0] }->{mva}->{$filter}->{lookup} )
        {
            my $class = $indexes{ $indexes[0] }->{mva}->{$filter}->{to};
            eval("require $class;");
            die ("Unable to load $class for filter $filter: $@") if ($@);
            my @v = $class->load(
                {
                    $lookup => $app->param("filter_$filter"),
                    (
                        $class->has_column('blog_id')
                        ? ( blog_id => \@blog_ids )
                        : ()
                    )
                }
            );
            die ("Unable to find " . $app->param ("filter_$filter") . " for $filter") unless (@v);
            $filters->{$filter} = [ map { $_->id } @v ];

            if ( my $stash =
                $indexes{ $indexes[0] }->{mva}->{$filter}->{stash} )
            {
                if ( ref($stash) eq 'ARRAY' ) {
                    if ($#v) {
                        $filter_stash->{ $stash->[1] } = \@v;
                    }
                    else {
                        $filter_stash->{ $stash->[0] } = $v[0];
                    }
                }
                else {
                    $filter_stash->{$stash} = \@v;
                }
            }
            $filter_stash->{"sphinx_filter_$filter"} =
              $app->param("filter_$filter");
        }
        elsif ( my $lookup_meta =
            $indexes{ $indexes[0] }->{mva}->{$filter}->{lookup_meta} )
        {
            my $class = $indexes{ $indexes[0] }->{mva}->{$filter}->{to};
            eval("require $class;");
            die ("Unable to load $class for filter $filter: $@") if ($@);
            my @v =
              $class->search_by_meta(
                $lookup_meta => $app->param("filter_$filter") );
            if ( @blog_ids && $class->has_column('blog_id') ) {
                my %blogs = map { $_ => 1 } @blog_ids;
                @v = grep { $blogs{ $_->blog_id } } @v;
            }
            die ("Unable to find " . $app->param ("filter_$filter") . " for $filter") unless (@v);
            $filters->{$filter} = [ map { $_->id } @v ];

            if ( my $stash =
                $indexes{ $indexes[0] }->{mva}->{$filter}->{stash} )
            {
                if ( ref($stash) eq 'ARRAY' ) {
                    if ($#v) {
                        $filter_stash->{ $stash->[1] } = \@v;
                    }
                    else {
                        $filter_stash->{ $stash->[0] } = $v[0];
                    }
                }
                else {
                    $filter_stash->{$stash} = \@v;
                }
            }
            $filter_stash->{"sphinx_filter_$filter"} =
              $app->param("filter_$filter");
        }

        else {
            $filters->{$filter} = [ $app->param("filter_$filter") ];
            $filter_stash->{"sphinx_filter_$filter"} =
              $app->param("filter_$filter");
        }
    }
    for
      my $filter ( map { s/^sfilter_//; $_ } grep { /^sfilter_/ } keys %params )
    {
        require String::CRC32;
        $filters->{ $filter . '_crc32' } =
          [ String::CRC32::crc32( $app->param("sfilter_$filter") ) ];
        $filter_stash->{"sphinx_filter_$filter"} =
          $app->param("sfilter_$filter");
    }

    my $limit  = $app->param('limit')  || $app->{searchparam}{SearchMaxResults};
    my $offset = $app->param('offset') || 0;
    $offset = $limit * ( $app->param('page') - 1 )
      if ( !$offset && $limit && $app->param('page') );

    my $max;
    if ($app->param ('max_matches')) {
        $max = $app->param ('max_matches');
    }
    elsif ($app->config->SphinxMaxMatches < 0) {
        $max = MT::Entry->count(
            { status => MT::Entry::RELEASE(), blog_id => \@blog_ids } );   
    }
    elsif ($app->config->SphinxMaxMatches) {
        $max = $app->config->SphinxMaxMatches;
    }

    my $match_mode = $app->param('match_mode') || 'all';

    require SphinxSearch::Sphinxable;
    my $results = SphinxSearch::Sphinxable->sphinx_search(
        \@classes, $app->{search_string},
        Indexes      => \@indexes,
        Filters      => $filters,
        RangeFilters => $range_filters,
        Sort         => $sort_mode,
        Offset       => $offset,
        Limit        => $limit,
        Match        => $match_mode,
        ( $max ? ( Max => $max ) : () )
    );
    return unless ($results);
    my $i = 0;

    if ( my $stash = $indexes{ $indexes[0] }->{stash} ) {
        require MT::Request;
        my $r = MT::Request->instance;
        $r->stash( 'sphinx_stash_name', $stash );
        $r->stash( 'sphinx_results',    $results->{result_objs} );
    }
    elsif ($res_callback) {
        foreach my $o ( @{ $results->{result_objs} } ) {
            $res_callback->( $o, $i++ );
        }
    }

    my $num_pages = ceil( $results->{query_results}->{total} / $limit );
    my $cur_page  = int( $offset / $limit ) + 1;

    require MT::Request;
    my $r = MT::Request->instance;
    $r->stash( 'sphinx_searched_indexes', [@indexes] );
    $r->stash( 'sphinx_results_total', $results->{query_results}->{total} );
    $r->stash( 'sphinx_results_total_found',
        $results->{query_results}->{total_found} );
    $r->stash( 'sphinx_pages_number',  $num_pages );
    $r->stash( 'sphinx_pages_current', $cur_page );
    $r->stash( 'sphinx_pages_offset',  $offset );
    $r->stash( 'sphinx_pages_limit',   $limit );
    $r->stash( 'sphinx_filters',       $filter_stash );
    $r->stash( 'tmpl_vars',            $vars );
    $r->stash( 'sphinx_sort_by',       $sort_by_param );

    $results;
}

sub result_count_tag {
    my ( $ctx, $args ) = @_;
    require MT::Request;
    my $r = MT::Request->instance;
    return $r->stash('sphinx_results_total') || 0;
}

sub _resort_sphinx_results {
    my ( $ctx, $args, $cond ) = @_;

    my $results = $ctx->stash('results') || return;

    $results = [
        sort {
            $a->{entry}->{__sphinx_search_index} <=> $b->{entry}
              ->{__sphinx_search_index}
          } @$results
    ];
    $ctx->stash( 'results', $results );
}

sub tag {
    my ( $cb, $app, $filters, $range_filters, $stash ) = @_;

    # if it's a tag search,
    # grab all the tag ids we can find for a filter
    # and nix the search keyword
    if ( $app->mode eq 'tag' ) {
        require MT::Tag;
        my $tags = delete $app->{search_string};
        require MT::Util;
        $stash->{search_string} = MT::Util::encode_html($tags);
        my @tag_names = MT::Tag->split( ',', $tags );
        my %tags = map { $_ => 1, MT::Tag->normalize($_) => 1 } @tag_names;
        my @tags = MT::Tag->load( { name => [ keys %tags ] } );
        my @tag_ids;

        foreach (@tags) {
            push @tag_ids, $_->id;
            my @more =
              MT::Tag->load( { n8d_id => $_->n8d_id ? $_->n8d_id : $_->id } );
            push @tag_ids, $_->id foreach @more;
        }
        @tag_ids = (0) unless @tags;

        $filters->{tag} = \@tag_ids;
    }
}

sub category {
    my ( $cb, $app, $filters, $range_filters, $stash ) = @_;
    if ( my $cat_basename = $app->param('category')
        || $app->param('category_basename') )
    {
        my @blog_ids = keys %{ $app->{searchparam}{IncludeBlogs} };
        my @all_cats;
        require MT::Category;
        foreach my $cat_base ( split( /,/, $cat_basename ) ) {
            my @cats = MT::Category->load(
                { blog_id => \@blog_ids, basename => $cat_base } );
            if (@cats) {
                push @all_cats, @cats;
            }
        }
        if (@all_cats) {
            $filters->{category} = [ map { $_->id } @all_cats ];
        }

        require MT::Request;
        $stash->{sphinx_search_categories} = \@all_cats;
    }
}

sub date {
    my ( $cb, $app, $filters, $range_filters, $stash ) = @_;
    if ( $app->param('date_start') || $app->param('date_end') ) {
        my $blog_id;
        if ( $app->{searchparam}{IncludeBlogs}
            && scalar( keys %{ $app->{searchparam}{IncludeBlogs} } ) == 1 )
        {
            ($blog_id) = keys %{ $app->{searchparam}{IncludeBlogs} };
        }
        my $date_start = $app->param('date_start');
        if ($date_start) {
            $date_start = ts2epoch( $blog_id, $date_start . '0000' );
        }
        else {
            $date_start = 0;
        }

        my $date_end = $app->param('date_end');
        if ($date_end) {
            $date_end = ts2epoch( $blog_id, $date_end . '0000' );
        }
        else {

            # max timestamp value? maybe 0xFFFFFFFF instead?
            # this is probably large enough
            $date_end = 2147483647;
        }

        $range_filters->{created_on} = [ $date_start, $date_end ];
    }
}

sub author {
    my ( $cb, $app, $filters, $range_filters, $stash, $vars ) = @_;
    my $author = $app->param('author') || $app->param('username');

    # if there's a comma, split 'em
    require MT::Author;
    if ( $author && $author =~ /,/ ) {
        $author = [ split( /\s*,\s*/, $author ) ];
    }
    my @authors = MT::Author->load( { name => $author } );
    $author = $authors[0];
    if ( $author && !$app->param('following_data') ) {
        $filters->{author_id} = [ map { $_->id } @authors ];
        $stash->{author} = $author;
    }
    elsif ($author) {
        eval { require MT::Community::Friending };
        if ( !$@ ) {
            my @followings = MT::Community::Friending::followings($author);

            $filters->{author_id}   = [ map { $_->id } @followings ];
            $stash->{author}        = $author;
            $vars->{following_data} = 1;
        }
    }
}

sub _sphinx_search_context_init {
    my $ctx = shift;

    require MT::Request;
    my $r             = MT::Request->instance;
    my $stash_name    = $r->stash('sphinx_stash_name');
    my $stash_results = $r->stash('sphinx_results');
    if ( $stash_name && $stash_results ) {
        $ctx->stash( $stash_name, $stash_results );
    }

    if ( my $filter_stash = $r->stash('sphinx_filters') ) {
        while ( my ( $k, $v ) = each %$filter_stash ) {
            $ctx->stash( $k, $v );
        }
    }

    if ( my $vars = $r->stash('tmpl_vars') ) {
        while ( my ( $k, $v ) = each %$vars ) {
            $ctx->var( $k, $v );
        }
    }

    require MT::App;
    my $app = MT::App->instance;
    if ( $app->param('searchall') ) {

        # not cute, but it'll work
        # and with the updated tag handler
        # it shouldn't be exposed
        $ctx->stash( 'search_string', 'searchall' );
    }

    $ctx->stash( 'limit',  $r->stash('sphinx_pages_limit') );
    $ctx->stash( 'offset', $r->stash('sphinx_pages_offset') );
    $ctx->stash( 'count',  $r->stash('sphinx_results_total') );
}

sub take_down {
    my ($cb, $app) = @_;
    delete $app->{search_string};
}


1;
