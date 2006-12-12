#
# Copyright (c) 2001-2006, Len Kranendonk. All rights reserved.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License. You should have
# received a copy of the GPL license along with this program; if you
# did not, you can find it at http://www.gnu.org/
#

#-------------------------------------------------------------
# Sphinx Perl searchd client API
#-------------------------------------------------------------

package Sphinx;

use strict;
use Carp;
use Socket;
use Data::Dumper;

# known searchd commands
use constant SEARCHD_COMMAND_SEARCH	=> 0;
use constant SEARCHD_COMMAND_EXCERPT	=> 1;

# current client-side command implementation versions
use constant VER_COMMAND_SEARCH		=> 0x101;
use constant VER_COMMAND_EXCERPT	=> 0x100;

# known searchd status codes
use constant SEARCHD_OK			=> 0;
use constant SEARCHD_ERROR		=> 1;
use constant SEARCHD_RETRY		=> 2;

# known match modes
use constant SPH_MATCH_ALL		=> 0;
use constant SPH_MATCH_ANY		=> 1;
use constant SPH_MATCH_PHRASE		=> 2;
use constant SPH_MATCH_BOOLEAN		=> 3;

# known sort modes
use constant SPH_SORT_RELEVANCE		=> 0;
use constant SPH_SORT_DATE_DESC		=> 1;
use constant SPH_SORT_DATE_ASC		=> 2;
use constant SPH_SORT_TIME_SEGMENTS	=> 3;


#-------------------------------------------------------------
# common stuff
#-------------------------------------------------------------

# create a new client object and fill defaults
sub new {
	my $class = shift;
	my $self = {
		_host		=> 'localhost',
		_port		=> 3312,
		_offset		=> 0,
		_limit		=> 20,
		_mode		=> SPH_MATCH_ALL,
		_weights	=> [],
		_groups		=> [],
		_sort		=> SPH_SORT_RELEVANCE,
		_min_id		=> 0,
		_max_id		=> 0xFFFFFFFF,
		_min_ts		=> 0,
		_max_ts		=> 0xFFFFFFFF,
		_min_gid	=> 0,
		_max_gid	=> 0xFFFFFFFF,
		_error		=> '',
		_warning	=> '',
	};
	bless($self, $class);
	return $self;
}

# get last error message (string)
sub GetLastError {
	my $self = shift;
	return $self->{_error};
}

# get last warning message (string)
sub GetLastWarning {
	my $self = shift;
	return $self->{_warning};
}

# set searchd server
sub SetServer {
	my $self = shift;
	my $host = shift;
	my $port = shift;

	croak("host is not defined") unless defined($host);
	croak("port is not defined") unless defined($port);

	$self->{_host} = $host;
	$self->{_port} = $port;
}

#-------------------------------------------------------------

# connect to searchd server

sub _Connect {
	my $self = shift;

	# connect socket
	my $fp;
	socket($fp, PF_INET, SOCK_STREAM, getprotobyname('tcp')) || Carp::croak("socket: ".$!);
	my $dest = sockaddr_in($self->{_port}, inet_aton($self->{_host}));
	connect($fp, $dest);
	
	if($!) {
		$self->{_error} = "connection to {$self->{_host}}:{$self->{_port}} failed: $!";
		return 0;
	}	
	
	# check version
	my $buf = '';
	recv($fp, $buf, 4, 0) eq "" || croak("recv: ".$!);
	my $v = unpack("N*", $buf);
	$v = int($v);
	if($v < 1) {
		close($fp) || croak("close: $!");
		$self->{_error} = "expected searchd protocol version 1+, got version '$v'";
	}

	# All ok, send my version
	send($fp, pack("N", 1),0);
	return $fp;
}

#-------------------------------------------------------------

