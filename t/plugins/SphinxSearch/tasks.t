use File::Spec;
BEGIN {
    my $mt_home = $ENV{MT_HOME} || '';
    unshift @INC, File::Spec->catdir ($mt_home, 'lib'), File::Spec->catdir ($mt_home, 'extlib');
}

use Test::More tests => 13;
use Test::Exception;
use Test::Deep;

use Sub::Install;

use Data::Dumper;

use strict;
use warnings;

my $fail = 1;
my @args;

use MT::App;
my $mt = MT::App->instance or die MT::App->errstr;


{
    local $SIG{__WARN__} = sub {};
    *MT::Plugin::SphinxSearch::run_cmd = sub {
        @args = @_;
        shift @args; # don't need the first one
        return $fail ? $fail : $_[0]->error ("Testing!");
    };
}

my $plugin = MT::Plugin::SphinxSearch->instance;
ok ($plugin, "Unable to load the plugin instance");

# first, let's test start_indexer
ok ( $plugin->start_indexer, 'start_indexer should return true if launching succeeds' );

$fail = 0;
ok (!$plugin->start_indexer, 'start_indexer should return false if launching fails');

$fail = 1;

$plugin->start_indexer;
my @indexes = grep { /_index/ } split (/\s+/, join (' ' , @args));
cmp_bag (\@indexes, [qw( entry_index comment_index )], "Entry and comment indexes present for unspecified indexer");

$plugin->start_indexer ('delta');
@indexes = grep { /_index/ } split (/\s+/, join (' ' , @args));
cmp_bag (\@indexes, [qw( entry_delta_index comment_delta_index )], "Entry and comment delta indexes present");

$plugin->start_indexer ('all');
@indexes = grep { /_index/ } split (/\s+/, join (' ' , @args));
cmp_bag (\@indexes, [ qw( entry_index entry_delta_index comment_index comment_delta_index )], "All indexes being indexed");

ok (!$plugin->start_indexer ('gobbledeegook'), "start_indexer with garbage argument should return false");

$fail = 0;
throws_ok { $plugin->sphinx_indexer_task ('main') } qr/Error starting [^:]*: Testing!/;

$fail = 1;
lives_ok { $plugin->sphinx_indexer_task ('main') } 'sphinx_indexer_task should live if launching succeeds';

@indexes = grep { /_index/ } split (/\s+/, join (' ' , @args));
cmp_bag (\@indexes, [qw( entry_index comment_index )], "Entry and comment indexes present for sphinx_indexer_task");

$fail = 0;
throws_ok { $plugin->sphinx_indexer_task ('delta') } qr/Error starting [^:]*: Testing!/;

$fail = 1;
lives_ok { $plugin->sphinx_indexer_task ('delta') } 'delta_indexer_task should live if launching succeeds';


@indexes = grep { /_index/ } split (/\s+/, join (' ' , @args));
cmp_bag (\@indexes, [qw( entry_delta_index comment_delta_index )], "Entry and comment delta indexes not present");