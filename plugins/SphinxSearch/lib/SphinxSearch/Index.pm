#############################################################################
# Copyright © 2006-2010 Six Apart Ltd.
# This program is free software: you can redistribute it and/or modify it
# under the terms of version 2 of the GNU General Public License as published
# by the Free Software Foundation, or (at your option) any later version.
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# version 2 for more details.  You should have received a copy of the GNU
# General Public License version 2 along with this program. If not, see
# <http://www.gnu.org/licenses/>

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
