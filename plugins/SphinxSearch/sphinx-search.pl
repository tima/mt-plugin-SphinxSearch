
package MT::Plugin::SphinxSearch;

use strict;
use warnings;

use base qw( MT::Plugin );

use MT;

use vars qw( $VERSION $plugin );
$VERSION = '0.1';
$plugin = MT::Plugin::SphinxSearch->new ({
        name    => 'SphinxSearch',
        description => 'A search script using the sphinx search engine for MySQL',
        version     => $VERSION,

        author_name => 'Apperceptive, LLC',
        author_link => 'http://www.apperceptive.com/',

        });
MT->add_plugin ($plugin);
