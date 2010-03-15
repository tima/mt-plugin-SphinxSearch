For the plugin itself:

* The plugin needs to be configured and sphinx.conf generated (either by the plugin or manually).
* If running for the first time, the indexer needs to be run manually (/path/to/indexer --config /path/to/sphinx.conf --all).
* Either start searchd manually as the web user (/path/to/searchd --config /path/to/sphinx.conf) or let the task start it for you.
* run-periodic-tasks needs to be running to update the indexes (and start searchd automatically if needed).
