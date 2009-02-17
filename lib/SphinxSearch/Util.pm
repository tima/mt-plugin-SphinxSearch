
package SphinxSearch::Util;

my $spx;

sub _reset_sphinx {
    undef $spx;
}

sub _get_sphinx {
    require Sphinx;
    return $spx if $spx;
    $spx = Sphinx->new;
    require MT;
    my $plugin = MT->component('sphinxsearch');
    $spx->SetServer(
        $plugin->get_config_value( 'searchd_host', 'system' ),
        $plugin->get_config_value( 'searchd_port', 'system' )
    );

    return $spx;
}

sub _get_sphinx_error {
    return unless $spx;
    $spx->GetLastError();
}

1;
