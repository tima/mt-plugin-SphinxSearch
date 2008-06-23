
package MT::Plugin::SphinxSearch;

use strict;
use warnings;

use base qw( MT::Plugin );

use MT;
use Sphinx;
use File::Spec;
use POSIX;

use MT::Util qw( ts2epoch );

use vars qw( $VERSION $plugin );
$VERSION = '0.99.12';
$plugin = MT::Plugin::SphinxSearch->new ({
        name    => 'SphinxSearch',
        description => 'A search script using the sphinx search engine for MySQL',
        version     => $VERSION,

        author_name => 'Apperceptive, LLC',
        author_link => 'http://www.apperceptive.com/',

        system_config_template  => 'system_config.tmpl',
        settings    => MT::PluginSettings->new ([
            [ 'sphinx_path', { Default => undef, Scope => 'system' }],
            [ 'sphinx_file_path', { Default => undef, Scope => 'system' } ],
            [ 'sphinx_conf_path', { Default => undef, Scope => 'system' }],
            [ 'searchd_host', { Default => 'localhost', Scope => 'system' }],
            [ 'searchd_port', { Default => 3312, Scope => 'system' }],
            [ 'searchd_pid_path', { Default => '/var/log/searchd.pid', Scope => 'system' } ],
            [ 'search_excerpt_words', { Default => 9, Scope => 'system' } ],
            [ 'index_morphology', { Default => 'none', Scope => 'system' } ],
            ]),
        
        tasks   => {
            'sphinx_indexer'    => {
                name    => 'Sphinx Indexer',
                frequency   => 15 * 60,
                code        => sub { $plugin->sphinx_indexer_task (@_) },
            }
        },
        
        init_app    => \&init_apps,
        
        app_methods => {
            'MT::App::CMS'  => {
                'gen_sphinx_conf'  => \&gen_sphinx_conf,
            },
        },
        
        container_tags  => {
            'SearchResultsPageLoop'  => \&search_results_page_loop_container_tag,
        },
        
        template_tags   => {
            'SearchResultsOffset'   => \&search_results_offset_tag,
            'SearchResultsLimit'    => \&search_results_limit_tag,
            'SearchResultsPage'     => \&search_results_page_tag,
            
            'SearchSortMode'        => \&search_sort_mode_tag,
            'SearchMatchMode'       => \&search_match_mode_tag,
            
            'SearchResultExcerpt'   => \&search_result_excerpt_tag,
            
            'SearchAllResult'       => \&search_all_result_tag,
        },
        
        conditional_tags    => {
            'IfCurrentSearchResultsPage'    => \&if_current_search_results_page_conditional_tag,
            'IfNotCurrentSearchResultsPage' => sub { !if_current_search_results_page_conditional_tag (@_) },
            'IfMultipleSearchResultsPages'  => \&if_multiple_search_results_pages_conditional_tag,
            'IfSingleSearchResultsPage'     => sub { !if_multiple_search_results_pages_conditional_tag (@_) },
        },
        

});
MT->add_plugin ($plugin);

{
    local $SIG{__WARN__} = sub { };
    *MT::Object::sphinx_init = sub { $plugin->sphinx_init (@_); };
    *MT::Object::sphinx_search = sub { $plugin->sphinx_search (@_); };
}

require MT::Entry;
require MT::Comment;
MT::Entry->sphinx_init (
    select_values => { status => MT::Entry::RELEASE }, 
    mva => {
        category    => {
            to      => 'MT::Category',
            with    => 'MT::Placement',
            by      => [ 'entry_id', 'category_id' ],
        },
    },
);
MT::Comment->sphinx_init (select_values => { visible => 1 }, group_columns => [ 'entry_id' ]);

sub instance {
    $plugin;
}

my %indexes;

sub sphinx_indexer_task {
    my $plugin = shift;
    my $task = shift;
    
    if (!$plugin->check_searchd) {
        if (my $err = $plugin->start_searchd) {
            MT->instance->log ("Error starting searchd: $err");
            die ("Error starting searchd: $err");
        }
    }
    
    if (my $err = $plugin->start_indexer) {
        MT->instance->log ("Error starting sphinx indexer: $err");
        die ("Error starting sphinx indexer: $err");
    }
    
    1;
}

sub init_apps {
    my $plugin = shift;
    my ($app) = @_;
    
    if ($app->isa ('MT::App::Search')) {
        $plugin->init_search_app ($app);
    }
    
}


