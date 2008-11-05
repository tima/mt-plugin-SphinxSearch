
use strict;
use warnings;

use lib 't/lib', 'lib', 'extlib';

use Test::More tests => 1;
use MT::Test;
use MT;

ok (MT->component ('sphinxsearch'), "Plugin loaded");