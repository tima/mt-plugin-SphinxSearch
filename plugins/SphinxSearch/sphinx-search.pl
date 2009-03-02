
package MT::Plugin::SphinxSearch;

use strict;
use warnings;

use base qw( MT::Plugin );

use MT;
use File::Spec;
use POSIX;

use vars qw( $VERSION $plugin );
$VERSION = '0.99.70mt4';
$plugin  = MT::Plugin::SphinxSearch->new(
    {
        id   => 'SphinxSearch',
        name => 'SphinxSearch',
        description =>
          'A search script using the sphinx search engine',
        version => $VERSION,

        author_name => 'Six Apart',
        author_link => 'http://www.sixapart.com/',

        system_config_template => 'system_config.tmpl',
        settings               => MT::PluginSettings->new(
            [
                [ 'sphinx_path',      	{ Default => undef, Scope => 'system' } ],
                [ 'sphinx_file_path', 	{ Default => undef, Scope => 'system' } ],
                [ 'sphinx_conf_path', 	{ Default => undef, Scope => 'system' } ],
                [ 'searchd_host',		{ Default => 'localhost', Scope => 'system' } ],
                [ 'searchd_port', 		{ Default => 3312, Scope => 'system' } ],
                [ 'searchd_pid_path',	{ Default => '/var/log/searchd.pid', Scope => 'system' } ],
                [ 'search_excerpt_words', { Default => 9, Scope => 'system' } ],
                [ 'index_morphology', 	{ Default => 'none', Scope => 'system' } ],
                [ 'db_host', 			{ Default => undef, Scope => 'system' } ],
                [ 'db_user', 			{ Default => undef, Scope => 'system' } ],
                [ 'db_pass', 			{ Default => undef, Scope => 'system' } ],
                [ 'use_indexer_tasks', 	{ Default => 1, Scope => 'system' } ],
                [ 'min_word_len', 		{ Default => 1, Scope => 'system' } ],
                [ 'charset_type', 		{ Default => 'utf-8', Scope => 'system' } ],
            ]
        ),
    }
);
MT->add_plugin($plugin);

sub instance {
    $plugin;
}

sub init_registry {
    my $plugin = shift;
    my $reg    = {
        config_settings => {
            UseSphinxTasks              => { default => 1, },
            UseSphinxDistributedIndexes => { default => 0, },
        },
        applications => {
            cms => { methods => { 'gen_sphinx_conf' => '$SphinxSearch::SphinxSearch::Config::gen_sphinx_conf', } },
            new_search => {
                callbacks => {
                    'sphinx_search.tag' =>
                      '$SphinxSearch::SphinxSearch::Search::tag',
                    'sphinx_search.category' =>
                      '$SphinxSearch::SphinxSearch::Search::category',
                    'sphinx_search.date' =>
                      '$SphinxSearch::SphinxSearch::Search::date',
                    'sphinx_search.author' =>
                      '$SphinxSearch::SphinxSearch::Search::author',
                    'init_request' => '$SphinxSearch::SphinxSearch::Search::init_request',
                }
            }
        },
        tasks => {
            'sphinx_delta_indexer' => {
                name      => 'Sphinx Delta Indexer',
                frequency => 2 * 60,                   # every two minutes
                code => sub { $plugin->sphinx_indexer_task( 'delta', @_ ) },
            },
            'sphinx_indexer' => {
                name      => 'Sphinx Indexer',
                frequency => 24 * 60 * 60,             # every 24 hours
                code => sub { $plugin->sphinx_indexer_task( 'main', @_ ) },
            }
        },
        callbacks => {
            'MT::Template::pre_load' => \&pre_load_template,
            'post_init'              => {
                priority => 1,
                handler  => \&init_sphinxable,
            },

            # 'init_app'  => \&init_apps,
        },
        init_app => \&init_apps,
        tags     => {
            function => {
                'SearchResultsOffset' => \&search_results_offset_tag,
                'SearchResultsLimit'  => \&search_results_limit_tag,
                'SearchResultsPage'   => \&search_results_page_tag,

                'SearchSortMode'  => \&search_sort_mode_tag,
                'SearchMatchMode' => \&search_match_mode_tag,

                'SearchResultExcerpt' => \&search_result_excerpt_tag,

                'NextSearchResultsPage'     => \&next_search_results_page,
                'PreviousSearchResultsPage' => \&previous_search_results_page,

                'SearchAllResult' => \&search_all_result_tag,

                'SearchTotalPages' => \&search_total_pages_tag,

                'SearchFilterValue' => \&search_filter_value_tag,

                'SearchParameters' => \&search_parameters_tag,

                'SearchDateStart' => \&search_date_start_tag,
                'SearchDateEnd'   => \&search_date_end_tag,
            },
            block => {
                'IfCurrentSearchResultsPage?' =>
                  \&if_current_search_results_page_conditional_tag,
                'IfNotCurrentSearchResultsPage?' =>
                  sub { !if_current_search_results_page_conditional_tag(@_) },
                'IfMultipleSearchResultsPages?' =>
                  \&if_multiple_search_results_pages_conditional_tag,
                'IfSingleSearchResultsPage?' =>
                  sub { !if_multiple_search_results_pages_conditional_tag(@_) },

                'SearchResultsPageLoop' =>
                  \&search_results_page_loop_container_tag,
                'SearchNextPage'     => \&search_next_page_tag,
                'SearchPreviousPage' => \&search_previous_page_tag,
                'SearchCategories'   => \&search_categories_container_tag,

                'IfFirstSearchResultsPage?' =>
                  sub { !previous_search_results_page(@_) },
                'IfLastSearchResultsPage?' =>
                  sub { !next_search_results_page(@_) },

                'IfIndexSearched?' => \&if_index_searched_conditional_tag,

                'IfSearchFiltered?' => \&if_search_filtered_conditional_tag,
                'IfSearchSortedBy?' => \&if_search_sorted_by_conditional_tag,

                'IfSearchDateStart?' => \&if_search_date_start_conditional_tag,
                'IfSearchDateEnd?'   => \&if_search_date_end_conditional_tag,
            },
        },
        task_workers => {
            'sphinx_indexer' => {
                label => "Runs the sphinx indexer.",
                class => 'SphinxSearch::Worker::Indexer',
            },
        },
    };
    $plugin->registry($reg);
}

