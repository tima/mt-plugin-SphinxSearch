
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
    my $spx = MT::Request->instance->stash('sphinx_obj');
    require Sphinx::Search;
    return $spx if $spx;
    $spx = Sphinx::Search->new;
    require MT;

    my ( $host, $port ) =
      ( MT->config->SphinxSearchdHost, MT->config->SphinxSearchdPort );

    if ( !( $host && $port ) ) {
        my $plugin = MT->component('sphinxsearch');

        $spx->SetServer(
            ( $host || $plugin->get_config_value( 'searchd_host', 'system' ) ),
            ( $port || $plugin->get_config_value( 'searchd_port', 'system' ) ),
        );
        MT::Request->instance->stash( 'sphinx_obj', $spx );
    }

    return $spx;
}

sub _get_sphinx_error {
    require MT::Request;
    return MT::Request->instance->cache('sphinx_error');
}

1;
