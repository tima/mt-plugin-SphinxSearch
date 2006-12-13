
package SphinxSearch::App;

use strict;
use warnings;

use base qw( MT::App );

use Sphinx;
use Data::Dumper;

sub init {
    my $app = shift;
    $app->SUPER::init (@_) or return;

    $app->add_methods (
            sphinx_search   => \&sphinx_search,
            );
    $app->{ default_mode } = 'sphinx_search';
    $app;
}

sub _get_sphinx {
    my $spx = Sphinx->new;
    $spx->SetServer('localhost', 3312);

    return $spx;
}

sub sphinx_search {
    my $app = shift;

    my $spx = _get_sphinx;

    my $search_keyword = $app->param ('keyword');
    my $results = $spx->Query ($search_keyword);

    require MT::Entry;
    require MT::Comment;
    
    my $out = '';
    
    foreach my $match (@{$results->{matches}}) {
        my $id = $match->{doc};
        my $o;
        if ($id > 10000000) {
            $o = MT::Comment->load ($id - 10000000);
        }
        else {
            $o = MT::Entry->load ($id);
        }
        
        $out .= "<pre>".Dumper ($o)."</pre>\n";
        $out .= "<hr />\n";
    }

    return $out;
}

1;
