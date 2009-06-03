
package SphinxSearch::Util;

use strict;
use warnings;

use Sphinx::Search;

# my $spx;

sub _reset_sphinx {

    # undef $spx;
}

sub _get_sphinx {
    require MT;
    my $spx = MT->instance->{__sphinx_obj};
    if ($spx) {
        $spx->ResetFilters();
        $spx->ResetOverrides();
        $spx->ResetGroupBy();
        return $spx;
    }
    require Sphinx::Search;
    $spx = Sphinx::Search->new;
    require MT;

    my ( $host, $port ) =
      ( MT->config->SphinxSearchdHost, MT->config->SphinxSearchdPort );

    if ( !( $host && $port ) ) {
        my $plugin = MT->component('sphinxsearch');
        $host = $plugin->get_config_value( 'searchd_host', 'system' )
          if ( !$host );
        $port = $plugin->get_config_value( 'searchd_port', 'system' )
          if ( !$port );
    }
    $spx->SetServer( $host, $port );
    $spx->SetEncoders( sub { shift }, sub { shift } );

    $spx->Open() or die "Error opening persistent connection to searchd: " . $spx->GetLastError();
    MT->instance->{__sphinx_obj} = $spx;

    return $spx;
}

sub _get_sphinx_error {
    require MT::Request;
    return MT::Request->instance->cache('sphinx_error');
}

1;
