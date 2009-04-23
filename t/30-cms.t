
use lib qw( t/lib lib extlib );

use strict;
use warnings;

BEGIN {
    $ENV{MT_APP} = 'MT::App::CMS';
}

use MT::Test qw( :app :db :data );
use Test::More tests => 1;

require MT::Author;
out_like ('MT::App::CMS', {__test_user => MT::Author->load (1), __mode => 'gen_sphinx_conf' }, qr/sql_host/, "CMS-level gen_sphinx_conf works");

1;