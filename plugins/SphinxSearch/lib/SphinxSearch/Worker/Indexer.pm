
package SphinxSearch::Worker::Indexer;

use strict;
use warnings;

use base qw( TheSchwartz::Worker );

use MT;
use SphinxSearch::Util;

sub check_searchd {
    my $plugin = shift;

    if ( !_check_searchd($plugin) ) {
        if ( !start_searchd($plugin) ) {
            MT->instance->log( "Error starting searchd: " . $plugin->errstr );
            return $plugin->error(
                "Error starting searchd: " . $plugin->errstr );
        }
    }

    1;
}

sub _check_searchd {
    my $plugin   = shift;
    my $pid_path = SphinxSearch::Util::_pid_path();

    open my $pid_file, "<", $pid_path or return undef;
    local $/ = undef;
    my $pid = <$pid_file>;
    close $pid_file;

    # returns number of process that exist and can be signaled
    # sends a 0 signal, which is meaningless as far as I can tell
    return kill 0, $pid;
}

sub start_searchd {
    my $plugin = shift;

    my $bin_path = $plugin->get_config_value( 'sphinx_path', 'system' )
      or return "Sphinx path is not set";
    my $conf_path = $plugin->get_config_value( 'sphinx_conf_path', 'system' )
      or return "Sphinx conf path is not set";
    my $file_path = $plugin->get_config_value( 'sphinx_file_path', 'system' )
      or return "Sphinx file path is not set";

    # Check for lock files and nix them if they exist
    # it's assumed that searchd is *not* running when this function is called
    require SphinxSearch::Index;
    my %indexes = %{ SphinxSearch::Index::_get_sphinx_indexes() };
    foreach my $source ( keys %indexes ) {
        my $lock_path =
          File::Spec->catfile( $file_path, $source . '_index.spl' );
        if ( -f $lock_path ) {
            unlink $lock_path;
        }
    }

    my $searchd_path = File::Spec->catfile( $bin_path, 'searchd' );

    run_cmd($plugin, "$searchd_path --config $conf_path");
}

sub run_cmd {
    my $plugin      = shift;
    my ($cmd)       = @_;
    my $res         = `$cmd`;
    my $return_code = $? / 256;
    $return_code ? $plugin->error($res) : 1;
}

sub start_indexer {
    my $plugin = shift;
    my ($indexes) = @_;
    $indexes = 'main' if ( !$indexes );
    my $sphinx_path = $plugin->get_config_value( 'sphinx_path', 'system' )
      or return $plugin->error("Sphinx path is not set");

    require SphinxSearch::Index;
    my @indexes = SphinxSearch::Index->which_indexes( Indexer => $indexes );

    return $plugin->error("No indexes to rebuild") if ( !@indexes );

    my $sphinx_conf = $plugin->get_config_value( 'sphinx_conf_path', 'system' )
      or return $plugin->error("Sphinx conf path is not set");
    my $indexer_binary = File::Spec->catfile( $sphinx_path, 'indexer' );
    my $cmd = "$indexer_binary --quiet --config $sphinx_conf --rotate "
      . join( ' ', @indexes );
    run_cmd($plugin,$cmd);
}

sub work {
    my $class = shift;
    my TheSchwartz::Job $job = shift;

    my @jobs = ($job);
    if ( my $key = $job->coalesce ) {
        while (
            my $job = MT::TheSchwartz->instance->find_job_with_coalescing_value(
                $class, $key
            )
          )
        {
            push @jobs, $job;
        }
    }

    return if ( !@jobs );

    my $plugin = MT->component('SphinxSearch');
    if ( !check_searchd($plugin) ) {
        $_->failed( "Error starting searchd: " . $plugin->errstr )
          foreach (@jobs);
    }
    else {
        foreach my $job (@jobs) {

            # key is the string 'main', 'delta', or 'all'
            my $key = $job->uniqkey;
            $job->debug("Starting $key indexing");
            if ( start_indexer( $plugin, $key ) ) {
                $job->debug("Indexing complete");
                $job->completed();
            }
            else {
                $job->failed( "Error starting indexer: " . $plugin->errstr );
            }
        }
    }
}

sub grab_for    { 60 * 30 }    # grab for half an hour, this might take a while
sub max_retries { 20 }

sub retry_delay {
    my $failures = shift;
    unless ( $failures && ( $failures + 0 ) ) {    # Non-zero digit
        return 600;
    }
    return 600  if $failures < 10;
    return 1800 if $failures < 15;
    return 60 * 60 * 12;
}

1;
