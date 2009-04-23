
package SphinxSearch::Config;

use strict;
use warnings;

use List::Util qw( max );

sub _gen_sphinx_conf_tmpl {
    my $plugin = MT->component('sphinxsearch');
    my $tmpl = $plugin->load_tmpl('sphinx.conf.tmpl') or die $plugin->errstr;
    my %params;

    my $app = MT->instance;
    $params{searchd_port} =
      $plugin->get_config_value( 'searchd_port', 'system' );

    $params{db_host} = $plugin->get_config_value( 'db_host', 'system' )
      || $app->{cfg}->DBHost;
    $params{db_user} = $plugin->get_config_value( 'db_user', 'system' )
      || $app->{cfg}->DBUser;
    my $db_pass = $plugin->get_config_value( 'db_pass', 'system' )
      || $app->{cfg}->DBPassword;
    $db_pass =~ s/#/\\#/g if ($db_pass);
    $params{db_pass} = $db_pass;
    $params{db_db}   = $app->{cfg}->Database;
    $params{tmp}     = $app->{cfg}->TempDir;
    $params{file_path} =
         $plugin->get_config_value( 'sphinx_file_path', 'system' )
      || $app->{cfg}->TempDir;
    $params{pid_path} = $plugin->_pid_path;
    $params{morphology} =
      $plugin->get_config_value( 'index_morphology', 'system' ) || 'none';

    require MT::Entry;
    my @num_entries = ();
    my $iter = MT::Entry->count_group_by( { status => MT::Entry::RELEASE() },
        { group => ['blog_id'] } );
    my $entry_count;
    push @num_entries, $entry_count while ( ($entry_count) = $iter->() );
    my $max_entries = scalar @num_entries ? int( 1.5 * max @num_entries ) : 0;
    $params{max_matches} = $max_entries > 1000 ? $max_entries : 1000;

    my %info_query;
    my %delta_query;
    my %delta_pre_query;
    my %query;
    my %mva;
    my %counts;

    require SphinxSearch::Index;
    my %indexes = %{SphinxSearch::Index::_get_sphinx_indexes()};
    foreach my $index ( keys %indexes ) {
        my $index_hash = $indexes{$index};
        my $source     = $index_hash->{class}->datasource;

        # build any count columns first
        if ( my $counts = $index_hash->{count_columns} ) {
            for my $count ( keys %$counts ) {
                my $what_class  = $counts->{$count}->{what};
                my $with_column = $counts->{$count}->{with};
                my $wheres      = $counts->{$count}->{select_values};
                eval("require $what_class;");
                next if ($@);

                my $what_ds = $what_class->datasource;
                my $count_query =
"SELECT count(*) from mt_$what_ds WHERE ${what_ds}_$with_column = ${source}_"
                  . $index_hash->{id_column};
                if ($wheres) {
                    $count_query .= ' AND '
                      . join( ' AND ',
                        map { "${what_ds}_$_ = \"" . $wheres->{$_} . "\"" }
                          keys %$wheres );
                }
                $counts{$index}->{$count} = $count_query;
            }
        }

        $query{$index} = "SELECT " . join(
            ", ",
            map {
                $index_hash->{date_columns}->{$_}
                  ? 'UNIX_TIMESTAMP(' . $source . '_' . $_ . ') as ' . $_
                  : $index_hash->{group_columns}->{$_}
                  ? "${source}_$_ as " . $index_hash->{group_columns}->{$_}
                  : $index_hash->{string_group_columns}->{$_}
                  ? ( $source . '_' . $_, "CRC32(${source}_$_) as ${_}_crc32" )
                  : $counts{$index}->{$_}
                  ? "(" . $counts{$index}->{$_} . ") as $_"
                  : $source . '_'
                  . $_
              } (
                $index_hash->{id_column},
                @{ $index_hash->{columns} },
                keys %{ $counts{$index} }
              )
        ) . " FROM mt_$source";
        if ( my $sel_values = $index_hash->{select_values} ) {
            $query{$index} .= " WHERE "
              . join( " AND ",
                map { "${source}_$_ = \"" . $sel_values->{$_} . "\"" }
                  keys %$sel_values );
        }
        $info_query{$index} =
            "SELECT * from mt_$source where ${source}_"
          . $index_hash->{id_column}
          . ' = $id';

        if ( $index_hash->{mva} ) {
            foreach my $mva ( keys %{ $index_hash->{mva} } ) {
                my $cur_mva = $index_hash->{mva}->{$mva};
                my $mva_query;
                if ( ref($cur_mva) ) {
                    if (!$cur_mva->{query}) {
                        my $mva_source = $cur_mva->{with}->datasource;
                        $mva_query = "SELECT "
                          . join( ', ',
                            map { "${mva_source}_$_" } @{ $cur_mva->{by} } )
                          . " from mt_"
                          . $mva_source;
                        if ( my $sel_values = $cur_mva->{select_values} ) {
                            $mva_query .= " WHERE " . join(
                                " AND ",
                                map {
                                    "${mva_source}_$_ = \""
                                      . $sel_values->{$_} . "\""
                                  } keys %$sel_values
                            );
                        }                        
                    }
                    else {
                        $mva_query = $cur_mva->{query};
                    }
                }
                else {
                    $mva_query = $cur_mva;
                }
                push @{ $mva{$index} },
                  { mva_query => $mva_query, mva_name => $mva };
            }
        }

        if ( my $delta = $index_hash->{delta} ) {
            $delta_query{$index} = $query{$index};
            $delta_query{$index} .=
              $indexes{$index}->{select_values} ? " AND " : " WHERE ";
            if ( exists $index_hash->{date_columns}->{$delta} ) {
                $delta_pre_query{$index} =
                  'set @cutoff = date_sub(NOW(), INTERVAL 36 HOUR)';
                $delta_query{$index} .= "${source}_${delta} > \@cutoff";
            }
        }
    }
    $params{source_loop} = [
        map {
            {
                index        => $_,
                  source     => $indexes{$_}->{class}->datasource,
                  query      => $query{$_},
                  info_query => $info_query{$_},
                  group_loop => [
                    map { { group_column => $_ } } (
                        values %{ $indexes{$_}->{group_columns} },
                        keys %{ $counts{$_} }
                    )
                  ],
                  string_group_loop => [
                    map { { string_group_column => $_ } }
                      keys %{ $indexes{$_}->{string_group_columns} }
                  ],
                  date_loop => [
                    map { { date_column => $_ } }
                      keys %{ $indexes{$_}->{date_columns} }
                  ],
                  delta_pre_query => $delta_pre_query{$_},
                  delta_query     => $delta_query{$_},
                  mva_loop        => $mva{$_} || [],
            }
          }
          keys %indexes
    ];
    $tmpl->param( \%params );
    $tmpl;
}

sub gen_sphinx_conf {
    my $app    = shift;
    my $plugin = MT->component('sphinxsearch');
    my $tmpl   = $plugin->_gen_sphinx_conf_tmpl;

    my $str = $app->build_page($tmpl);
    die $app->errstr if ( !$str );
    $app->{no_print_body} = 1;
    $app->set_header(
        "Content-Disposition" => "attachment; filename=sphinx.conf" );
    $app->send_http_header('text/plain');
    $app->print($str);
}

1;