# get and check response packet from searchd server
sub _GetResponse {
	my $self = shift;
	my $fp = shift;
	my $client_ver = shift;

	my $header;
	recv($fp, $header, 8, 0) eq "" || croak("recv: ".$!);

	my ($status, $ver, $len ) = unpack("n2N", $header);
        my ($chunk, $response);
	while(defined($chunk = <$fp>)) {
		$response .= $chunk;
	}
        close ( $fp );

	# check response
        if ( !$response || length($response) != $len ) {
		$self->{_error} = $len 
			? "failed to read searchd response (status=$status, ver=$ver, len=$len, read=". length($response) . ")"
       			: "received zero-sized searchd response";
		return 0;
	}

	# check status
        if ( $status==SEARCHD_ERROR ) {
		$self->{_error} = "searchd error: " . substr ( $response, 4 );
		return 0;
	}
	if ( $status==SEARCHD_RETRY ) {
		$self->{_error} = "temporary searchd error: " . substr ( $response, 4 );
                return 0;
        }
        if ( $status!=SEARCHD_OK ) {
        	$self->{_error} = "unknown status code '$status'";
        	return 0;
	}

	# check version
        if ( $ver<$client_ver ) {
		$self->{_warning} = sprintf ( "searchd command v.%d.%d older than client's v.%d.%d, some options might not work",
                                $ver>>8, $ver&0xff, $client_ver>>8, $client_ver&0xff );
	}
        return $response;
}


#-------------------------------------------------------------
# searching
#-------------------------------------------------------------

# set match offset/limits
sub SetLimits {
        my $self = shift;
        my $offset = shift;
        my $limit = shift;
        croak("offset should be an integer >= 0") unless ($offset =~ /^\d+$/ && $offset >= 0) ;
        croak("limit should be an integer >= 0") unless ($limit =~ /^\d+/ && $offset >= 0);
        $self->{_offset} = $offset;
        $self->{_limit}  = $limit;
}

# set match mode
sub SetMatchMode {
        my $self = shift;
        my $mode = shift;
        croak("Match mode not defined") unless defined($mode);
        croak("Unknown matchmode: $mode") unless ( $mode==SPH_MATCH_ALL || $mode==SPH_MATCH_ANY || $mode==SPH_MATCH_PHRASE || $mode==SPH_MATCH_BOOLEAN );
        $self->{_mode} = $mode;
}

# set sort mode
sub SetSortMode {
        my $self = shift;
        my $sort = shift;
        croak("Sort mode not defined") unless defined($sort);
        croak("Unknown sort mode: $sort") unless ( $sort==SPH_SORT_RELEVANCE || $sort==SPH_SORT_DATE_DESC ||
                                                        $sort==SPH_SORT_DATE_ASC || $sort==SPH_SORT_TIME_SEGMENTS );
        $self->{_sort} = $sort;
}

# set per-field weights
sub SetWeights {
        my $self = shift;
        my $weights = shift;
        croak("Weights is not an array reference") unless (ref($weights) eq 'ARRAY');
        foreach my $weight (@$weights) {
                croak("Weight: $weight is not an integer") unless ($weight =~ /^\d+$/);
        }
        $self->{_weights} = $weights;
}

# set groups
sub SetGroups {
	my $self = shift;
	my $groups = shift;
	croak("Groups is not an array reference") unless (ref($groups) eq 'ARRAY');
	foreach my $group (@$groups) {
		croak("Group: $group is not an integer") unless ($group =~ /^\d+$/);
	}
	$self->{_groups} = $groups;
}

# set IDs range to match
sub SetIDRange {
	my $self = shift;
	my $min = shift;
	my $max = shift;
	croak("min_id is not an integer") unless ($min =~ /^\d+$/);
	croak("max_id is not an integer") unless ($max =~ /^\d+$/);
	croak("min_id is larger than or equal to max_id") unless ($min < $max);
	$self->{_min_id} = $min;
	$self->{_max_id} = $max;
}

