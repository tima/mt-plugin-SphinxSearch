
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

    require MT::Log;
    my $blog_id;
    if ($app->{searchparam}{IncludeBlogs} && scalar (keys %{ $app->{searchparam}{IncludeBlogs} }) == 1) {
        ($blog_id) = keys %{ $app->{searchparam}{IncludeBlogs}};
    }
    
    $app->log({
        message => $app->translate("Search: query for '[_1]'",
              $app->{search_string}),
        level => MT::Log::INFO(),
        class => 'search',
        category => 'straight_search',
        $blog_id ? (blog_id => $blog_id) : ()
    });

    my $spx = _get_sphinx;

    my $search_keyword = $app->{search_string};
    my $results = $spx->Query ($search_keyword,'entry_index');
    return 1 unless ($results);

    require MT::Entry;
    my(%blogs, %hits);
    my $max = $app->{searchparam}{MaxResults};
    foreach my $match (@{$results->{matches}}) {
        my $id = $match->{doc};
        next if ($id > 10000000);
        my $o = MT::Entry->load ($id);
                
        next if ($app->{searchparam}{IncludeBlogs} && !exists $app->{searchparam}{IncludeBlogs}{$o->blog_id});
        next if $hits{$o->blog_id} && $hits{$o->blog_id} >= $max;
        
        $app->_store_hit_data ($o->blog, $o, $hits{$o->blog_id});
    }
    1;
}

1;