sub init_search_app {
    my $plugin = shift;
    my ($app) = @_;
        
    {
        local $SIG{__WARN__} = sub { };
        *MT::App::Search::_straight_search = \&straight_sphinx_search;
        *MT::App::Search::Context::_hdlr_result_count = \&result_count_tag;
        my $orig_results = \&MT::App::Search::Context::_hdlr_results;
        *MT::App::Search::Context::_hdlr_results = sub {
            _resort_sphinx_results (@_);
            $orig_results->(@_);
        }
    }

}

sub _resort_sphinx_results {
    my ($ctx, $args, $cond) = @_;
    
    my $results = $ctx->stash ('results') || return;
    
    $results = [ sort { $a->{entry}->{__sphinx_search_index} <=> $b->{entry}->{__sphinx_search_index} } @$results ];
    $ctx->stash ('results', $results);
}

sub _get_sphinx {
    my $spx = Sphinx->new;
    $spx->SetServer($plugin->get_config_value ('searchd_host', 'system'), $plugin->get_config_value ('searchd_port', 'system'));

    return $spx;
}

sub result_count_tag {
    my ($ctx, $args) = @_;
    require MT::Request;
    my $r = MT::Request->instance;
    return $r->stash ('sphinx_results_total') || 0;
}


sub straight_sphinx_search {
    my $app = shift;

    # Skip out unless either there *is* a search term, or we're explicitly searching all
    return 1 unless ($app->{search_string} =~ /\S/ || $app->param ('searchall'));

    require MT::Log;
    my $blog_id;
    if ($app->{searchparam}{IncludeBlogs} && scalar (keys %{ $app->{searchparam}{IncludeBlogs} }) == 1) {
        ($blog_id) = keys %{ $app->{searchparam}{IncludeBlogs}};
    }
    
    $app->log({
        message => $app->translate("Search: query for '[_1]'",
              $app->{search_string}),
        level => MT::Log::INFO(),
        class => 'search',
        category => 'straight_search',
        $blog_id ? (blog_id => $blog_id) : ()
    });


    my $spx = _get_sphinx;

    my @indexes = split (/,/, $app->param ('index') || 'entry');
    my @classes;
    foreach my $index (@indexes) {
        my $class = $indexes{$index}->{class};
        eval ("require $class;");
        if ($@) {
            return $app->error ("Error loading $class ($index): " . $@);
        }
        push @classes, $class;
    }
    
    my %classes = map { $_ => 1 } @classes;
    # if MT::Entry is in there, it should be first, just in case
    @classes = ( delete $classes{'MT::Entry'} ? ('MT::Entry') : (), keys %classes);

    my $index = $app->param ('index') || 'entry';
    my $class = $indexes{ $index }->{class};
    my $search_keyword = $app->{search_string};
    
    my $sort_mode = {};
    my $sort_mode_param = $app->param ('sort_mode') || 'descend';
    
    if ($sort_mode_param eq 'descend') {
        $sort_mode = { Descend => 'created_on' };
    }
    elsif ($sort_mode_param eq 'ascend') {
        $sort_mode = { Ascend => 'created_on' };
    }
    elsif ($sort_mode_param eq 'relevance') {
        $sort_mode = {};
    }
    elsif ($sort_mode_param eq 'extended') {
        if (my $extended_sort = $app->param ('extended_sort')) {
            $sort_mode = { Extended => $extended_sort };            
        }
    }
    elsif ($sort_mode_param eq 'segments') {
        $sort_mode = { Segments => 'created_on' };
    }
    
    my @blog_ids = keys %{ $app->{ searchparam }{ IncludeBlogs } };
    my $filters = {
        blog_id => \@blog_ids,
    };
    my $range_filters = {};
    
    if (my $cat_basename = $app->param ('category') || $app->param ('category_basename')) {
        require MT::Category;
        my @cats = MT::Category->load ({ blog_id => \@blog_ids, basename => $cat_basename });
        if (@cats) {
            $filters->{category} = [ map { $_->id } @cats ];
        }
    }
    
    if ($app->param ('date_start') || $app->param ('date_end')) {
        my $date_start = $app->param ('date_start');
        if ($date_start) {
            $date_start = ts2epoch ($blog_id, $date_start . '0000');
        }
        else {
            $date_start = 0;
        }
        
        my $date_end = $app->param ('date_end');
        if ($date_end) {
            $date_end = ts2epoch ($blog_id, $date_end . '0000');
        }
        else {
            # max timestamp value? maybe 0xFFFFFFFF instead?
            # this is probably large enough
            $date_end = 2147483647;
        }
        
        $range_filters->{created_on} = [ $date_start, $date_end ];
    }
    
    my $offset = $app->param ('offset') || 0;
    my $limit  = $app->param ('limit') || $app->{searchparam}{MaxResults};
    
    my $match_mode = $app->param ('match_mode') || 'all';
    
    my $results = $plugin->sphinx_search (\@classes, $search_keyword, 
        Filters         => $filters,
        RangeFilters    => $range_filters,
        Sort            => $sort_mode, 
        Offset          => $offset, 
        Limit           => $limit,
        Match           => $match_mode,
    );
    my(%blogs, %hits);
    my $i = 0;
    foreach my $o (@{$results->{result_objs}}) {
        my $blog_id = $o->blog_id;
        $o->{__sphinx_search_index} = $i++;
        $app->_store_hit_data ($o->blog, $o, $hits{$blog_id}++);
    }
    
    my $num_pages = ceil ($results->{query_results}->{total} / $limit);
    my $cur_page  = int ($offset / $limit) + 1;
    
    require MT::Request;
    my $r = MT::Request->instance;
    $r->stash ('sphinx_results_total', $results->{query_results}->{total});
    $r->stash ('sphinx_results_total_found', $results->{query_results}->{total_found});
    $r->stash ('sphinx_pages_number', $num_pages);
    $r->stash ('sphinx_pages_current', $cur_page);
    $r->stash ('sphinx_pages_offset', $offset);
    $r->stash ('sphinx_pages_limit', $limit);
    1;
}

