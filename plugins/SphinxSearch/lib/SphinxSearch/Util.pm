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

package SphinxSearch::Util;

use strict;
use warnings;

use Sphinx::Search;

# my $spx;

sub _reset_sphinx {

    # undef $spx;
}

sub _get_sphinx {
    require MT;
    my $spx = MT->instance->{__sphinx_obj};
    if ($spx) {
        $spx->ResetFilters();
        $spx->ResetOverrides();
        $spx->ResetGroupBy();

        my $time_since_opened = time - $spx->{_connected_at};
        if ( $time_since_opened > MT->config->SphinxSearchdMaxConnectionAge ) {
            $spx->Close();
            $spx->Open()
              or die "Error opening persistent connection to searchd: "
              . $spx->GetLastError();
        }

        return $spx;
    }
    require Sphinx::Search;
    $spx = Sphinx::Search->new;
    require MT;

    my ( $host, $port ) =
      ( MT->config->SphinxSearchdHost, MT->config->SphinxSearchdPort );

    if ( !( $host && $port ) ) {
        my $plugin = MT->component('sphinxsearch');
        $host = $plugin->get_config_value( 'searchd_host', 'system' )
          if ( !$host );
        $port = $plugin->get_config_value( 'searchd_port', 'system' )
          if ( !$port );
    }
    $spx->SetServer( $host, $port );
    $spx->SetConnectTimeout( MT->config->SphinxSearchdConnectTimeout )
      if ( MT->config->SphinxSearchdConnectTimeout );
    $spx->SetEncoders( sub { shift }, sub { shift } );
    $spx->SetRetries( MT->config->SphinxSearchdAgentRetries );
    $spx->SetReadTimeout(
        MT->config->SphinxSearchdReadTimeout,
        MT->config->SphinxSearchdReadRetries
    );

    $spx->Open()
      or die "Error opening persistent connection to searchd: "
      . $spx->GetLastError();
    MT->instance->{__sphinx_obj} = $spx;

    return $spx;
}

sub _get_sphinx_error {
    require MT::Request;
    return MT::Request->instance->cache('sphinx_error');
}

sub init_sphinxable {
    {
        local $SIG{__WARN__} = sub { };
        require SphinxSearch::Sphinxable;
        push @MT::Object::ISA, 'SphinxSearch::Sphinxable';
    }

    require MT::Entry;
    require MT::Comment;
    MT::Entry->sphinx_init(
        select_values => { status => MT::Entry::RELEASE() },
        group_columns => ['author_id'],
        include_meta  => 1,
        mva           => {
            category => {
                to   => 'MT::Category',
                with => 'MT::Placement',
                by   => [ 'entry_id', 'category_id' ],
            },
        },
        date_columns => { authored_on => 1 }
    );
    MT::Comment->sphinx_init(
        select_values => { visible => 1 },
        group_columns => [ 'entry_id', 'commenter_id' ],
        stash         => 'comments',
        include_meta  => 1,
        mva           => {
            response_to => {
                query =>
'select distinct mt_comment.comment_id, response_to.comment_commenter_id from mt_comment, mt_comment as response_to where mt_comment.comment_entry_id = response_to.comment_entry_id and mt_comment.comment_created_on > response_to.comment_created_on and response_to.comment_commenter_id is not null',
                to     => 'MT::Author',
	            by => [ 'comment_id', 'author_id' ],
                lookup => 'name',
                stash  => [ 'author', 'authors' ],
            },
            entry_basename => {
                to     => 'MT::Entry',
                lookup => 'basename',
                stash  => [ 'entry', 'entries' ],
                with   => 'MT::Comment',
                by     => [ 'id', 'entry_id' ],
            }
        }
    );

    require MT::Tag;
    require MT::ObjectTag;

	MT::Tag->sphinx_init(
	    index         => 'tag',
	    stash         => 'sphinxtags',
	    select_values => { is_private => 0 },
		include_columns => [ 'name' ],
		count_columns => {
			entry_count => {
				what => 'MT::ObjectTag',
				with => 'tag_id',
				select_values => { object_datasource => 'entry' }
			}
		},
	    mva => {
			entry => {
	            to            => 'MT::Entry',
	            with          => 'MT::ObjectTag',
	            by            => [ 'tag_id', 'object_id' ],
	            select_values => { object_datasource => 'entry' },
			},
			category => {
	            to => 'MT::Category',
                lookup => 'id',
                stash  => [ 'category', 'categories' ],

	            by => [ 'tag_id', 'category_id' ],
				# remember to allow for the appendage of the columns defined above: by[0] = object_id i.e. tag_id = object_id.
				# See Config.pm fore more details
				query => 'select distinct tag_id, placement_category_id from mt_tag, mt_objecttag, mt_placement where tag_id = objecttag_tag_id and objecttag_object_id = placement_entry_id'
			},
		}
	);
}

sub init_apps {
    my $cb = shift;
    my ($app) = @_;
    if ( $app->isa('MT::App::Search') ) {
        require SphinxSearch::Search;
        SphinxSearch::Search::init_app( $cb, $app );
    }

}

sub pre_load_template {
    my ( $cb, $params ) = @_;

    # skip out of here if this isn't a search app
    # we don't want to screw anything up
    require MT::App;
    my $app = MT::App->instance;
    return unless ( $app && $app->isa('MT::App::Search') );

    return unless ( my $tmpl_id = $app->param('tmpl_id') );
    if (   'HASH' eq ref( $params->[1] )
        && scalar keys %{ $params->[1] } == 2
        && $params->[1]->{blog_id}
        && $params->[1]->{type} eq 'search_template' )
    {
        $params->[1] = $tmpl_id;
    }
}

sub _pid_path {
    my $plugin = MT->component('sphinxsearch');
    my $pid_file = $plugin->get_config_value( 'searchd_pid_path', 'system' );
    my $sphinx_file_path =
      $plugin->get_config_value( 'sphinx_file_path', 'system' );

    return File::Spec->catfile( $sphinx_file_path, 'searchd.pid' )
      if ($sphinx_file_path);
    return $sphinx_file_path;
}

1;
