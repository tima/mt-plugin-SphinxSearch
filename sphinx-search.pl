
package MT::Plugin::SphinxSearch;

use strict;
use warnings;

use base qw( MT::Plugin );

use MT;
use Sphinx;
use File::Spec;

use vars qw( $VERSION $plugin );
$VERSION = '0.3';
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
            ]),
        
        tasks   => {
            'sphinx_indexer'    => {
                name    => 'Sphinx Indexer',
                frequency   => 60 * 60,
                code        => \&sphinx_indexer_task,
            }
        },
        
        init_app    => {
            'MT::App::Search'   => \&init_search_app,
        },

});
MT->add_plugin ($plugin);

sub sphinx_indexer_task {
    my $task = shift;

    my $sphinx_path = $plugin->get_config_value ('sphinx_path', 'system');
    if (!$sphinx_path) {
        my $app = MT->instance;
        $app->log ('Sphinx path is not set');
        return;
    }

    my $sphinx_conf = $plugin->get_config_value ('sphinx_conf_path',
            'system');
    if (!$sphinx_conf) {
        my $app = MT->instance;
        $app->log ('Sphinx conf path is not set');
        return;
    }
    my $indexer_binary = File::Spec->catdir ($sphinx_path, 'indexer');
    my $str = `$indexer_binary --quiet --config $sphinx_conf --all`;
    die $str if ($str);
    1;
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

    my $search_keyword = $app->{search_string};
    my $results = $spx->Query ($search_keyword,'entry_index');
    if (!$results) {
        $app->log ({
            message => "Error querying searchd daemon: " . $spx->GetLastError,
            level   => MT::Log::ERROR(),
            class   => 'search',
            category    => 'straight_search',
        });
        return 1;
    }

    require MT::Entry;
    my(%blogs, %hits);
    my $max = $app->{searchparam}{MaxResults};
    foreach my $match (@{$results->{matches}}) {
        my $id = $match->{doc};
        next if ($id > 10000000);
        my $o = MT::Entry->load ($id);
                
        next if ($app->{searchparam}{IncludeBlogs} && !exists $app->{searchparam}{IncludeBlogs}{$o->blog_id});
        next if $hits{$o->blog_id} && $hits{$o->blog_id} >= $max;
        
        $app->_store_hit_data ($o->blog, $o, $hits{$o->blog_id});
    }
    1;
}


1;