# set timestamps to match
sub SetTimestampRange {
        my $self = shift;
	my $min = shift;
	my $max = shift;
	croak("min_ts is not an integer") unless ($min =~ /^\d+$/);
        croak("max_ts is not an integer") unless ($max =~ /^\d+$/);
	croak("min_ts is larger than or equal to max_ts") unless ($min < $max);
        $self->{_min_ts} = $min;
	$self->{_max_ts} = $max;
}

# set groups range to match
sub SetGroupsRange {
        my $self = shift;
        my $min = shift;
        my $max = shift;
	croak("min_gid is not an integer") unless ($min =~ /^\d+$/);
        croak("max_gid is not an integer") unless ($max =~ /^\d+$/);
        croak("min_gid is larger than or equal to max_gid") unless ($min < $max);
        $self->{_min_gid} = $min;
        $self->{_max_gid} = $max;
}

# connect to searchd server and run given search query
#
# $query is query string
# $query is index name to query, default is "*" which means to query all indexes
#
# returns false on failure
# returns hash which has the following keys on success:
#          "matches"
#                     array containing hashes with found documents ( "doc", "weight", "group", "stamp" )
#          "total"
#                     total amount of matches retrieved (upto SPH_MAX_MATCHES, see sphinx.h)
#          "total_found"
#                     total amount of matching documents in index
#          "time"
#                     search time
#          "words"
#                     hash which maps query terms (stemmed!) to ( "docs", "hits" ) hash
sub Query {
	my $self = shift;
	my $query = shift;
	my $index = shift;
	$index ||= "*";

	my $fp = $self->_Connect();
	return 0 unless ($fp);
	
	##################
	# build request
	##################
	
        # v.1.0
	my $req;
        $req = pack ( "NNNN", $self->{_offset}, $self->{_limit}, $self->{_mode}, $self->{_sort} ); # mode and limits
        $req .= pack ( "N", scalar(@{$self->{_groups}}) ); # groups
        foreach my $group (@{$self->{_groups}}) {
		$req .= pack ( "N", $group );
	}
	$req .= pack ( "N", length($query) ) . $query; # query itself
        $req .= pack ( "N", scalar(@{$self->{_weights}}) ); # weights
        foreach my $weight (@{$self->{_weights}}) {
		$req .= pack ( "N", int($weight));
	}
	
        $req .= pack ( "N", length($index) ) . $index; # indexes
        $req .=	# id/ts ranges
                pack ( "N", int($self->{_min_id}) ) .
        	pack ( "N", int($self->{_max_id}) ) .
      		pack ( "N", int($self->{_min_ts}) ) .
                pack ( "N", int($self->{_max_ts}) );

	# v.1.1
        $req .= # gid ranges
                pack ( "N", int($self->{_min_gid}) ) .
                pack ( "N", int($self->{_max_gid}) );
	
	##################
	# send query, get response
	##################

	my $len = length($req);
        $req = pack ( "nnN", SEARCHD_COMMAND_SEARCH, VER_COMMAND_SEARCH, $len ) . $req; # add header
	send($fp, $req ,0);

        my $response = $self->_GetResponse ( $fp, VER_COMMAND_SEARCH );
	return 0 unless ($response);

	##################
	# parse response
	##################
	
	my $result = {};		# Empty hash ref
	$result->{matches} = [];	# Empty array ref
	my $count = unpack ( "N*", substr ( $response, 0, 4 ) );

	my $p = 4;
	while ( $count-->0 ) {
		my ( $doc, $group, $stamp, $weight ) = unpack("N*N*N*N*", substr($response,$p,16));
		$p += 16;
		push(@{$result->{matches}}, {
						"doc"		=> $doc,
						"weight"        => $weight,
						"group"         => $group,
						"stamp"         => $stamp 
						});
	}
	my $words;
	($result->{total}, $result->{total_found}, $result->{time}, $words) = unpack("N*N*N*N*", substr($response, $p, 16));
	$result->{time} = sprintf ( "%.3f", $result->{"time"}/1000 );
        $p += 16;

        while ( $words-->0 ) {
		my $len = unpack ( "N*", substr ( $response, $p, 4 ) ); 
		$p += 4;
		my $word = substr ( $response, $p, $len ); 
		$p += $len;
		my ($docs, $hits) = unpack ("N*N*", substr($response, $p, 8));
		$p += 8;
		$result->{words}{$word} = {
						"docs" => $docs,
						"hits" => $hits
					};
	}
        return $result;
}