sub _pid_path {
    my $plugin = shift;
    my $pid_file = $plugin->get_config_value ('searchd_pid_path', 'system');
    my $sphinx_file_path = $plugin->get_config_value ('sphinx_file_path', 'system');
    
    return File::Spec->catfile ($sphinx_file_path, 'searchd.pid') if ($sphinx_file_path);
    return $sphinx_file_path;
}

sub gen_sphinx_conf {
    my $app = shift;
    
    my $tmpl = $plugin->load_tmpl ('sphinx.conf.tmpl') or die $plugin->errstr;
    my %params;
    
    $params{searchd_port} = $plugin->get_config_value ('searchd_port', 'system');
    
    $params{ db_host } = $app->{cfg}->DBHost;
    $params{ db_user } = $app->{cfg}->DBUser;
    $params{ db_pass } = $app->{cfg}->DBPassword;
    $params{  db_db  } = $app->{cfg}->Database;
    $params{ tmp } = $app->{cfg}->TempDir;
    $params{ file_path } = $plugin->get_config_value ('sphinx_file_path', 'system') || $app->{cfg}->TempDir;
    $params{ pid_path } = $plugin->_pid_path;
    $params{ morphology } = $plugin->get_config_value ('index_morphology', 'system') || 'none';
 
    my %info_query;
    my %query;
    my %mva;
    foreach my $source (keys %indexes) {
        $query{$source} = "SELECT " . join(", ", map { 
            $indexes{$source}->{date_columns}->{$_} ? 'UNIX_TIMESTAMP(' . $source . '_' . $_ . ') as ' . $_ :
            $indexes{$source}->{group_columns}->{$_} ? "${source}_$_ as $_" :
                                                      $source . '_' . $_
            } ( $indexes{$source}->{ id_column }, @{ $indexes{$source}->{ columns } } ) ) . 
            " FROM mt_$source";
        if (my $sel_values = $indexes{$source}->{select_values}) {
            $query{$source} .= " WHERE " . join (" AND ", map { "${source}_$_ = \"" . $sel_values->{$_} . "\""} keys %$sel_values);
        }
        $info_query{$source} = "SELECT * from mt_$source where ${source}_" . $indexes{$source}->{ id_column } . ' = $id';
        
        if ($indexes{$source}->{mva}) {
            foreach my $mva (keys %{$indexes{$source}->{mva}}) {
                my $cur_mva = $indexes{$source}->{mva}->{$mva};
                my $mva_source = $cur_mva->{with}->datasource;
                my $mva_query = "SELECT " . join (', ', map { "${mva_source}_$_" } @{$cur_mva->{by}}) . " from mt_" . $mva_source;
                if (my $sel_values = $cur_mva->{select_values}) {
                    $mva_query .= " WHERE " . join (" AND ", map { "${mva_source}_$_ = \"" . $sel_values->{$_} . "\""} keys %$sel_values);
                }
                push @{$mva{$source}}, { mva_query => $mva_query, mva_name => $mva };
            }            
        }
    }
    $params{ source_loop } = [
        map {
                {
                 source => $_,
                 query  => $query{$_},
                 info_query => $info_query{$_},
                 group_loop    => [ map { { group_column => $_ } } keys %{$indexes{$_}->{group_columns}} ],
                 date_loop  => [ map { { date_column => $_ } } keys %{$indexes{$_}->{date_columns}} ],
                 delta  => $indexes{$_}->{delta},
                 mva_loop   => $mva{$_} || [],
                } 
        }
        keys %indexes
    ];
    
    my $str = $app->build_page ($tmpl, \%params);
    die $app->errstr if (!$str);
    $app->{no_print_body} = 1;
    $app->set_header("Content-Disposition" => "attachment; filename=sphinx.conf");
    $app->send_http_header ('text/plain');
    $app->print ($str);
}

