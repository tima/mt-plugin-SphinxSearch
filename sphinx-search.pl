
package MT::Plugin::SphinxSearch;

use strict;
use warnings;

use base qw( MT::Plugin );

use MT;
use File::Spec;

use vars qw( $VERSION $plugin );
$VERSION = '0.1';
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
            ]),
        
        tasks   => {
            'sphinx_indexer'    => {
                name    => 'Sphinx Indexer',
                frequency   => 60 * 60,
                code        => \&sphinx_indexer_task,
            }
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
