
use lib qw( t/lib lib extlib );
use strict;
use warnings;

use Data::Dumper;
use List::Util qw( min );

BEGIN {
    $ENV{MT_APP} = 'MT::App::Search';
}

use MT::Test qw( :app :db :data );
use Test::More tests => 30;
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

MT->instance->config->SphinxSearchdPort(9999);
out_like(
    'MT::App::Search',
    { search => 'stuff', IncludeBlogs => 1 },
qr/\QError opening persistent connection to searchd: Failed to open connection to localhost:9999: Connection refused\E/,
    "When searchd isn't available, return a useful error"
);

my %filters;
my $warning = '';
my $error   = '';
my $search  = '';
my $opened  = 0;
my $closed  = 0;

my $is_conn_error = 0;
{
    local $SIG{__WARN__} = sub { };

    # temp. nix the sphinx searching,
    # since we're not testing that part of the plugin
    require Sphinx::Search;
    my $orig_exec = \&Sphinx::Search::Query;
    *Sphinx::Search::Query = sub {
        my $self = shift;
        $self->{_connerror} = $is_conn_error;
        $is_conn_error-- if ($is_conn_error);
        return if ( $self->{_connerror} );
        my $max_matches = $self->{_limit};
        %filters = ();
        $search  = $_[0];
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

    *Sphinx::Search::Open  = sub { $opened++; 1; };
    *Sphinx::Search::Close = sub { $closed++; 1; };
}
$tmpl->text(
"Search string: <mt:searchstring>\nSearch count: <mt:searchresultcount>\n<mt:searchresults>Entry #<mt:entryid>\n</mt:searchresults>"
);
$tmpl->save or die $tmpl->errstr;

require MT::Session;

# we have to search for a known tag
out_like(
    'MT::App::Search',
    { tag => 'rain' },
    qr/Search string: rain/,
    "mt:searchstring works correctly for a tag search"
);

MT::Session->remove( { kind => 'CS' } );
out_like(
    'MT::App::Search',
    { search => 'some search string' },
    qr/Search string: some search string/,
    "mt:searchstring works for a straight search"
);

MT::Session->remove( { kind => 'CS' } );
my $count = MT::Entry->count( { status => MT::Entry::RELEASE() } );
out_like(
    'MT::App::Search',
    { tag => 'rain' },
    qr/Search count: $count/,
    "Returned all the entries"
);

MT::Session->remove( { kind => 'CS' } );

require MT::Object;
MT::Object->driver->clear_cache;

out_like(
    'MT::App::Search',
    { tag => 'rain', max_matches => 2, limit => 2 },
    qr/Search count: $count\n(?:Entry #(?:\d+)\n){2}$/m,
    "CGI max_matches parameter"
);

MT::Session->remove( { kind => 'CS' } );
out_like(
    'MT::App::Search',
    { searchall => 1 },
    qr/Search count: $count/,
    "Using searchall works"
);

# now to verify the filter bits

MT::Session->remove( { kind => 'CS' } );
_run_app( 'MT::App::Search',
    { searchall => 1, author => 'Bob D', use_text_filters => 0 } );
cmp_bag( $filters{author_id}, [3], "Author filter works as expected" );
is( $search, '', "Author filter does not set search string" );

MT::Session->remove( { kind => 'CS' } );
_run_app( 'MT::App::Search', { tag => 'rain', use_text_filters => 0 } );
cmp_bag( $filters{tag}, [2], "Tag filter works as expected" );
is( $search, '', "Tag filter does not set search string" );

MT::Session->remove( { kind => 'CS' } );
_run_app(
    'MT::App::Search',
    {
        searchall        => 1,
        category         => 'subfoo',
        blog_id          => 1,
        use_text_filters => 0
    }
);
cmp_bag( $filters{category}, [3], "Category filter works as expected" );
is( $search, '', "Category filter does not set search string" );

MT::Session->remove( { kind => 'CS' } );
_run_app( 'MT::App::Search',
    { searchall => 1, author => 'Bob D', use_text_filters => 1 } );
ok( !$filters{author_id}, "Author filter works as expected" );
like( $search, qr/entry_author_id_3/, "Author filter sets search string" );

MT::Session->remove( { kind => 'CS' } );
_run_app( 'MT::App::Search', { tag => 'rain', use_text_filters => 1 } );
ok( !$filters{tag}, "Tag filter works as expected" );
like( $search, qr/entry_tag_2/, "Tag filter sets search string" );

MT::Session->remove( { kind => 'CS' } );
_run_app(
    'MT::App::Search',
    {
        searchall        => 1,
        category         => 'subfoo',
        blog_id          => 1,
        use_text_filters => 1
    }
);
ok( !$filters{category}, "Category filter works as expected" );
like(
    $search,
    qr/^(?:entry_(?:category_3|blog_id_1)\s*){2}$/,
    "Category filter sets search string"
);

print "ABOUT TO RUN THE TF2 test!\n";

require MT::Object;
MT::Object->driver->clear_cache;
MT::Session->remove( { kind => 'CS' } );
_run_app(
    'MT::App::Search',
    {
        searchall        => 1,
        category         => 'foo,subfoo',
        blog_id          => 1,
        use_text_filters => 1
    }
);
cmp_bag( $filters{category}, [ 1, 3 ],
    "TF1 Category filter works as expected" );
ok( !$filters{blog_id}, "TF1 Blog filter works as expected" );
unlike(
    $search,
    qr/\Q(entry_category_1|entry_category_3)\E/,
    "TF1 Category filter does not set search string"
);

like( $search, qr/entry_blog_id_1/, "TF1 Blog filter sets search string" );

MT::Session->remove( { kind => 'CS' } );
my $a = _run_app(
    'MT::App::Search',
    {
        searchall        => 1,
        category         => 'foo,subfoo',
        blog_id          => 1,
        use_text_filters => 2
    }
);

ok( !$filters{category}, "TF2 Category filter works as expected" );
ok( !$filters{blog_id},  "TF2 Blog filter works as expected" );
like(
    $search,
    qr/\Q(entry_category_1|entry_category_3)\E/,
    "TF2 Category filter sets search string"
);
like( $search, qr/entry_blog_id_1/, "TF2 Blog filter sets search string" );

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

MT::Session->remove( { kind => 'CS' } );
MT::Object->driver->clear_cache;

$warning       = '';
$is_conn_error = 15;

out_like(
    'MT::App::Search',
    { tag => 'rain' },
    qr/Error querying searchd: unable to connect after 3 retries/,
    "Exceeding maximum retries"
);

MT::Session->remove( { kind => 'CS' } );
MT::Object->driver->clear_cache;

$is_conn_error = 2;

out_like(
    'MT::App::Search',
    { tag => 'rain' },
    qr/Search string: rain/,
    "Did not exceed maximum retries"
);

1;
