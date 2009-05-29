
package SphinxSearch::CMS;

use strict;
use warnings;

use SphinxSearch::Config;

sub gen_sphinx_conf {
    my $app    = shift;
    my $plugin = MT->component('sphinxsearch');
    my $tmpl   = SphinxSearch::Config->_gen_sphinx_conf_tmpl;

    my $str = $app->build_page($tmpl);
    die $app->errstr if ( !$str );
    $app->{no_print_body} = 1;
    $app->set_header(
        "Content-Disposition" => "attachment; filename=sphinx.conf" );
    $app->send_http_header('text/plain');
    $app->print($str);
}

1;
