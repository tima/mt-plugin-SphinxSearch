
package SphinxSearch::Index;

use strict;
use warnings;

my %indexes;

sub _get_sphinx_indexes {
    return \%indexes;
}

sub which_indexes {
    my $class  = shift;
    my $plugin = MT->component('sphinxsearch');
    my %params = @_;
    my @indexes;

    my $use_deltas =
      defined $params{UseDistributed}
      ? !$params{UseDistributed}
      : !MT->config->UseSphinxDistributedIndexes;

    if ( my $indexer = $params{Indexer} ) {
        if ( $indexer eq 'all' ) {
            push @indexes, map {
                     $indexes{$_}->{delta}
                  && $use_deltas ? ( $_ . '_index', $_ . '_delta_index' )
                  : $use_deltas ? ( $_ . '_index' )
                  : ( $_ . '_index_distributed' )
            } keys %indexes;
        }
        elsif ( $indexer eq 'main' ) {
            push @indexes, map { $_ . '_index' } keys %indexes;
        }
        elsif ( $indexer eq 'delta' ) {
            push @indexes, map { $_ . '_delta_index' }
              grep { $indexes{$_}->{delta} } keys %indexes;
        }
    }
    elsif ( my $sources = $params{Source} ) {
        my @sources;
        if ( ref($sources) ) {
            @sources = @$sources;
        }
        else {
            @sources = ($sources);
        }
        @sources = map {
            my $s = $_;
            if ( $s =~ /::/ ) { $s = $s->datasource }
            $s;
        } @sources;
        push @indexes, map {
                 $indexes{$_}->{delta}
              && $use_deltas ? ( $_ . '_index', $_ . '_delta_index' )
              : $use_deltas ? ( $_ . '_index' )
              : ( $_ . '_index_distributed' )
        } @sources;
    }

    return @indexes;
}

1;
