
package SphinxSearch::Util;

use strict;
use warnings;

use Sphinx::Search;

use MT::Request;
# my $spx;

sub _reset_sphinx {
    # undef $spx;
}

sub _get_sphinx {
    my $spx = MT::Request->instance->stash ('sphinx_obj');
    require Sphinx::Search;
    return $spx if $spx;
    $spx = Sphinx::Search->new;
    require MT;
    my $plugin = MT->component('sphinxsearch');
    $spx->SetServer(
        $plugin->get_config_value( 'searchd_host', 'system' ),
        $plugin->get_config_value( 'searchd_port', 'system' )
    );
    MT::Request->instance->stash ('sphinx_obj', $spx);
    return $spx;
}

sub _get_sphinx_error {
    # return unless $spx;
    my $spx = _get_sphinx();
    $spx->GetLastError();
}

1;
