
package SphinxSearch::Sphinxable;

use strict;
use warnings;

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
    my ($classes, $search, %params) = @_;
	$search ||= '';
	
    my @classes;
    if (ref $classes) {
        @classes = @$classes;
    }
    else {
        @classes = ($classes);
    }

    # I'm sure there's a better way to do this bit
    # but it's working for now
    my $datasource;
    
    require SphinxSearch::Index;
    my %indexes = %{SphinxSearch::Index::_get_sphinx_indexes()};
    if (my $indexes = $params{Indexes}) {
        $datasource = $indexes->[0];
        @classes = @$indexes;
    }
    else {
        for my $c (reverse @classes) {
            $class = $c;
            $datasource = $class->datasource;
            return () if (!exists $indexes{ $datasource });
        }        
    }
    require SphinxSearch::Util;
    my $spx = SphinxSearch::Util::_get_sphinx();
    
    if (exists $params{Filters}) {
        foreach my $filter (keys %{ $params{Filters} }) {
			next unless (ref ($params{Filters}->{$filter}) eq 'ARRAY' && scalar @{$params{Filters}{$filter}});
            $spx->SetFilter($filter, $params{Filters}{$filter});
        }
    }
    
    if (exists $params{SFilters}) {
        require String::CRC32;
        foreach my $filter (keys %{ $params{SFilters} }) {
            $spx->SetFilter ($filter . '_crc32', [ map { String::CRC32::crc32 ($_) } @{$params{SFilters}{$filter}} ] );
        }
    }
    
    if (exists $params{RangeFilters}) {
        foreach my $filter (keys %{ $params{RangeFilters} }) {
            $spx->SetFilterRange ($filter, @{$params{RangeFilters}->{$filter}});
        }
    }
    
    if (exists $params{Sort}) {
        exists $params{Sort}->{Ascend}      ?   $spx->SetSortMode (Sphinx::SPH_SORT_ATTR_ASC, $params{Sort}->{Ascend}) :
        exists $params{Sort}->{Descend}     ?   $spx->SetSortMode (Sphinx::SPH_SORT_ATTR_DESC, $params{Sort}->{Descend}) :
        exists $params{Sort}->{Segments}    ?   $spx->SetSortMode (Sphinx::SPH_SORT_TIME_SEGMENTS, $params{Sort}->{Segments}) :
        exists $params{Sort}->{Extended}    ?   $spx->SetSortMode (Sphinx::SPH_SORT_EXTENDED, $params{Sort}->{Extended}) :
                                                $spx->SetSortMode (Sphinx::SPH_SORT_RELEVANCE);
    }
    else {
        # Default to explicitly setting the sort mode to relevance
        $spx->SetSortMode (Sphinx::SPH_SORT_RELEVANCE);
    }
    
    if (exists $params{Match}) {
        my $match = $params{Match};
        $match eq 'extended'? $spx->SetMatchMode (Sphinx::SPH_MATCH_EXTENDED):
        $match eq 'boolean' ? $spx->SetMatchMode (Sphinx::SPH_MATCH_BOOLEAN) :
        $match eq 'phrase'  ? $spx->SetMatchMode (Sphinx::SPH_MATCH_PHRASE)  :
        $match eq 'any'     ? $spx->SetMatchMode (Sphinx::SPH_MATCH_ANY)     :
                              $spx->SetMatchMode (Sphinx::SPH_MATCH_ALL);
    }
    else {
        $spx->SetMatchMode (Sphinx::SPH_MATCH_ALL);
    }
    
    my $offset = 0;
    my $limit  = 200;
    my $max    = 0;
    if (exists $params{Offset}) {
        $offset = $params{Offset};
    }
    
    if (exists $params{Limit}) {
        $limit = $params{Limit};
    }
    
    if (exists $params{Max}) {
        $max = $params{Max};
    }
    
    $spx->SetLimits ($offset, $limit, $max);
    
    require SphinxSearch::Index;
    my $results = $spx->Query ($search, join ( ' ', SphinxSearch::Index->which_indexes (Source => [ @classes ] ) ) );
    if (!$results) {
        MT->instance->log ({
            message => "Error querying searchd daemon: " . $spx->GetLastError,
            level   => MT::Log::ERROR(),
            class   => 'search',
            category    => 'straight_search',
        });
        return ();
    }

    my @result_objs = ();
    my $meth = $indexes{ $datasource }->{id_to_obj} or die "No id_to_obj method for $datasource";
    foreach my $match (@{$results->{ matches }}) {
        my $id = $match->{ doc };
        my $o = $meth->($id) or next;
        push @result_objs, $o;
    }
    
    return @result_objs if wantarray;
    return {
        result_objs     => [ @result_objs ],
        query_results   => $results,
    };
    
}

