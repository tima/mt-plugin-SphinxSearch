
use strict;
use warnings;

use lib 't/lib', 'lib', 'extlib';

use Test::More tests => 23;
use Test::Deep;

use MT::Test qw ( :cms );

# my $mt = MT::App->instance or die MT::App->errstr;

my $plugin = MT::Plugin::SphinxSearch->instance;
ok( $plugin, "Unable to load the plugin instance" );

require_ok('SphinxSearch::Index');

my %indexes = $plugin->sphinx_indexes;

sub check_indexes {
    my ( $params, $indexes, $name ) = @_;

    require SphinxSearch::Index;
    my @indexes = SphinxSearch::Index->which_indexes(%$params);

    for my $i (@$indexes) {
        ok( ( scalar grep { /^$i$/ } @indexes ), "$name contains $i" );
    }
}

ok( exists $indexes{entry}, "Unable to find entry index information" );

is( scalar SphinxSearch::Index->which_indexes,
    0, "No parameters to which_indexes should return empty list" );

check_indexes(
    { Indexer => 'all' },
    [qw( entry_index entry_delta_index comment_index comment_delta_index )],
    "All indexer indexes"
);

check_indexes(
    { Indexer => 'main' },
    [qw( comment_index entry_index )],
    "Main indexer indexes"
);

check_indexes(
    { Indexer => 'delta' },
    [qw( entry_delta_index comment_delta_index )],
    "Delta indexer indexes"
);

my @unknown_indexer_indexes =
  SphinxSearch::Index->which_indexes( Indexer => 'unknown' );
ok( !@unknown_indexer_indexes, "Unknown indexer indexes" );

check_indexes(
    { Source => 'entry' },
    [qw( entry_index entry_delta_index )],
    "Entry source indexes"
);

check_indexes(
    { Source => 'MT::Entry' },
    [qw( entry_index entry_delta_index )],
    "Entry class source indexes"
);

check_indexes(
    { Source => ['entry'] },
    [qw( entry_index entry_delta_index )],
    "Entry array source indexes"
);

check_indexes(
    { Source => [qw( entry comment )] },
    [qw( entry_index entry_delta_index comment_index comment_delta_index )],
    "Entry and comment source indexes"
);
