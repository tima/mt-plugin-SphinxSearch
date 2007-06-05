
package MT::Plugin::SphinxSearch;

use strict;
use warnings;

use base qw( MT::Plugin );

use MT;
use Sphinx;
use File::Spec;

use vars qw( $VERSION $plugin );
$VERSION = '0.7';
$plugin = MT::Plugin::SphinxSearch->new ({
        name    => 'SphinxSearch',
        description => 'A search script using the sphinx search engine for MySQL',
        version     => $VERSION,

        author_name => 'Apperceptive, LLC',
        author_link => 'http://www.apperceptive.com/',

        system_config_template  => 'system_config.tmpl',
        settings    => MT::PluginSettings->new ([
            [ 'sphinx_path', { Default => undef, Scope => 'system' }],
            [ 'sphinx_conf_path', { Default => undef, Scope => 'system' }],
            [ 'searchd_host', { Default => 'localhost', Scope => 'system' }],
            [ 'searchd_port', { Default => 3312, Scope => 'system' }],
            [ 'searchd_pid_path', { Default => '/var/log/searchd.pid', Scope => 'system' } ],
            ]),
        
        tasks   => {
            'sphinx_indexer'    => {
                name    => 'Sphinx Indexer',
                frequency   => 60 * 60,
                code        => sub { $plugin->sphinx_indexer_task (@_) },
            }
        },
        
        init_app    => \&init_apps,
        
        app_methods => {
            'MT::App::CMS'  => {
                'gen_sphinx_conf'  => \&gen_sphinx_conf,
            },
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
MT::Entry->sphinx_init (select_values => { status => MT::Entry::RELEASE });
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
    }

}

sub _get_sphinx {
    my $spx = Sphinx->new;
    $spx->SetServer($plugin->get_config_value ('searchd_host', 'system'), $plugin->get_config_value ('searchd_port', 'system'));

    return $spx;
}

sub straight_sphinx_search {
    my $app = shift;
    return 1 unless $app->{search_string} =~ /\S/;

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

    require MT::Entry;
    my $search_keyword = $app->{search_string};
    my @results = MT::Entry->sphinx_search ($search_keyword, Filters => { blog_id => [ keys %{ $app->{ searchparam }{ IncludeBlogs } } ] });
    my(%blogs, %hits);
    my $max = $app->{searchparam}{MaxResults};
    foreach my $o (@results) {
        my $blog_id = $o->blog_id;
                
        if ($hits{$blog_id} && $hits{$blog_id} >= $max) {
            my $blog = $blogs{$blog_id} || MT::Blog->load($blog_id);
            my @res = @{ $app->{results}{$blog->name} };
            my $count = $#res;
            $res[$count]{maxresults} = $max;
            next;
        }
        
        $app->_store_hit_data ($o->blog, $o, $hits{$blog_id}++);
    }
    1;
}

sub gen_sphinx_conf {
    my $app = shift;
    
    my $tmpl = $plugin->load_tmpl ('sphinx.conf.tmpl');
    my %params;
    
    $params{searchd_port} = $plugin->get_config_value ('searchd_port', 'system');
    
    $params{ db_host } = $app->{cfg}->DBHost;
    $params{ db_user } = $app->{cfg}->DBUser;
    $params{ db_pass } = $app->{cfg}->DBPassword;
    $params{  db_db  } = $app->{cfg}->Database;
    $params{ tmp } = $app->{cfg}->TempDir;
    $params{ pid_file } = $plugin->get_config_value ('searchd_pid_path', 'system');
 
    my %info_query;
    my %query;
    foreach my $source (keys %indexes) {
        $query{$source} = "SELECT " . join(", ", map { 
            $indexes{$source}->{date_columns}->{$_} ? 'UNIX_TIMESTAMP(' . $source . '_' . $_ . ') as ' . $source . '_' . $_ : $source . '_' . $_
            } ( $indexes{$source}->{ id_column }, @{ $indexes{$source}->{ columns } } ) ) . 
            " FROM mt_$source";
        if (my $sel_values = $indexes{$source}->{select_values}) {
            $query{$source} .= " WHERE " . join (" AND ", map { "${source}_$_ = \"" . $sel_values->{$_} . "\""} keys %$sel_values);
        }
        $info_query{$source} = "SELECT * from mt_$source where ${source}_" . $indexes{$source}->{ id_column } . ' = $id';
    }
    $params{ source_loop } = [
        map {
                {
                 source => $_,
                 query  => $query{$_},
                 info_query => $info_query{$_},
                 group_loop    => [ map { { group_column => $_ } } @{$indexes{$_}->{group_columns}} ],
                 date_loop  => [ map { { date_column => $_ } } keys %{$indexes{$_}->{date_columns}} ],
                } 
        }
        keys %indexes
    ];
    
    $app->{no_print_body} = 1;
    $app->set_header("Content-Disposition" => "attachment; filename=sphinx.conf");
    $app->send_http_header ('text/plain');
    $app->print ($app->build_page ($tmpl, \%params));
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
    my $pid_path = $plugin->get_config_value ('searchd_pid_path', 'system');
    
    open my $pid_file, "<", $pid_path or return undef;
    local $/ = undef;
    my $pid = <$pid_file>;
    close $pid_file;
    
    return $pid;
}


sub start_searchd {
    my $plugin = shift;
    
    my $bin_path = $plugin->get_config_value ('sphinx_path', 'system') or return "Sphinx path is not set";
    my $conf_path = $plugin->get_config_value ('sphinx_conf_path', 'system') or return "Sphinx conf path is not set";
    
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
    $indexes{ $datasource } = {
        id_column   => $primary_key,
        columns     => [ grep { $_ ne $primary_key } keys %$defs ],
    };
    
    if (exists $defs->{ blog_id }) {
        push @{$indexes{ $datasource }->{ group_columns }}, 'blog_id';
    }
    
    if (exists $params{group_columns}) {
        push @{$indexes{ $datasource }->{ group_columns }}, grep { $_ ne 'blog_id' } @{$params{group_columns}};
    }
    
    if ($props->{audit}) {
        $indexes{$datasource}->{date_columns}->{'created_on'}++;
        $indexes{$datasource}->{date_columns}->{'modified_on'}++;
    }
    
    if (exists $params{date_columns}) {
        $indexes{$datasource}->{date_columns}->{$_}++ foreach (keys %{$params{date_columns}});
    }
    
    if (exists $params{select_values}) {
        $indexes{ $datasource }->{select_values} = $params{select_values};
    }    
}

sub sphinx_search {
    my $plugin = shift;
    my ($class, $search, %params) = @_;
    
    my $datasource = $class->datasource;
    
    return () if (!exists $indexes{ $datasource });
    
    my $spx = _get_sphinx();
    
    if (exists $params{Filters}) {
        foreach my $filter (keys %{ $params{Filters}}) {
            $spx->SetFilter($datasource . '_' . $filter, $params{Filters}{$filter});
        }
    }
    
    my $results = $spx->Query ($search, $datasource . '_index');
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
    foreach my $match (@{$results->{ matches }}) {
        my $id = $match->{ doc };
        my $o = $class->load ($id) or next;
        push @result_objs, $o;
    }
    
    return @result_objs;
    
}




1;