#-------------------------------------------------------------
# excerpts generation
#-------------------------------------------------------------

# connect to searchd server and generate exceprts from given documents
#
# $index is a string specifiying the index which settings will be used
# for stemming, lexing and case folding
# $docs is an array reference of strings which represent the documents' contents
# $words is a string which contains the words to highlight
# $opts is a hash which contains additional optional highlighting parameters:
# 	      "before_match"
#                     a string to insert before a set of matching words, default is "<b>"
#             "after_match"
#                     a string to insert after a set of matching words, default is "<b>"
#             "chunk_separator"
#                     a string to insert between excerpts chunks, default is " ... "
#             "limit"
#                     max excerpt size in symbols (codepoints), default is 256
#             "around"
#                     how much words to highlight around each match, default is 5
#
# returns false on failure
# retrurns an array of string excerpts on success
sub BuildExcerpts {
	my ($self, $docs, $index, $words, $opts) = @_;
	$opts ||= {};
	croak("BuildExcepts() called with incorrect parameters") unless (ref($docs) eq 'ARRAY' 
									&& defined($index) 
									&& defined($words) 
									&& ref($opts) eq 'HASH');
        my $fp = $self->_Connect();
        return 0 unless ($fp);

	##################
	# fixup options
	##################
	$opts->{"before_match"} ||= "<b>";
	$opts->{"after_match"} ||= "</b>";
	$opts->{"chunk_separator"} ||= " ... ";
	$opts->{"limit"} ||= 256;
	$opts->{"around"} ||= 5;

	##################
	# build request
	##################

	# v.1.0 req
	my $req;
	$req = pack ( "NN", 0, 1 ); # mode=0, flags=1 (remove spaces)
	$req .= pack ( "N", length($index) ) . $index; # req index
	$req .= pack ( "N", length($words) ) . $words; # req words

	# options
	$req .= pack ( "N", length($opts->{"before_match"}) ) . $opts->{"before_match"};
	$req .= pack ( "N", length($opts->{"after_match"}) ) . $opts->{"after_match"};
	$req .= pack ( "N", length($opts->{"chunk_separator"}) ) . $opts->{"chunk_separator"};
	$req .= pack ( "N", int($opts->{"limit"}) );
	$req .= pack ( "N", int($opts->{"around"}) );

	# documents
	$req .= pack ( "N", scalar(@$docs) );
	foreach my $doc (@$docs) {
		croak('BuildExcepts: Found empty document in $docs') unless ($doc);
		$req .= pack("N", length($doc)) . $doc;
	}

	##########################
        # send query, get response
	##########################

	my $len = length($req);
	$req = pack ( "nnN", SEARCHD_COMMAND_EXCERPT, VER_COMMAND_EXCERPT, $len ) . $req; # add header
	send($fp, $req ,0);
	
	my $response = $self->_GetResponse($fp, VER_COMMAND_EXCERPT);
	return 0 unless ($response);

	my ($pos, $i) = 0;
	my $res = [];	# Empty hash ref
        my $rlen = length($response);
        for ( $i=0; $i< scalar(@$docs); $i++ ) {
		my $len = unpack ( "N*", substr ( $response, $pos, 4 ) );
		$pos += 4;

                if ( $pos+$len > $rlen ) {
			$self->_error = "incomplete reply";
			return 0;
		}
		push(@$res, substr ( $response, $pos, $len ));
		$pos += $len;
        }
        return $res;
}

1;