sub sphinx_indexes {
    require SphinxSearch::Index;
    return %{ SphinxSearch::Index::_get_sphinx_indexes() };
}

sub check_searchd {
    my $plugin = shift;

    if ( !$plugin->_check_searchd ) {
        if ( !$plugin->start_searchd ) {
            MT->instance->log( "Error starting searchd: " . $plugin->errstr );
            return $plugin->error(
                "Error starting searchd: " . $plugin->errstr );
        }
    }

    1;
}

sub sphinx_indexer_task {
    my $plugin = shift;
    my $which  = shift;
    my $task   = shift;

    return unless $plugin->get_config_value( 'use_indexer_tasks', 'system' );

    require MT::TheSchwartz;
    require TheSchwartz::Job;

    my $job = TheSchwartz::Job->new;
    $job->funcname('SphinxSearch::Worker::Indexer');
    $job->uniqkey($which);
    $job->priority(10)
      ; # reindexing is high priority, it should be delayed as little as possible
    MT::TheSchwartz->insert($job);

    1;
}

sub init_sphinxable {
    {
        local $SIG{__WARN__} = sub { };
        require SphinxSearch::Sphinxable;
        push @MT::Object::ISA, 'SphinxSearch::Sphinxable';
    }

    require MT::Entry;
    require MT::Comment;
    require MT::Author;
    MT::Entry->sphinx_init(
        select_values => { status => MT::Entry::RELEASE() },
        group_columns => ['author_id'],
        include_meta  => 1,
        mva           => {
            category => {
                to   => 'MT::Category',
                with => 'MT::Placement',
                by   => [ 'entry_id', 'category_id' ],
            }
        },
        date_columns => { authored_on => 1 }
    );
    MT::Comment->sphinx_init(
        select_values => { visible => 1 },
        group_columns => [ 'entry_id', 'commenter_id' ],
        stash         => 'comments',
        include_meta  => 1,
        mva           => {
            response_to => {
                query =>
'select distinct mt_comment.comment_id, response_to.comment_commenter_id from mt_comment, mt_comment as response_to where mt_comment.comment_entry_id = response_to.comment_entry_id and mt_comment.comment_created_on > response_to.comment_created_on and response_to.comment_commenter_id is not null',
                to     => 'MT::Author',
                lookup => 'name',
                stash  => [ 'author', 'authors' ],
            },
            entry_basename => {
                to     => 'MT::Entry',
                lookup => 'basename',
                stash  => [ 'entry', 'entries' ],
                with   => 'MT::Comment',
                by     => [ 'id', 'entry_id' ],
            }
        }
    );
    MT::Author->sphinx_init(
        select_values => { status => MT::Author::APPROVED() },
        include_meta  => 1,
		exclude_columns => [ 'api_password', 'hint', 'password', 'public_key', 'remote_auth_token' ]
    );
}

