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

package SphinxSearch::Tasks;

use strict;
use warnings;

sub sphinx_delta_indexer {
    sphinx_indexer_task( 'delta', @_ );
}

sub sphinx_indexer {
    sphinx_indexer_task( 'main', @_ );
}

sub sphinx_indexer_task {
    my $plugin = MT->component('sphinxsearch');
    my $which  = shift;
    my $task   = shift;

    return
      unless $plugin->get_config_value( 'use_indexer_tasks', 'system' )
          && MT->config->UseSphinxTasks;
    
    require MT::TheSchwartz;
    require TheSchwartz::Job;

    my $job = TheSchwartz::Job->new;
    $job->funcname('SphinxSearch::Worker::Indexer');
    $job->uniqkey($which);
    $job->priority(10)
      ; # reindexing is high priority, it should be delayed as little as possible
    MT::TheSchwartz->insert($job);
    
    1;
}

1;
