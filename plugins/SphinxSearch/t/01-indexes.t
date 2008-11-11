
use strict;
use warnings;

use lib 't/lib', 'lib', 'extlib';

use Test::More tests => 11;
use Test::Deep;

use MT::Test qw ( :cms );

# my $mt = MT::App->instance or die MT::App->errstr;

my $plugin = MT::Plugin::SphinxSearch->instance;
ok ($plugin, "Unable to load the plugin instance");

my %indexes = $plugin->sphinx_indexes;

ok (exists $indexes{entry}, "Unable to find entry index information");

is (scalar $plugin->which_indexes, 0, "No parameters to which_indexes should return empty list");

my @all_indexer_indexes = $plugin->which_indexes (Indexer => 'all');
cmp_bag (\@all_indexer_indexes, [ qw( entry_index entry_delta_index comment_index comment_delta_index ) ], "All indexer indexes");

my @main_indexer_indexes = $plugin->which_indexes (Indexer => 'main');
cmp_bag (\@main_indexer_indexes, [ qw( comment_index entry_index ) ], "Main indexer indexes");

my @delta_indexer_indexes = $plugin->which_indexes (Indexer => 'delta');
cmp_bag (\@delta_indexer_indexes, [ qw( entry_delta_index comment_delta_index ) ], "Delta indexer indexes");

my @unknown_indexer_indexes = $plugin->which_indexes (Indexer => 'unknown');
ok (!@unknown_indexer_indexes, "Unknown indexer indexes");

my @entry_indexes = $plugin->which_indexes (Source => 'entry');
cmp_bag (\@entry_indexes, [ qw( entry_index entry_delta_index ) ], "Entry source indexes");

my @entry_class_indexes = $plugin->which_indexes (Source => 'MT::Entry');
cmp_bag (\@entry_class_indexes, [ qw( entry_index entry_delta_index ) ], "Entry class source indexes");

my @entry_array_indexes = $plugin->which_indexes (Source => [ 'entry' ]);
cmp_bag (\@entry_array_indexes, [ qw( entry_index entry_delta_index ) ], "Entry array source indexes");

my @entry_and_comment_indexes = $plugin->which_indexes (Source => [ qw( entry comment ) ]);
cmp_bag (\@entry_and_comment_indexes, [ qw( entry_index entry_delta_index comment_index comment_delta_index ) ], "Entry and comment source indexes");