sub start_indexer {
    my $plugin = shift;
    my $sphinx_path = $plugin->get_config_value ('sphinx_path', 'system') or return "Sphinx path is not set";

    my $sphinx_conf = $plugin->get_config_value ('sphinx_conf_path', 'system') or return "Sphinx conf path is not set";
    my $indexer_binary = File::Spec->catfile ($sphinx_path, 'indexer');
    my $str = `$indexer_binary --quiet --config $sphinx_conf --all --rotate`;
    
    my $return_code = $? / 256;
    return $str if ($return_code);
    return undef;
}

sub check_searchd {
    my $plugin = shift;
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
    
    my $bin_path = $plugin->get_config_value ('sphinx_path', 'system') or return "Sphinx path is not set";
    my $conf_path = $plugin->get_config_value ('sphinx_conf_path', 'system') or return "Sphinx conf path is not set";
    my $file_path = $plugin->get_config_value ('sphinx_file_path', 'system') or return "Sphinx file path is not set";
    
    # Check for lock files and nix them if they exist
    # it's assumed that searchd is *not* running when this function is called
    foreach my $source (keys %indexes) {
        my $lock_path = File::Spec->catfile ($file_path, $source . '_index.spl');
        if (-f $lock_path) {
            unlink $lock_path;
        }
    }
    
    my $searchd_path = File::Spec->catfile ($bin_path, 'searchd');
    
    my $out = `$searchd_path --config $conf_path`;
    my $return_code = $? / 256;
    
    return $out if ($return_code);
    return undef;
}

sub sphinx_init {
    my $plugin = shift;
    my ($class, %params) = @_;
    
    my $datasource = $class->datasource;

    return if (exists $indexes{ $datasource });
    
    my $props = $class->properties;

    my $primary_key = $props->{primary_key};
    my $defs = $class->column_defs;
    my $columns = [ grep { $_ ne $primary_key } keys %$defs ];
    if ($params{include_columns}) {
        my $includes = { map { $_ => 1} @{$params{include_columns}} };
        $columns = [ grep {exists $includes->{$_}} @$columns ];
    }
    elsif ($params{exclude_columns}) {
        my $excludes = { map { $_ => 1 } @{$params{exclude_columns}} };
        $columns = [ grep { !exists $excludes->{$_} } @$columns ];
    }
    my $id_column = $params{id_column} || $primary_key;
    $indexes{ $datasource } = {
        id_column   => $id_column,
        columns     => $columns,
    };
    $indexes{ $datasource }->{class} = $class;
    $indexes{ $datasource }->{delta} = $params{delta};
    
    if (exists $defs->{ blog_id }) {
        $indexes{ $datasource }->{ group_columns }->{ blog_id }++;
    }
    
    if (exists $params{group_columns}) {
        $indexes{ $datasource }->{ group_columns }->{$_}++ foreach (@{$params{group_columns}});
    }
    
    if ($props->{audit}) {
        $indexes{$datasource}->{date_columns}->{'created_on'}++;
        $indexes{$datasource}->{date_columns}->{'modified_on'}++;
    }
    
    if (exists $params{date_columns}) {
        $indexes{$datasource}->{date_columns}->{$_}++ foreach (ref ($params{date_columns}) eq 'HASH' ? keys %{$params{date_columns}} : @{$params{date_columns}});
    }
    
    if (exists $params{select_values}) {
        $indexes{ $datasource }->{select_values} = $params{select_values};
    }    
    
    if (exists $params{mva}) {
        $indexes{ $datasource }->{mva} = $params{mva};
    }
    
    if ($class->isa ('MT::Taggable')) {
        require MT::Tag;
        require MT::ObjectTag;
        # if it's taggable, setup the MVA bits
        $indexes{ $datasource }->{ mva }->{ tag } = {
            to      => 'MT::Tag',
            with    => 'MT::ObjectTag',
            by      => [ 'object_id', 'tag_id' ],
            select_values   => { object_datasource => $datasource },
        };
    }
    
    $indexes{ $datasource }->{id_to_obj} = $params{id_to_obj} || sub { $class->load ($_[0]) };
}