sub init_apps {
    my $cb = shift;
    my ($app) = @_;
    if ( $app->isa('MT::App::Search') ) {
        require SphinxSearch::Search;
        SphinxSearch::Search::init_app( $cb, $app );
    }

}

sub _pid_path {
    my $plugin = shift;
    my $pid_file = $plugin->get_config_value( 'searchd_pid_path', 'system' );
    my $sphinx_file_path =
      $plugin->get_config_value( 'sphinx_file_path', 'system' );

    return File::Spec->catfile( $sphinx_file_path, 'searchd.pid' )
      if ($sphinx_file_path);
    return $sphinx_file_path;
}

sub run_cmd {
    my $plugin      = shift;
    my ($cmd)       = @_;
    my $res         = `$cmd`;
    my $return_code = $? / 256;
    $return_code ? $plugin->error($res) : 1;
}

sub start_indexer {
    my $plugin = shift;
    my ($indexes) = @_;
    $indexes = 'main' if ( !$indexes );
    my $sphinx_path = $plugin->get_config_value( 'sphinx_path', 'system' )
      or return $plugin->error("Sphinx path is not set");

    my @indexes = $plugin->which_indexes( Indexer => $indexes );

    return $plugin->error("No indexes to rebuild") if ( !@indexes );

    my $sphinx_conf = $plugin->get_config_value( 'sphinx_conf_path', 'system' )
      or return $plugin->error("Sphinx conf path is not set");
    my $indexer_binary = File::Spec->catfile( $sphinx_path, 'indexer' );
    my $cmd = "$indexer_binary --quiet --config $sphinx_conf --rotate "
      . join( ' ', @indexes );
    $plugin->run_cmd($cmd);
}

sub _check_searchd {
    my $plugin   = shift;
    my $pid_path = $plugin->_pid_path;

    open my $pid_file, "<", $pid_path or return undef;
    local $/ = undef;
    my $pid = <$pid_file>;
    close $pid_file;

    # returns number of process that exist and can be signaled
    # sends a 0 signal, which is meaningless as far as I can tell
    return kill 0, $pid;
}

sub start_searchd {
    my $plugin = shift;

    my $bin_path = $plugin->get_config_value( 'sphinx_path', 'system' )
      or return "Sphinx path is not set";
    my $conf_path = $plugin->get_config_value( 'sphinx_conf_path', 'system' )
      or return "Sphinx conf path is not set";
    my $file_path = $plugin->get_config_value( 'sphinx_file_path', 'system' )
      or return "Sphinx file path is not set";

    # Check for lock files and nix them if they exist
    # it's assumed that searchd is *not* running when this function is called
    require SphinxSearch::Index;
    my %indexes = %{ SphinxSearch::Index::_get_sphinx_indexes() };
    foreach my $source ( keys %indexes ) {
        my $lock_path =
          File::Spec->catfile( $file_path, $source . '_index.spl' );
        if ( -f $lock_path ) {
            unlink $lock_path;
        }
    }

    my $searchd_path = File::Spec->catfile( $bin_path, 'searchd' );

    $plugin->run_cmd("$searchd_path --config $conf_path");
}

sub _process_extended_sort {
    my $plugin = shift;
    my ( $class, $sort_string ) = @_;

    my $datasource = $class->datasource;

    $sort_string =~ s/(?<!@)\b(\w+)\b(?!(?:,|$))/${datasource}_$1/gi;
    $sort_string;
}

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

sub pre_load_template {
    my ( $cb, $params ) = @_;

    # skip out of here if this isn't a search app
    # we don't want to screw anything up
    require MT::App;
    my $app = MT::App->instance;
    return unless ( $app && $app->isa('MT::App::Search') );

    return unless ( my $tmpl_id = $app->param('tmpl_id') );
    if (   'HASH' eq ref( $params->[1] )
        && scalar keys %{ $params->[1] } == 2
        && $params->[1]->{blog_id}
        && $params->[1]->{type} eq 'search_template' )
    {
        $params->[1] = $tmpl_id;
    }
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

1;