sub sphinx_init {
    my ($class, %params) = @_;
    my $datasource = $class->datasource;
    my $index_name = $params{index} || $datasource;

    require SphinxSearch::Index;
    my $indexes = SphinxSearch::Index::_get_sphinx_indexes();
    return if (exists $indexes->{ $index_name });
    
    my $index_hash = {};
    
    my $props = $class->properties;

    my $primary_key = $props->{primary_key};
    my $defs = $class->column_defs;
    my $columns = [ grep { $_ ne $primary_key } keys %$defs ];
    my $columns_hash = { map { $_ => 1 } @$columns };
    if ($params{include_columns}) {
        my $includes = { map { $_ => 1} @{$params{include_columns}} };
        $columns = [ grep {exists $includes->{$_}} @$columns ];
    }
    elsif ($params{exclude_columns}) {
        my $excludes = { map { $_ => 1 } @{$params{exclude_columns}} };
        $columns = [ grep { !exists $excludes->{$_} } @$columns ];
    }
    my $id_column = $params{id_column} || $primary_key;
    $index_hash = {
        id_column   => $id_column,
        columns     => $columns,
    };
    $index_hash->{class} = $class;
    $index_hash->{delta} = $params{delta};
    $index_hash->{stash} = $params{stash};
    $index_hash->{count_columns} = $params{count_columns};
    
    if (exists $defs->{ blog_id }) {
        $index_hash->{ group_columns }->{ blog_id } = 'blog_id';
    }
    
    if (exists $props->{indexes}) {
        # push all the indexes that are actual columns
        push @{$params{group_columns}}, grep { $columns_hash->{$_} } keys %{$props->{indexes}};
    }
    
    if (exists $params{group_columns}) {
        for my $column (@{$params{group_columns}}) {
            next if ($column eq $id_column); # skip if this is the id column, don't need to group on it after all
            my $name;
            if ('HASH' eq ref ($column)) {
                ($column, $name) = each (%$column);
            }
            else {
                $name = $column;
            }
            my $col_type = $defs->{$column}->{type};
            if ($col_type =~ /^(datetime|timestamp)/) {
                # snuck in from indexes, we should push it into the date columns instead
                $params{date_columns}->{$column} = 1;
            }
            else {                
                $index_hash->{ $defs->{$column}->{type} =~ /^(string|text)$/ ? 'string_group_columns' : 'group_columns' }->{$column} = $name;
            }
        }
    }

    if ($props->{audit}) {
        $index_hash->{date_columns}->{'created_on'}++;
        $index_hash->{date_columns}->{'modified_on'}++;
        
        $index_hash->{delta} = 'modified_on' if (!$index_hash->{delta});
    }
    
    if (exists $params{date_columns}) {
        $index_hash->{date_columns}->{$_}++ foreach (ref ($params{date_columns}) eq 'HASH' ? keys %{$params{date_columns}} : @{$params{date_columns}});
    }
    
    if (exists $params{select_values}) {
        $index_hash->{select_values} = $params{select_values};
    }    
    
    if (exists $params{mva}) {
        $index_hash->{mva} = $params{mva};
    }
    
    if ($class->isa ('MT::Taggable')) {
        require MT::Tag;
        require MT::ObjectTag;
        # if it's taggable, setup the MVA bits
        $index_hash->{ mva }->{ tag } = {
            to      => 'MT::Tag',
            with    => 'MT::ObjectTag',
            by      => [ 'object_id', 'tag_id' ],
            select_values   => { object_datasource => $datasource },
        };
    }
    
    $index_hash->{id_to_obj} = $params{id_to_obj} || sub { $class->load ($_[0]) };
    $indexes->{$index_name} = $index_hash;
}

sub sphinx_result_index {
    return shift->{__sphinx_result_index};
}

1;