sub _process_extended_sort {
    my $plugin = shift;
    my ($class, $sort_string) = @_;
    
    my $datasource = $class->datasource;
    
    $sort_string =~ s/(?<!@)\b(\w+)\b(?!(?:,|$))/${datasource}_$1/gi;    
    $sort_string;
}


sub sphinx_search {
    my $plugin = shift;
    my ($classes, $search, %params) = @_;

    my @classes;
    if (ref $classes) {
        @classes = @$classes;
    }
    else {
        @classes = ($classes);
    }

    # I'm sure there's a better way to do this bit
    # but it's working for now
    my $class;
    my $datasource;
    for my $c (reverse @classes) {
        $class = $c;
        $datasource = $class->datasource;
        return () if (!exists $indexes{ $datasource });
    }
        
    my $spx = _get_sphinx();
    
    if (exists $params{Filters}) {
        foreach my $filter (keys %{ $params{Filters} }) {
            $spx->SetFilter($filter, $params{Filters}{$filter});
        }
    }
    
    if (exists $params{RangeFilters}) {
        foreach my $filter (keys %{ $params{RangeFilters} }) {
            $spx->SetFilterRange ($filter, @{$params{RangeFilters}->{$filter}});
        }
    }
    
    if (exists $params{Sort}) {
        exists $params{Sort}->{Ascend}      ?   $spx->SetSortMode (Sphinx::SPH_SORT_ATTR_ASC, $params{Sort}->{Ascend}) :
        exists $params{Sort}->{Descend}     ?   $spx->SetSortMode (Sphinx::SPH_SORT_ATTR_DESC, $params{Sort}->{Descend}) :
        exists $params{Sort}->{Segments}    ?   $spx->SetSortMode (Sphinx::SPH_SORT_TIME_SEGMENTS, $params{Sort}->{Segments}) :
        exists $params{Sort}->{Extended}    ?   $spx->SetSortMode (Sphinx::SPH_SORT_EXTENDED, $plugin->_process_extended_sort ($class, $params{Sort}->{Extended})) :
                                                $spx->SetSortMode (Sphinx::SPH_SORT_RELEVANCE);
    }
    else {
        # Default to explicitly setting the sort mode to relevance
        $spx->SetSortMode (Sphinx::SPH_SORT_RELEVANCE);
    }
    
    if (exists $params{Match}) {
        my $match = $params{Match};
        $match eq 'extended'? $spx->SetMatchMode (Sphinx::SPH_MATCH_EXTENDED):
        $match eq 'boolean' ? $spx->SetMatchMode (Sphinx::SPH_MATCH_BOOLEAN) :
        $match eq 'phrase'  ? $spx->SetMatchMode (Sphinx::SPH_MATCH_PHRASE)  :
        $match eq 'any'     ? $spx->SetMatchMode (Sphinx::SPH_MATCH_ANY)     :
                              $spx->SetMatchMode (Sphinx::SPH_MATCH_ALL);
    }
    else {
        $spx->SetMatchMode (Sphinx::SPH_MATCH_ALL);
    }
    
    my $offset = 0;
    my $limit = 200;
    if (exists $params{Offset}) {
        $offset = $params{Offset};
    }
    
    if (exists $params{Limit}) {
        $limit = $params{Limit};
    }
    
    $spx->SetLimits ($offset, $limit);
    
    my $results = $spx->Query ($search, join ( ' ', map { my $ds = $_->datasource; $ds . '_index' . ( $indexes{$ds}->{delta} ? " ${ds}_delta_index" : '' ) } @classes ) );
    if (!$results) {
        MT->instance->log ({
            message => "Error querying searchd daemon: " . $spx->GetLastError,
            level   => MT::Log::ERROR(),
            class   => 'search',
            category    => 'straight_search',
        });
        return ();
    }

    my @result_objs = ();
    my $meth = $indexes{ $datasource }->{id_to_obj} or die "No id_to_obj method for $datasource";
    foreach my $match (@{$results->{ matches }}) {
        my $id = $match->{ doc };
        my $o = $meth->($id) or next;
        push @result_objs, $o;
    }
    
    return @result_objs if wantarray;
    return {
        result_objs     => [ @result_objs ],
        query_results   => $results,
    };
    
}

