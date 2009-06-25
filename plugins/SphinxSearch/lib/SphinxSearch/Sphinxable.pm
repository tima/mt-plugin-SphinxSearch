
package SphinxSearch::Sphinxable;

use strict;
use warnings;

use Sphinx::Search;

use MT::Util qw( encode_xml );

# sub sphinx_header {
#     my $class = shift;
#     my $defs = $class->column_defs;
#
#     my $innards = '';
#     while (my ($k, $v) = each (%$defs)) {
#         if ($v->{type} =~ /datetime|timestamp/) {
#             $innards .= qq{<sphinx:attr name="$k" time="timestamp" />\n};
#         }
#         else {
#             $innards .= qq{<sphinx:field name="$k" />\n};
#         }
#     }
#
#     my $res = qq{<sphinx:schema>
# $innards
# </sphinx:schema>
# };
# }
#
# sub to_sphinx_xml {
#     my $obj = shift;
#
#     my $vals = $obj->get_values;
#     my $id = delete $vals->{$obj->properties->{primary_key}};
#     my $defs = $obj->column_defs;
#
#     $vals = { %$vals, %{$obj->meta} };
#
#     my $innards = join ("\n", map { "<$_>" . encode_xml ($vals->{$_}) . "</$_>" } keys %$vals );
#     my $res = qq{
# <sphinx:document id="$id">
# $innards
# </sphinx:document>
# };
#     return $res;
# }

