
use strict;
use warnings;

use lib 't/lib', 'lib', 'extlib';

use Test::More tests => 5;
use MT::Test;
use MT;

ok( MT->component('sphinxsearch'), "Plugin loaded" );
require_ok('SphinxSearch::Search');
require_ok('SphinxSearch::Sphinxable');
require_ok('SphinxSearch::Config');
require_ok('SphinxSearch::Index');
