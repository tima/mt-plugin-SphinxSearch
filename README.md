# SphinxSearch

The SphinxSearch plugin enhances the search feature in Movable Type by adding
extensive support for full-text indices. It integrates the Sphinx server with
Movable Type to provide full-text searches across various objects in Movable
Type.

## What is Sphinx?

Sphinx is a full-text search engine, distributed under GPL version 2.
Generally, it's a standalone search engine, meant to provide fast,
size-efficient and relevant full-text search functions to other applications.

Currently built-in data source drivers support fetching data either via direct
connection to MySQL, or from a pipe in a custom XML format.

The native Sphinx search API is available for PHP, Python, Perl, Ruby, Java
amongst other programming languages. As the Movable Type core is primarily
written in Perl, the plugin uses the Perl API via the corresponding CPAN
module to communicate with the Sphinx search service.
