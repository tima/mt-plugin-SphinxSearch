use lib qw( t/lib lib extlib );

use strict;
use warnings;

BEGIN {
    $ENV{MT_APP} = 'MT::App::Search';
}

use MT::Test qw( :app :db :data );
use Test::More tests => 1;

my @searches = ({ search => 'stuff' }, { searchall => 1 });

sub get_cgi {
    my $params = shift @searches;
    return unless $params;
    require CGI;
    my $cgi = CGI->new;
    while (my ($k, $v) = each %$params) {
        $cgi->param ($k, $v);
    }
    
    $cgi;
}


my $app;

while (my $cgi = get_cgi()) {
    $app = MT::App::Search->new (CGIObject => $cgi);
    local $SIG{__WARN__} = sub { $app->trace($_[0]) };
    MT->set_instance($app);
    $app->init_request(CGIObject => $cgi);
    $app->run;
}

isnt ($app->{search_string}, 'stuff', "Search string is stuck");
