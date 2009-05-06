
use lib qw( t/lib lib extlib );
use strict;
use warnings;

use List::Util qw( min );

BEGIN {
    $ENV{MT_APP} = 'MT::App::Search';
}

use MT::Test qw( :app :db :data );
use Test::More tests => 11;
use Test::Deep;

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

my %filters;
my $warning = '';
my $error = '';
{
    local $SIG{__WARN__} = sub { };

    # temp. nix the sphinx searching,
    # since we're not testing that part of the plugin
    require Sphinx::Search;
    my $orig_exec = \&Sphinx::Search::Query;
    *Sphinx::Search::Query = sub {
        my $self        = shift;
        my $max_matches = $self->{_limit};
        %filters = ();
        for my $f ( @{ $self->{_filters} } ) {
            $filters{ $f->{attr} } = $f->{values};
        }
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
            ( $error   ? ( error   => $error )   : () ),
            ( $warning ? ( warning => $warning ) : () )
        };
    };
}
$tmpl->text(
"Search string: <mt:searchstring>\nSearch count: <mt:searchresultcount>\n<mt:searchresults>Entry #<mt:entryid>\n</mt:searchresults>"
);
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

# now to verify the filter bits

_run_app( 'MT::App::Search', { searchall => 1, author => 'Bob D' } );
cmp_bag( $filters{author_id}, [3], "Author filter works as expected" );

_run_app( 'MT::App::Search', { tag => 'rain' } );
cmp_bag( $filters{tag}, [2], "Tag filter works as expected" );

_run_app( 'MT::App::Search', { searchall => 1, category => 'subfoo' } );
cmp_bag( $filters{category}, [3], "Category filter works as expected" );

MT::Session->remove( { kind => 'CS' } );
MT::Object->driver->clear_cache;

$error = "This is my error";
out_like(
    'MT::App::Search',
    { tag => 'rain' },
    qr/This is my error/,
    "Error is exposed"
);

MT::Session->remove( { kind => 'CS' } );
MT::Object->driver->clear_cache;

$error   = '';
$warning = 'This is my warning';

out_like(
    'MT::App::Search',
    { tag => 'rain' },
    qr/This is my warning/,
    "Warning is exposed"
);

1;