sub search_results_page_loop_container_tag {
    my ($ctx, $args, $cond) = @_;
    
    require MT::Request;
    my $r = MT::Request->instance;
    my $number_pages = $r->stash ('sphinx_pages_number');
    my $current_page = $r->stash ('sphinx_pages_current');
    my $limit        = $r->stash ('sphinx_pages_limit');
    my $builder = $ctx->stash ('builder');
    my $tokens  = $ctx->stash ('tokens');
    
    my $res = '';
    my $glue = $args->{glue} || '';
    foreach my $page (1 .. $number_pages) {
        local $ctx->{__stash}{sphinx_page_number} = $page;
        # offset is 0 for page 1, limit for page 2, limit * 2 for page 3, ...
        local $ctx->{__stash}{sphinx_pages_offset} = ($page - 1) * $limit;
        defined (my $out = $builder->build ($ctx, $tokens, {
            %$cond,
            IfCurrentSearchResultsPage => ($page == $current_page),
        })) or return $ctx->error ($builder->errstr);
        $res .= $glue if $res ne '';
        $res .= $out;
    }
    $res;
}

sub search_results_limit_tag {
    my ($ctx, $args) = @_;
    
    require MT::Request;
    my $r = MT::Request->instance;
    
    return $r->stash ('sphinx_pages_limit') || 0;
}

sub search_results_offset_tag {
    my ($ctx, $args) = @_;
    
    my $offset = $ctx->stash ('sphinx_pages_offset');
    return $offset if defined $offset;
    
    require MT::Request;
    my $r = MT::Request->instance;
    return $r->stash ('sphinx_pages_offset') || 0;
}

sub search_results_page_tag {
    my ($ctx, $args) = @_;
    my $page_number = $ctx->stash ('sphinx_page_number');
    return $page_number if $page_number;
    
    require MT::Request;
    my $r = MT::Request->instance;
    return $r->stash ('sphinx_pages_current') || 0;
}

sub search_sort_mode_tag {
    my ($ctx, $args) = @_;
    
    require MT::App;
    my $app = MT::App->instance;
    my $mode = $app->param ('sort_mode') || 'descend';
    return $mode;
}

sub search_match_mode_tag {
    my ($ctx, $args) = @_;
    
    require MT::App;
    my $app = MT::App->instance;
    my $mode = $app->param ('match_mode') || 'all';
    return $mode;
}

sub if_current_search_results_page_conditional_tag {
    $_[2]->{IfCurrentSearchResultsPage};
}

sub if_multiple_search_results_pages_conditional_tag {
    require MT::Request;
    my $r = MT::Request->instance;
    my $number_pages = $r->stash ('sphinx_pages_number');
    return $number_pages > 1;
}

sub search_result_excerpt_tag {
    my ($ctx, $args) = @_;
    
    my $entry = $ctx->stash ('entry') or return $ctx->_no_entry_error ('MTSearchResultExcerpt');
    
    require MT::App;
    my $app = MT::App->instance;
    my $search_string = $app->{search_string};
    my $words = $plugin->get_config_value ('search_excerpt_words', 'system');
    
    require MT::Util;
    TEXT_FIELD:
    for my $text ($entry->text, $entry->text_more) {
        $text = MT::Util::remove_html ($text);
        if ($text && $text =~ /(((([\w']+)\b\W*){0,$words})$search_string\b\W*((([\w']+)\b\W*){0,$words}))/ims) {
            my ($excerpt, $pre, $post) = ($1, $2, $5);
            $excerpt =~ s{($search_string)}{<b>$1</b>}ig;
            $entry->excerpt ($excerpt);
            last TEXT_FIELD;
        }    
    }
        
    my ($handler) = $ctx->handler_for ('EntryExcerpt');
    return $handler->($ctx, $args);
}

sub search_all_result_tag {
    require MT::App;
    MT::App->instance->param ('searchall');
}

1;
