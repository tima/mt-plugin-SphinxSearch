
package SphinxSearch::Search;

use strict;
use warnings;

use MT::Util qw( ts2epoch );
use POSIX;

require MT;
my $plugin = MT->component('sphinxsearch');

sub init_app {
    my ( $cb, $app ) = @_;
    if ( $app->id eq 'new_search' ) {
        no warnings 'redefine';
        *MT::App::Search::execute = sub {
            require SphinxSearch::Util;
            my $results = _get_sphinx_results( @_ );
            return $_[0]->error( "Error querying searchd: "
                  . ( SphinxSearch::Util::_get_sphinx_error() || $_[0]->errstr )
            ) unless ( $results && $results->{result_objs} );
            my @results = ( @{ $results->{result_objs} } );
            return ( $results->{query_results}->{total_found},
                sub { shift @results } );
        };
        my $orig_search_terms = \&MT::App::Search::search_terms;
        *MT::App::Search::search_terms = sub {
            if ( $_[0]->param('searchall') ) {
                $app->param( 'search', '' );
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
    my ( $cb, $app ) = @_;

    if ( !$app->param('search') && $app->param('searchall') ) {
        $app->param( 'search', 'SPHINX_SEARCH_SEARCHALL' );
    }
}


sub _get_sphinx_results {
    my $app = shift;
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

    my @callbacks = (
        [ 'tag', sub { $_[0]->mode eq 'tag' } ],
        [
            'category',
            sub {
                $_[0]->param('category') || $_[0]->param('category_basename');
              }
        ],
        [
            'date',
            sub {
                $_[0]->param('date')
                  || $_[0]->param('date_start')
                  || $_[0]->param('date_end');
              }
        ],
        [ 'author', sub { 1 } ]
    );

    for my $cb (@callbacks) {
        my ( $cb_name, $cb_cond ) = @$cb;
        if ( $cb_cond->($app) ) {
            unless (
                $app->run_callbacks(
                    'sphinx_search.' . $cb_name, $app,
                    $filters,                    $range_filters,
                    $filter_stash,               $vars
                )
              )
            {
                die( "Unable to set $cb_name filter: " . $app->errstr );
            }
        }
    }

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
            die("Unable to load $class for filter $filter: $@") if ($@);
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
            die(    "Unable to find "
                  . $app->param("filter_$filter")
                  . " for $filter" )
              unless (@v);
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
            die("Unable to load $class for filter $filter: $@") if ($@);
            my @v =
              $class->search_by_meta(
                $lookup_meta => $app->param("filter_$filter") );
            if ( @blog_ids && $class->has_column('blog_id') ) {
                my %blogs = map { $_ => 1 } @blog_ids;
                @v = grep { $blogs{ $_->blog_id } } @v;
            }
            die(    "Unable to find "
                  . $app->param("filter_$filter")
                  . " for $filter" )
              unless (@v);
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

    my $sfilters = {};
    for
      my $filter ( map { s/^sfilter_//; $_ } grep { /^sfilter_/ } keys %params )
    {
        $sfilters->{ $filter } = [ $app->param("sfilter_$filter") ];
        $filter_stash->{"sphinx_filter_$filter"} =
          $app->param("sfilter_$filter");
    }

    if ($MT::DebugMode) {
        for my $key ( sort keys %$filters ) {
            warn "SPHINX FILTER: $key => "
              . join( ', ', @{ $filters->{$key} } );
        }

        for my $key ( sort keys %$sfilters ) {
            warn "SPHINX STRING FILTER: $key => "
              . join( ', ', @{ $sfilters->{$key} } );
        }

        for my $key ( sort keys %$range_filters ) {
            warn "SPHINX RANGE FILTER: $key => "
              . join( ', ', @{ $range_filters->{$key} } );
        }
    }

    my $limit  = $app->param('limit')  || $app->{searchparam}{SearchMaxResults};
    my $offset = $app->param('offset') || 0;
    $offset = $limit * ( $app->param('page') - 1 )
      if ( !$offset && $limit && $app->param('page') );

    my $max;
    if ( $app->param('max_matches') ) {
        $max = $app->param('max_matches');
    }
    elsif ( $app->config->SphinxMaxMatches < 0 ) {
        $max = MT::Entry->count(
            { status => MT::Entry::RELEASE(), blog_id => \@blog_ids } );
    }
    elsif ( $app->config->SphinxMaxMatches ) {
        $max = $app->config->SphinxMaxMatches;
    }

    my $match_mode = $app->param('match_mode') || 'all';

    require SphinxSearch::Sphinxable;
    my $results = SphinxSearch::Sphinxable->sphinx_search(
        \@classes,
        $app->{search_string},
        Indexes      => \@indexes,
        Filters      => $filters,
        SFilters     => $sfilters,
        RangeFilters => $range_filters,
        Sort         => $sort_mode,
        Offset       => $offset,
        Limit        => $limit,
        Match        => $match_mode,
        ( $max ? ( Max => $max ) : () ),
        TextFilters => (
              $app->param('use_text_filters')
            ? $app->param('use_text_filters')
            : $app->config->SphinxUseTextFilters
        ),
    );
    return unless ($results);
    my $i = 0;

    if ( my $stash = $indexes{ $indexes[0] }->{stash} ) {
        require MT::Request;
        my $r = MT::Request->instance;
        $r->stash( 'sphinx_stash_name', $stash );
        $r->stash( 'sphinx_results',    $results->{result_objs} );
    }

    my $num_pages = ceil( $results->{query_results}->{total_found} / $limit );
    my $cur_page  = int( $offset / $limit ) + 1;

    require MT::Request;
    my $r = MT::Request->instance;
    $r->stash( 'sphinx_searched_indexes', [@indexes] );
    $r->stash( 'sphinx_results_total',
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
        my @tag_names = MT::Tag->split( ',', $tags );
        # only grab the first tag in a multi-tag search
        # are there any instances where we don't want to do this?
        $stash->{search_string} = MT::Util::encode_html($tag_names[0]);
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
        
        # remove duplicates from the list
        my %seen = ();
        @tag_ids = grep { !$seen{$_}++} @tag_ids;

        $filters->{tag} = \@tag_ids;
    }

    1;
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
        else {
            return $cb->error("Unable to find category $cat_basename");
        }

        require MT::Request;
        $stash->{sphinx_search_categories} = \@all_cats;
    }

    1;
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

    1;
}

sub author {
    my ( $cb, $app, $filters, $range_filters, $stash, $vars ) = @_;
    my $author = $app->param('author') || $app->param('username');

    return 1 unless $author;

    # if there's a comma, split 'em
    require MT::Author;
    if ( $author && $author =~ /,/ ) {
        $author = [ split( /\s*,\s*/, $author ) ];
    }
    my @authors = MT::Author->load( { name => $author } );
    return $cb->error("Unable to locate author $author") unless (@authors);
    $author = $authors[0];
    if ( $author && !$app->param('following_data') ) {
        $filters->{author_id} = [ map { $_->id } @authors ];
        $stash->{author} = $author;
    }
    elsif ($author) {
        eval { require MT::Community::Friending };
        if ( !$@ ) {
            my @followings = MT::Community::Friending::followings($author);

         # if the author has no followers, filter on author_id -1 (i.e., nobody)
         # we can't pass an empty filter or it'll load for everybody
            $filters->{author_id} =
              [ @followings ? ( map { $_->id } @followings ) : (-1) ];
            $stash->{author}        = $author;
            $vars->{following_data} = 1;
        }
    }

    1;
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
    my ( $cb, $app ) = @_;
    delete $app->{search_string};
}

1;
