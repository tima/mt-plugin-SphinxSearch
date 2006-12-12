
package SphinxSearch::App;

use strict;
use warnings;

use base qw( MT::App );

use Sphinx;

sub init {
    my $app = shift;
    $app->SUPER::init (@_) or return;

    $app->add_methods (
            sphinx_search   => \&sphinx_search,
            );
    $app->{ default_mode } = 'sphinx_search';
    $app;
}

sub sphinx_search {
    my $app = shift;

    return "This is the search function";
}

1;
