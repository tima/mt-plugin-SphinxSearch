#############################################################################
# Copyright © 2006-2010 Six Apart Ltd.
# This program is free software: you can redistribute it and/or modify it
# under the terms of version 2 of the GNU General Public License as published
# by the Free Software Foundation, or (at your option) any later version.
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# version 2 for more details.  You should have received a copy of the GNU
# General Public License version 2 along with this program. If not, see
# <http://www.gnu.org/licenses/>

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
