
use lib qw( t/lib lib extlib );
use strict;
use warnings;

use List::Util qw( min );

BEGIN {
    $ENV{MT_APP} = 'MT::App::Search';
}

use MT::Test qw( :app :db :data );
use Test::More tests => 6;

require MT::Template;
my $tmpl = MT::Template->get_by_key(
    {
        blog_id    => 0,
        identifier => 'search_results',
        name       => 'Search Results',
        type       => 'system'
    }
);
$tmpl->text('Search Results!!! Error = <mt:var name="error">.');
$tmpl->save or die $tmpl->errstr;

# gotta make sure we go somewhere funny, in case sphinx *is* running
my $p = MT->component('sphinxsearch');
$p->set_config_value( 'searchd_port', '9999', 'system' );

out_like(
    'MT::App::Search',
    { search => 'stuff', IncludeBlogs => 1 },
qr/\QError querying searchd: connection to {localhost}:{9999} failed: Connection refused\E/,
    "When searchd isn't available, return a useful error"
);

{
    local $SIG{__WARN__} = sub { };

    # temp. nix the sphinx searching,
    # since we're not testing that part of the plugin
    require Sphinx::Search;
    my $orig_exec = \&Sphinx::Search::Query;
    *Sphinx::Search::Query = sub {
        my $max_matches = shift->{_limit};
        require MT::Entry;
        my $total_found =
          MT::Entry->count( { status => MT::Entry::RELEASE() } );
        my @entries = MT::Entry->load( { status => MT::Entry::RELEASE() },
            { ( $max_matches ? ( limit => $max_matches ) : () ) } );
        my $total = min( scalar @entries, $total_found );
        return {
            matches     => [ map { { doc => $_->id } } @entries ],
            total       => $total,
            total_found => $total_found,
        };
    };
}
$tmpl->text(
    "Search string: <mt:searchstring>\nSearch count: <mt:searchresultcount>\n<mt:searchresults>Entry #<mt:entryid>\n</mt:searchresults>");
$tmpl->save or die $tmpl->errstr;

# we have to search for a known tag
out_like(
    'MT::App::Search',
    { tag => 'rain' },
    qr/Search string: rain/,
    "mt:searchstring works correctly for a tag search"
);

out_like(
    'MT::App::Search',
    { search => 'some search string' },
    qr/Search string: some search string/,
    "mt:searchstring works for a straight search"
);

my $count = MT::Entry->count( { status => MT::Entry::RELEASE() } );
out_like(
    'MT::App::Search',
    { tag => 'rain' },
    qr/Search count: $count/,
    "Returned all the entries"
);

require MT::Session;
MT::Session->remove( { kind => 'CS' } );

require MT::Object;
MT::Object->driver->clear_cache;

out_like(
    'MT::App::Search',
    { tag => 'rain', max_matches => 2, limit => 2 },
    qr/Search count: $count\n(?:Entry #(?:\d+)\n){2}$/m,
    "CGI max_matches parameter"
);

out_like(
    'MT::App::Search',
    { searchall => 1 },
    qr/Search count: $count/,
    "Using searchall works"
);
