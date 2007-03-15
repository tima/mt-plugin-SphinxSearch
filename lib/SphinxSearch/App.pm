
package SphinxSearch::App;

use strict;
use warnings;

use base qw( MT::App::Search );

use Sphinx;
use Data::Dumper;

{
    local $SIG{__WARN__} = sub { };
    *MT::App::Search::_straight_search = \&_straight_sphinx_search;
}

sub _get_sphinx {
    my $spx = Sphinx->new;
    $spx->SetServer('localhost', 3312);

    return $spx;
}

sub _straight_sphinx_search {
    my $app = shift;
    return 1 unless $app->{search_string} =~ /\S/;

    my $spx = _get_sphinx;

    my $search_keyword = $app->{search_string};
    my $results = $spx->Query ($search_keyword,'entry_index');
    return 1 unless ($results);

    require MT::Entry;

    foreach my $match (@{$results->{matches}}) {
        my $id = $match->{doc};
        next if ($id > 10000000);
        my $o = MT::Entry->load ($id);
        
        $app->_store_hit_data ($o->blog, $o);
    }
    1;
}

1;
