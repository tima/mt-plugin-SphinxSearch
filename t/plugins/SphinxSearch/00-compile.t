
use Test::More tests => 1;

# plugin assumes this, thanks to MT
use lib 'plugins/SphinxSearch/lib';
require_ok( 'plugins/SphinxSearch/sphinx-search.pl');