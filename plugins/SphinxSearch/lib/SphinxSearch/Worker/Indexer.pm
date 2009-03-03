
package SphinxSearch::Worker::Indexer;

use strict;
use warnings;

use base qw( TheSchwartz::Worker );

use MT;

sub work {
    my $class = shift;
    my TheSchwartz::Job $job = shift;
        
    my @jobs = ($job);
    if (my $key = $job->coalesce) {
        while (my $job = MT::TheSchwartz->instance->find_job_with_coalescing_value ($class, $key)) {
            push @jobs, $job;
        }
    }
    
    return if (!@jobs);

    my $plugin = MT->component ('SphinxSearch'); 
    if ( !$plugin->check_searchd && $plugin->errstr !~ /no valid indexes to serve/gi ) {
        $_->failed ("Error starting searchd: " . $plugin->errstr) foreach (@jobs);
    }
    else {
        foreach my $job (@jobs) {
            # key is the string 'main', 'delta', or 'all'
            my $key = $job->uniqkey;
            $job->debug ("Starting $key indexing");
            if ($plugin->start_indexer ($key)) {
                $job->debug ("Indexing complete");
                $job->completed ();
            }
            else {
                $job->failed ("Error starting indexer: " . $plugin->errstr);
            }
        }        
    }
}

sub grab_for { 60 * 30 } # grab for half an hour, this might take a while
sub max_retries { 20 }
sub retry_delay {
	my $failures = shift;
	unless ( $failures && ($failures + 0) ) { # Non-zero digit
		return 600;
	}
	return 600 if $failures < 10;
	return 1800 if $failures < 15;
	return 60 * 60 * 12;
}



1;
