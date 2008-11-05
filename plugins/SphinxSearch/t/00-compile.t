use File::Spec;
BEGIN {
    my $mt_home = $ENV{MT_HOME} || '';
    unshift @INC, File::Spec->catdir ($mt_home, 'lib'), File::Spec->catdir ($mt_home, 'extlib');
}

use Test::More tests => 1;

# plugin assumes this, thanks to MT
use lib 'plugins/SphinxSearch/lib';
require_ok( 'plugins/SphinxSearch/sphinx-search.pl');
