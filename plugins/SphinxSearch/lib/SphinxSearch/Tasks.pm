
package SphinxSearch::Tasks;

use strict;
use warnings;

sub sphinx_delta_indexer {
    sphinx_indexer_task( 'delta', @_ );
}

sub sphinx_indexer {
    print "pre indexer task call\n";
    sphinx_indexer_task( 'main', @_ );
    print "post indexer task call\n";
}

sub sphinx_indexer_task {
    my $plugin = MT->component('sphinxsearch');
    my $which  = shift;
    my $task   = shift;

    print "pre config check\n";
    return
      unless $plugin->get_config_value( 'use_indexer_tasks', 'system' )
          && MT->config->UseSphinxTasks;
    
    print "past config check\n";

    require MT::TheSchwartz;
    require TheSchwartz::Job;

    my $job = TheSchwartz::Job->new;
    $job->funcname('SphinxSearch::Worker::Indexer');
    $job->uniqkey($which);
    $job->priority(10)
      ; # reindexing is high priority, it should be delayed as little as possible
    MT::TheSchwartz->insert($job) or die MT::TheSchwartz->errstr;

    1;
}

1;