sub sphinx_search {
    my $class = shift;
    my ( $classes, $search, %params ) = @_;
    $search ||= '';

    my @classes;
    if ( ref $classes ) {
        @classes = @$classes;
    }
    else {
        @classes = ($classes);
    }

    # I'm sure there's a better way to do this bit
    # but it's working for now
    my $datasource;

    require SphinxSearch::Index;
    my %indexes = %{ SphinxSearch::Index::_get_sphinx_indexes() };
    if ( my $indexes = $params{Indexes} ) {
        $datasource = $indexes->[0];
        @classes    = @$indexes;
    }
    else {
        for my $c ( reverse @classes ) {
            $class      = $c;
            $datasource = $class->datasource;
            return () if ( !exists $indexes{$datasource} );
        }
    }
    require SphinxSearch::Util;
    my $spx = SphinxSearch::Util::_get_sphinx();

    my $text_filters = $params{TextFilters};
    if ( exists $params{Filters} ) {
        foreach my $filter ( keys %{ $params{Filters} } ) {
            next
              unless ( ref( $params{Filters}->{$filter} ) eq 'ARRAY'
                && scalar @{ $params{Filters}{$filter} } );
            if ($text_filters) {
                my $filter_str;
                if (
                    scalar @{
                        $params{Filters}{$filter};
                    } == 1
                  )
                {
                    $filter_str = join( '_',
                        $datasource, $filter, $params{Filters}{$filter}->[0] );
                }
                elsif ( $text_filters > 1
                    && scalar @{ $params{Filters}{$filter} } > 1 )
                {
                    $filter_str = '('
                      . join( '|',
                        map { join( '_', $datasource, $filter, $_ ) }
                          @{ $params{Filters}{$filter} } )
                      . ')';
                }
                else {
                    $spx->SetFilter( $filter, $params{Filters}{$filter} );
                }

                $search = join( ' ', ( $search ? ($search) : () ), $filter_str )
                  if ($filter_str);
            }
            else {
                $spx->SetFilter( $filter, $params{Filters}{$filter} );
            }
        }
    }

    if ( exists $params{SFilters} ) {
        require String::CRC32;
        foreach my $filter ( keys %{ $params{SFilters} } ) {
            if ($text_filters) {
                my $filter_str;
                if (
                    scalar @{
                        $params{SFilters}{$filter};
                    } == 1
                  )
                {
                    $filter_str = join( '_',
                        $datasource, $filter, $params{SFilters}{$filter}->[0] );
                }
                elsif ( $text_filters > 1
                    && scalar @{ $params{SFilters}{$filter} } > 1 )
                {
                    $filter_str = '('
                      . join( '|',
                        map { join( '_', $datasource, $filter, $_ ) }
                          @{ $params{SFilters}{$filter} } )
                      . ')';
                }
                else {
                    $spx->SetFilter(
                        $filter . '_crc32',
                        [
                            map { String::CRC32::crc32($_) }
                              @{ $params{SFilters}{$filter} }
                        ]
                    );
                }

                $search = join( ' ', ( $search ? ($search) : () ), $filter_str )
                  if ($filter_str);
            }
            else {
                $spx->SetFilter(
                    $filter . '_crc32',
                    [
                        map { String::CRC32::crc32($_) }
                          @{ $params{SFilters}{$filter} }
                    ]
                );
            }
        }
    }

    if ( exists $params{RangeFilters} ) {
        foreach my $filter ( keys %{ $params{RangeFilters} } ) {
            $spx->SetFilterRange( $filter,
                @{ $params{RangeFilters}->{$filter} } );
        }
    }

    if ( exists $params{Sort} ) {
        exists $params{Sort}->{Ascend}
          ? $spx->SetSortMode( SPH_SORT_ATTR_ASC, $params{Sort}->{Ascend} )
          : exists $params{Sort}->{Descend}
          ? $spx->SetSortMode( SPH_SORT_ATTR_DESC, $params{Sort}->{Descend} )
          : exists $params{Sort}->{Segments}
          ? $spx->SetSortMode( SPH_SORT_TIME_SEGMENTS,
            $params{Sort}->{Segments} )
          : exists $params{Sort}->{Extended}
          ? $spx->SetSortMode( SPH_SORT_EXTENDED, $params{Sort}->{Extended} )
          : $spx->SetSortMode(SPH_SORT_RELEVANCE);
    }
    else {

        # Default to explicitly setting the sort mode to relevance
        $spx->SetSortMode(SPH_SORT_RELEVANCE);
    }

    if ( exists $params{Match} ) {
        my $match = $params{Match};
        $match eq 'extended'
          || $text_filters > 1 ? $spx->SetMatchMode(SPH_MATCH_EXTENDED)
          : $match eq 'boolean' ? $spx->SetMatchMode(SPH_MATCH_BOOLEAN)
          : $match eq 'phrase'  ? $spx->SetMatchMode(SPH_MATCH_PHRASE)
          : $match eq 'any'     ? $spx->SetMatchMode(SPH_MATCH_ANY)
          :                       $spx->SetMatchMode(SPH_MATCH_ALL);
    }
    else {
        $spx->SetMatchMode(SPH_MATCH_ALL);
    }

    if ( exists $params{Select} ) {
        $spx->SetSelect( $params{Select} );
    }

    if ( exists $params{GroupBy} ) {
        exists $params{GroupBy}->{Attribute}
          ? $spx->SetGroupBy( $params{GroupBy}->{Attribute},
            SPH_GROUPBY_ATTR, $params{GroupBy}->{Sort} )
          : exists $params{GroupBy}->{Day}
          ? $spx->SetGroupBy( $params{GroupBy}->{Day},
            SPH_GROUPBY_DAY, $params{GroupBy}->{Sort} )
          : exists $params{GroupBy}->{Week}
          ? $spx->SetGroupBy( $params{GroupBy}->{Week},
            SPH_GROUPBY_WEEK, $params{GroupBy}->{Sort} )
          : exists $params{GroupBy}->{Month}
          ? $spx->SetGroupBy( $params{GroupBy}->{Month},
            SPH_GROUPBY_MONTH, $params{GroupBy}->{Sort} )
          : exists $params{GroupBy}->{Year}
          ? $spx->SetGroupBy( $params{GroupBy}->{Year},
            SPH_GROUPBY_YEAR, $params{GroupBy}->{Sort} )
          : die "Unknown group by";

        $spx->SetGroupDistinct( $params{GroupBy}->{Distinct} )
          if ( exists $params{GroupBy}->{Distinct} );
    }

    my $offset = 0;
    my $limit  = 200;
    my $max    = 0;
    if ( exists $params{Offset} ) {
        $offset = $params{Offset};
    }

    if ( exists $params{Limit} ) {
        $limit = $params{Limit};
    }

    if ( exists $params{Max} ) {
        $max = $params{Max};
    }

    # if offset is beyond max, set max to
    # include this page and the next
    if ( ( $offset + $limit ) >= $max ) {
        $max = $offset + ( 2 * $limit );
    }

    $spx->SetLimits( $offset, $limit, $max );

    require SphinxSearch::Index;
    my $indexes =
      join( ' ', SphinxSearch::Index->which_indexes( Source => [@classes] ) );
    my $results;
    my $reconnects     = 0;
    my $max_reconnects = MT->config->SphinxSearchdMaxReconnects;
    do {
        $results = $spx->Query( $search, $indexes );
        if (   !$results
            || ( $results->{error} )
            || ( $results->{warning} && MT->config->SphinxErrorOnWarning ) )
        {
            if ( $spx->IsConnectError() ) {
                while ( $reconnects++ < $max_reconnects ) {
                    $spx->Close();
                    last if ( $spx->Open() );
                }
            }
            else {
                my $errstr =
                  $results
                  ? ( $results->{error} || $results->{warning} )
                  : ( $spx->GetLastError || $spx->GetLastWarning );
                require MT::Request;
                MT::Request->instance->stash( 'sphinx_error', $errstr );
                MT->instance->log(
                    {
                        message  => "Error querying searchd daemon: " . $errstr,
                        level    => MT::Log::ERROR(),
                        class    => 'search',
                        category => 'straight_search',
                    }
                );
                return ();
            }
        }

    } while ( !$results && $reconnects < $max_reconnects );

    if (  !$results
        || $results->{error}
        || ( $results->{warning} && MT->config->SphinxErrorOnWarning ) )
    {
        my $errstr =
          $results
          ? ( $results->{error} || $results->{warning} )
          : ( $spx->GetLastError || $spx->GetLastWarning );
        require MT::Request;
        MT::Request->instance->stash( 'sphinx_error',
                "unable to connect after $max_reconnects retries (" 
              . $errstr
              . ")" );
        MT->instance->log(
            {
                message =>
"Error querying searchd daemon: unable to connect after $max_reconnects retries ("
                  . $errstr . ")",
                level    => MT::Log::ERROR(),
                class    => 'search',
                category => 'straight_search',
            }
        );
        return ();
    }

    warn "SPHINX WARNING: " . ($results->{warning} || $spx->GetLastWarning) if ($results->{warning});
    my $meth       = $indexes{$datasource}->{id_to_obj};
    my $multi_meth = $indexes{$datasource}->{ids_to_objs}
      or die "No ids_to_objs method for $datasource";
    my $i = 0;

    my @ids = map { $_->{doc} } @{ $results->{matches} };
    my @objs = $meth ? ( map { $meth->($_) } @ids ) : ( $multi_meth->(@ids) );
    @objs = grep { defined $_ } @objs;
    $_->{__sphinx_result_index} = sprintf( "%04d", $i++ ) foreach (@objs);

    return @objs if wantarray;
    return {
        result_objs   => [@objs],
        query_results => $results,
    };

}

