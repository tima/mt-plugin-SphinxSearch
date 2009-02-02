
use lib qw( t/lib lib extlib );
use strict;
use warnings;

BEGIN {
    $ENV{MT_APP} = 'MT::App::Search';
}

use MT::Test qw( :app :db :data );
use Test::More tests => 1;

require MT::Template;
my $tmpl = MT::Template->get_by_key ({ blog_id => 0, identifier => 'search_results', name => 'Search Results', type => 'system' });
$tmpl->text ('Search Results!!! Error = <mt:var name="error">.');
$tmpl->save or die $tmpl->errstr;

out_like ('MT::App::Search', { search => 'stuff' }, qr/Error querying searchd: received zero-sized searchd response/, "When searchd isn't available, return a useful error");