sub sphinx_init {
    my ( $class, %params ) = @_;
    my $datasource = $class->datasource;
    my $index_name = $params{index} || $datasource;

    require SphinxSearch::Index;
    my $indexes = SphinxSearch::Index::_get_sphinx_indexes();
    return if ( exists $indexes->{$index_name} );

    my $index_hash = {};

    my $props = $class->properties;

    my $primary_key  = $props->{primary_key};
    my $defs         = $class->column_defs;
    my $columns      = [ grep { $_ ne $primary_key } keys %$defs ];
    my $columns_hash = { map { $_ => 1 } @$columns };
    if ( $params{include_columns} ) {
        my $includes = { map { $_ => 1 } @{ $params{include_columns} } };
        $columns = [ grep { exists $includes->{$_} } @$columns ];
    }
    elsif ( $params{exclude_columns} ) {
        my $excludes = { map { $_ => 1 } @{ $params{exclude_columns} } };
        $columns = [ grep { !exists $excludes->{$_} } @$columns ];
    }
    my $id_column = $params{id_column} || $primary_key;
    $index_hash = {
        id_column => $id_column,
        columns   => $columns,
    };
    $index_hash->{class}         = $class;
    $index_hash->{delta}         = $params{delta};
    $index_hash->{stash}         = $params{stash};
    $index_hash->{count_columns} = $params{count_columns};

    if ( exists $defs->{blog_id} ) {
        $index_hash->{group_columns}->{blog_id} = 'blog_id';
    }

    if ( exists $props->{indexes} ) {

        # push all the indexes that are actual columns
        push @{ $params{group_columns} },
          grep { $columns_hash->{$_} } keys %{ $props->{indexes} };
    }

    if ( exists $params{group_columns} ) {
        for my $column ( @{ $params{group_columns} } ) {
            next
              if ( $column eq $id_column )
              ; # skip if this is the id column, don't need to group on it after all
            my $name;
            if ( 'HASH' eq ref($column) ) {
                ( $column, $name ) = each(%$column);
            }
            else {
                $name = $column;
            }
            my $col_type = $defs->{$column}->{type};
            if ( $col_type =~ /^(datetime|timestamp)/ ) {

        # snuck in from indexes, we should push it into the date columns instead
                $params{date_columns}->{$column} = 1;
            }
            else {
                $index_hash->{
                    $defs->{$column}->{type} =~ /^(string|text)$/
                    ? 'string_group_columns'
                    : 'group_columns'
                  }->{$column} = $name;
            }
        }
    }

    if ( $props->{audit} ) {
        $index_hash->{date_columns}->{'created_on'}++;
        $index_hash->{date_columns}->{'modified_on'}++;

        $index_hash->{delta} = 'modified_on' if ( !$index_hash->{delta} );
    }

    if ( exists $params{date_columns} ) {
        $index_hash->{date_columns}->{$_}++ foreach (
            ref( $params{date_columns} ) eq 'HASH'
            ? keys %{ $params{date_columns} }
            : @{ $params{date_columns} }
        );
    }

    if ( exists $params{select_values} ) {
        $index_hash->{select_values} = $params{select_values};
    }

    if ( exists $params{mva} ) {
        $index_hash->{mva} = $params{mva};
    }

    if ( $class->isa('MT::Taggable') ) {
        require MT::Tag;
        require MT::ObjectTag;

        # if it's taggable, setup the MVA bits
        $index_hash->{mva}->{tag} = {
            to            => 'MT::Tag',
            with          => 'MT::ObjectTag',
            by            => [ 'object_id', 'tag_id' ],
            select_values => { object_datasource => $datasource },
        };
    }

    if ( $params{include_meta} ) {
        require MT::Meta;
        my @metadata = MT::Meta->metadata_by_class($class);
        my $meta_pkg = $class->meta_pkg;
        for my $meta_field (@metadata) {
            next
              unless ( $meta_field->{type} =~ /integer/ );
            $index_hash->{mva}->{ "meta_" . $meta_field->{name} } = {
                with => $meta_pkg,
                by   => [ $class->datasource . '_id', $meta_field->{type} ],
                select_values => { type => $meta_field->{name} },
            };
        }
    }

    # only explicit id_to_obj methods will be respected
    $index_hash->{id_to_obj} = $params{id_to_obj};

    # || sub { $class->load( $_[0] ) };
    $index_hash->{ids_to_objs} = $params{ids_to_objs}
      || sub { @{ $class->lookup_multi( \@_ ) } };
    $indexes->{$index_name} = $index_hash;
}

sub sphinx_result_index {
    return shift->{__sphinx_result_index};
}

1;
