package Sphinx::Search;

use warnings;
use strict;
use Carp;
use Socket;
use Config;
use Math::BigInt;
use base 'Exporter';
use Fcntl qw(:DEFAULT);
use Errno;

=head1 NAME

Sphinx::Search - Sphinx search engine API Perl client

=head1 VERSION

Please note that you *MUST* install a version which is compatible with your version of Sphinx.

This version is 0.12

Use version 0.12 for Sphinx 0.9.8 and later

Use version 0.11 for Sphinx 0.9.8-rc1 and later

Use version 0.10 for Sphinx 0.9.8-svn-r1112

Use version 0.09 for Sphinx 0.9.8-svn-r985

Use version 0.08 for Sphinx 0.9.8-svn-r871

Use version 0.06 for Sphinx 0.9.8-svn-r820

Use version 0.05 for Sphinx 0.9.8-cvs-20070907

Use version 0.02 for Sphinx 0.9.8-cvs-20070818

=cut

our $VERSION = '0.12';

=head1 SYNOPSIS

    use Sphinx::Search;

    $sphinx = Sphinx::Search->new();

    $results = $sphinx->SetMatchMode(SPH_MATCH_ALL)
                      ->SetSortMode(SPH_SORT_RELEVANCE)
                      ->Query("search terms");

=head1 DESCRIPTION

This is the Perl API client for the Sphinx open-source SQL full-text indexing
search engine, L<http://www.sphinxsearch.com>.

=cut

# Constants to export.
our @EXPORT = qw(	
		SPH_MATCH_ALL SPH_MATCH_ANY SPH_MATCH_PHRASE SPH_MATCH_BOOLEAN SPH_MATCH_EXTENDED
		SPH_MATCH_FULLSCAN SPH_MATCH_EXTENDED2
		SPH_RANK_PROXIMITY_BM25 SPH_RANK_BM25 SPH_RANK_NONE SPH_RANK_WORDCOUNT
		SPH_SORT_RELEVANCE SPH_SORT_ATTR_DESC SPH_SORT_ATTR_ASC SPH_SORT_TIME_SEGMENTS
		SPH_SORT_EXTENDED SPH_SORT_EXPR
		SPH_GROUPBY_DAY SPH_GROUPBY_WEEK SPH_GROUPBY_MONTH SPH_GROUPBY_YEAR SPH_GROUPBY_ATTR
		SPH_GROUPBY_ATTRPAIR
		);

# known searchd commands
use constant SEARCHD_COMMAND_SEARCH	=> 0;
use constant SEARCHD_COMMAND_EXCERPT	=> 1;
use constant SEARCHD_COMMAND_UPDATE	=> 2;
use constant SEARCHD_COMMAND_KEYWORDS	=> 3;

# current client-side command implementation versions
use constant VER_COMMAND_SEARCH		=> 0x113;
use constant VER_COMMAND_EXCERPT	=> 0x100;
use constant VER_COMMAND_UPDATE	        => 0x101;
use constant VER_COMMAND_KEYWORDS       => 0x100;

# known searchd status codes
use constant SEARCHD_OK			=> 0;
use constant SEARCHD_ERROR		=> 1;
use constant SEARCHD_RETRY		=> 2;
use constant SEARCHD_WARNING		=> 3;

# known match modes
use constant SPH_MATCH_ALL		=> 0;
use constant SPH_MATCH_ANY		=> 1;
use constant SPH_MATCH_PHRASE		=> 2;
use constant SPH_MATCH_BOOLEAN		=> 3;
use constant SPH_MATCH_EXTENDED		=> 4;
use constant SPH_MATCH_FULLSCAN	        => 5;
use constant SPH_MATCH_EXTENDED2	=> 6; # extended engine V2 (TEMPORARY, WILL BE REMOVED

# known ranking modes (ext2 only)
use constant SPH_RANK_PROXIMITY_BM25    => 0; # default mode, phrase proximity major factor and BM25 minor one
use constant SPH_RANK_BM25              => 1; # statistical mode, BM25 ranking only (faster but worse quality)
use constant SPH_RANK_NONE              => 2; # no ranking, all matches get a weight of 1
use constant SPH_RANK_WORDCOUNT         => 3; # simple word-count weighting, rank is a weighted sum of per-field keyword occurence counts

# known sort modes
use constant SPH_SORT_RELEVANCE		=> 0;
use constant SPH_SORT_ATTR_DESC		=> 1;
use constant SPH_SORT_ATTR_ASC		=> 2;
use constant SPH_SORT_TIME_SEGMENTS	=> 3;
use constant SPH_SORT_EXTENDED	        => 4;
use constant SPH_SORT_EXPR	        => 5;

# known filter types
use constant SPH_FILTER_VALUES          => 0;
use constant SPH_FILTER_RANGE           => 1;
use constant SPH_FILTER_FLOATRANGE      => 2;

# known attribute types
use constant SPH_ATTR_INTEGER		=> 1;
use constant SPH_ATTR_TIMESTAMP		=> 2;
use constant SPH_ATTR_ORDINAL		=> 3;
use constant SPH_ATTR_BOOL		=> 4;
use constant SPH_ATTR_FLOAT		=> 5;
use constant SPH_ATTR_MULTI		=> 0x40000000;

# known grouping functions
use constant SPH_GROUPBY_DAY		=> 0;
use constant SPH_GROUPBY_WEEK		=> 1;
use constant SPH_GROUPBY_MONTH		=> 2;
use constant SPH_GROUPBY_YEAR		=> 3;
use constant SPH_GROUPBY_ATTR		=> 4;
use constant SPH_GROUPBY_ATTRPAIR	=> 5;

# Floating point number matching expression
my $num_re = qr/^-?\d*\.?\d*(?:[eE][+-]?\d+)?$/;

=head1 CONSTRUCTOR

=head2 new

    $sph = Sphinx::Search->new;
    $sph = Sphinx::Search->new(\%options);

Create a new Sphinx::Search instance.

OPTIONS

=over 4

=item log

Specify an optional logger instance.  This can be any class that provides error,
warn, info, and debug methods (e.g. see L<Log::Log4perl>).  Logging is disabled
if no logger instance is provided.

=item debug

Debug flag.  If set (and a logger instance is specified), debugging messages
will be generated.

=back

=cut

# create a new client object and fill defaults
sub new {
    my ($class, $options) = @_;
    my $self = {
	# per=client-object settings
	_host		=> 'localhost',
	_port		=> 3312,

	# per-query settings
	_offset		=> 0,
	_limit		=> 20,
	_mode		=> SPH_MATCH_ALL,
	_weights	=> [],
	_sort		=> SPH_SORT_RELEVANCE,
	_sortby		=> "",
	_min_id		=> 0,
	_max_id		=> 0xFFFFFFFF,
	_filters	=> [],
	_groupby	=> "",
	_groupdistinct	=> "",
	_groupfunc	=> SPH_GROUPBY_DAY,
	_groupsort      => '@group desc',
	_maxmatches	=> 1000,
	_cutoff         => 0,
	_retrycount     => 0,
	_retrydelay     => 0,
	_anchor         => undef,
	_indexweights   => undef,
	_ranker         => SPH_RANK_PROXIMITY_BM25,
	_maxquerytime   => 0,
	_fieldweights   => {},

	# per-reply fields (for single-query case)
	_error		=> '',
	_warning	=> '',
	
	# request storage (for multi-query case)
	_reqs           => [],

	_timeout        => 0,
	_connection     => undef,
	_persistent_connection => 0,
	_longsize      => $Config{longsize},
    };
    bless $self, ref($class) || $class;

    # These options are supported in the constructor, but not recommended 
    # since there is no validation.  Use the Set* methods instead.
    my %legal_opts = map { $_ => 1 } qw/host port offset limit mode weights sort sortby groupby groupbyfunc maxmatches cutoff retrycount retrydelay log debug/;
    for my $opt (keys %$options) {
	$self->{'_' . $opt} = $options->{$opt} if $legal_opts{$opt};
    }
    # Disable debug unless we have something to log to
    $self->{_debug} = 0 unless $self->{_log};

    return $self;
}

=head1 METHODS

=cut

sub _Error {
    my ($self, $msg) = @_;

    $self->{_error} = $msg;
    $self->{_log}->error($msg) if $self->{_log};
}

=head2 GetLastError

    $error = $sph->GetLastError;

Get last error message (string)

=cut

sub GetLastError {
	my $self = shift;
	return $self->{_error};
}

sub _Warning {
    my ($self, $msg) = @_;

    $self->{_warning} = $msg;
    $self->{_log}->warn($msg) if $self->{_log};
}

=head2 GetLastWarning

    $warning = $sph->GetLastWarning;

Get last warning message (string)

=cut

sub GetLastWarning {
	my $self = shift;
	return $self->{_warning};
}

# Persistent connections not currently supported by searchd.
#=head2 SetPersistentConnection
#
#    $sphinx->SetPersistentConnection(1);
#    $sphinx->SetPersistentConnection(0);
#
#Enable/disable persistent connections.
#
#When enabled, the connection to the searchd server is kept open; you must close
#it manually using Disconnect when you have finished with it.  This is the most
#efficient way to reach the search server if you are performing multiple queries
#with the one Sphinx::Search instance, such as in a web application server
#environment.
#
#When disabled, the connection is established and automatically disconnected on
#each query.  This is useful for CGI type environments where you have only one
#request for the lifetime of the process.
#
#=cut
#
sub _SetPersistentConnection {
    my $self = shift;
    $self->{_persistent_connection} = shift;
    return $self;
}
#
#=head2 Disconnect
#
#    $sph->Disconnect;
#
#Disconnect from the search server.  See L<SetPersistentConnection> for a description.
#
#=cut
#
sub _Disconnect {
    my $self = shift;

    if ($self->{_connection}) {
	close($self->{_connection});
	$self->{_connection} = undef;
    }
    return $self;
}


#-------------------------------------------------------------

# connect to searchd server

sub _Connect {
	my $self = shift;
	
	my $debug = $self->{_debug};

	$self->{_log}->debug("Connecting to $self->{_host}:$self->{_port}") if $debug;

	return $self->{_connection} if $self->{_connection};

	# connect socket
	my $fp;
	socket($fp, PF_INET, SOCK_STREAM, getprotobyname('tcp')) || Carp::croak("socket: ".$!);
	binmode($fp, ':bytes');
	my $dest = sockaddr_in($self->{_port}, inet_aton($self->{_host}));

	if ($self->{_timeout}) {
	    my $flags = fcntl($fp, F_GETFL, 0) or do {
		$self->_Error("Can't get flags for socket: $!");
		return 0;
	    };
	    fcntl($fp, F_SETFL, $flags | O_NONBLOCK) or do {
		$self->_Error("Can't set flags for socket: $!");
		return 0;
	    };
		
	    if (! connect($fp, $dest)) {
		if (! $!{EINPROGRESS}) {
		    $self->_Error("connect to {$self->{_host}}:{$self->{_port}} failed: $!");
		    return 0;
		}
		my $count = 0;
		while ($count < 2) { # until timeout or data received
		    my $vec = '';
		    vec($vec, fileno($fp), 1) = 1;
		    my $n = select($vec, undef, undef, $self->{_timeout});
		    if ($n < 0) {
			$self->_Error("connection to {$self->{_host}}:{$self->{_port}} failed: $!");
			return 0;
		    }
		    elsif ($n == 0) {
			$self->_Error("connection to {$self->{_host}}:{$self->{_port}} timed out");
			return 0;
		    }
		    else {
			my $tmpbuf = 0;
			my $ret = recv($fp, $tmpbuf, 4, MSG_PEEK);
			last if $tmpbuf;
		    }
		    $count++;
		}
	    }
	    fcntl($fp, F_SETFL, $flags) or do {
		$self->_Error("Can't set flags for socket: $!");
		return 0;
	    };
	}
	else {
	    connect($fp, $dest) or do {
		$self->_Error("connection to {$self->{_host}}:{$self->{_port}} failed: $!");
		return 0;
	    };
	}
	# check version
	my $buf = '';
	croak("recv: ".$!) unless defined recv($fp, $buf, 4, 0);
	my $v = unpack("N*", $buf);
	$v = int($v);
	if($v < 1) {
		close($fp) || croak("close: $!");
		$self->_Error("expected searchd protocol version 1+, got version '$v'");
	}

	$self->{_log}->debug("Sending version") if $debug;

	# All ok, send my version
	send($fp, pack("N", 1),0);

	$self->{_connection} = $fp;

	$self->{_log}->debug("Connection complete") if $debug;

	return $fp;
}

#-------------------------------------------------------------

# get and check response packet from searchd server
sub _GetResponse {
	my $self = shift;
	my $fp = shift;
	my $client_ver = shift;

	my $header;
	croak("recv: ".$!) unless defined recv($fp, $header, 8, 0);

	my ($status, $ver, $len ) = unpack("n2N", $header);
        my ($chunk, $response);
	while(defined($chunk = <$fp>)) {
		$response .= $chunk;
	}
        $self->_Disconnect unless $self->{_persistent_connection};

	# check response
        if ( !$response || length($response) != $len ) {
		$self->_Error( $len 
			? "failed to read searchd response (status=$status, ver=$ver, len=$len, read=". length($response) . ")"
       			: "received zero-sized searchd response");
		return 0;
	}

	# check status
        if ( $status==SEARCHD_WARNING ) {
	    my ($wlen) = unpack ( "N*", substr ( $response, 0, 4 ) );
	    $self->_Warning(substr ( $response, 4, $wlen ));
	    return substr ( $response, 4+$wlen );
	}
        if ( $status==SEARCHD_ERROR ) {
		$self->_Error("searchd error: " . substr ( $response, 4 ));
		return 0;
	}
	if ( $status==SEARCHD_RETRY ) {
		$self->_Error("temporary searchd error: " . substr ( $response, 4 ));
                return 0;
        }
        if ( $status!=SEARCHD_OK ) {
        	$self->_Error("unknown status code '$status'");
        	return 0;
	}

	# check version
        if ( $ver<$client_ver ) {
	    $self->_Warning(sprintf ( "searchd command v.%d.%d older than client's v.%d.%d, some options might not work",
				      $ver>>8, $ver&0xff, $client_ver>>8, $client_ver&0xff ));
	}
        return $response;
}

# portably pack numeric to 64 unsigned bits, network order
sub _sphPack64 {
    my $self = shift;
    my $v = shift;

    # x64 route
    if ( $self->{_longsize} >= 8 ) {
	my $i = int($v);
	return pack ( "NN", $i>>32, $i & 4294967295 );
    }

    # x32 route, BigInt
    my $x = "4294967296";
    my $vb = Math::BigInt->new($v);
    my $l = $vb->copy->band ( 4294967295 );
    my $h = $vb->copy->brsft ( 32 );
    return pack ( "NN", $h, $l );
}


# portably unpack 64 unsigned bits, network order to numeric
sub _sphUnpack64 
{
    my $self = shift;
    my $v = shift;

    my ($h,$l) = unpack ( "N*N*", $v );

    # x64 route
    return ($h<<32) + $l if ( $self->{_longsize} >= 8 );

    # x32 route, BigInt
    $h = Math::BigInt->new($h);
    $h->blsft(32)->badd($l);
    
    return $h->bstr;
}



=head2 SetServer

    $sph->SetServer($host, $port);

Set the host (string) and port (integer) details for the searchd server.  Returns $sph.

=cut

sub SetServer {
    my $self = shift;
    my $host = shift;
    my $port = shift;

    croak("host is not defined") unless defined($host);
    croak("port is not an integer") unless defined($port) && $port =~ m/^\d+$/o;

    $self->{_host} = $host;
    $self->{_port} = $port;
    return $self;
}

=head2 SetConnectTimeout

    $sph->SetConnectTimeout($timeout)

Set server connection timeout (in seconds).

Returns $sph.

=cut

sub SetConnectTimeout {
    my $self = shift;
    my $timeout = shift;

    croak("timeout is not numeric") unless ($timeout =~  m/$num_re/);
    $self->{_timeout} = $timeout;
}

=head2 SetLimits

    $sph->SetLimits($offset, $limit);
    $sph->SetLimits($offset, $limit, $max);

Set match offset/limits, and optionally the max number of matches to return.

Returns $sph.

=cut

sub SetLimits {
    my $self = shift;
    my $offset = shift;
    my $limit = shift;
    my $max = shift || 0;
    croak("offset should be an integer >= 0") unless ($offset =~ /^\d+$/ && $offset >= 0) ;
    croak("limit should be an integer >= 0") unless ($limit =~ /^\d+$/ && $limit >= 0);
    $self->{_offset} = $offset;
    $self->{_limit}  = $limit;
    if($max > 0) {
	$self->{_maxmatches} = $max;
    }
    return $self;
}

=head2 SetMaxQueryTime

    $sph->SetMaxQueryTime($millisec);

Set maximum query time, in milliseconds, per index.

The value may not be negative; 0 means "do not limit".

Returns $sph.

=cut

sub SetMaxQueryTime {
    my $self = shift;
    my $max = shift;

    croak("max value should be an integer >= 0") unless ($max =~ /^\d+$/ && $max >= 0) ;
    $self->{_maxquerytime} = $max;
    return $self;
}


=head2 SetMatchMode

    $sph->SetMatchMode($mode);

Set match mode, which may be one of:

=over 4

=item * SPH_MATCH_ALL

Match all words

=item * SPH_MATCH_ANY		

Match any words

=item * SPH_MATCH_PHRASE	

Exact phrase match

=item * SPH_MATCH_BOOLEAN	

Boolean match, using AND (&), OR (|), NOT (!,-) and parenthetic grouping.

=item * SPH_MATCH_EXTENDED	

Extended match, which includes the Boolean syntax plus field, phrase and
proximity operators.

=back

Returns $sph.

=cut

sub SetMatchMode {
        my $self = shift;
        my $mode = shift;
        croak("Match mode not defined") unless defined($mode);
        croak("Unknown matchmode: $mode") unless ( $mode==SPH_MATCH_ALL 
						   || $mode==SPH_MATCH_ANY 
						   || $mode==SPH_MATCH_PHRASE 
						   || $mode==SPH_MATCH_BOOLEAN 
						   || $mode==SPH_MATCH_EXTENDED 
						   || $mode==SPH_MATCH_FULLSCAN 
						   || $mode==SPH_MATCH_EXTENDED2 );
        $self->{_mode} = $mode;
	return $self;
}


=head2 SetRankingMode

    $sph->SetRankingMode(SPH_RANK_BM25);

Set ranking mode, which may be one of:

=over 4

=item * SPH_RANK_PROXIMITY_BM25 

Default mode, phrase proximity major factor and BM25 minor one

=item * SPH_RANK_BM25 

Statistical mode, BM25 ranking only (faster but worse quality)

=item * SPH_RANK_NONE 

No ranking, all matches get a weight of 1

=item * SPH_RANK_WORDCOUNT 

Simple word-count weighting, rank is a weighted sum of per-field keyword
occurence counts

=back

Returns $sph.

=cut

sub SetRankingMode {
    my $self = shift;
    my $ranker = shift;

    croak("Unknown ranking mode: $ranker") unless ( $ranker==SPH_RANK_PROXIMITY_BM25
						    || $ranker==SPH_RANK_BM25
						    || $ranker==SPH_RANK_NONE
						    || $ranker==SPH_RANK_WORDCOUNT );

    $self->{_ranker} = $ranker;
    return $self;
}
   

=head2 SetSortMode

    $sph->SetSortMode(SPH_SORT_RELEVANCE);
    $sph->SetSortMode($mode, $sortby);

Set sort mode, which may be any of:

=over 4

=item SPH_SORT_RELEVANCE - sort by relevance

=item SPH_SORT_ATTR_DESC, SPH_SORT_ATTR_ASC

Sort by attribute descending/ascending.  $sortby specifies the sorting attribute.

=item SPH_SORT_TIME_SEGMENTS

Sort by time segments (last hour/day/week/month) in descending order, and then
by relevance in descending order.  $sortby specifies the time attribute.

=item SPH_SORT_EXTENDED

Sort by SQL-like syntax.  $sortby is the sorting specification.

=item SPH_SORT_EXPR


=back

Returns $sph.

=cut

sub SetSortMode {
        my $self = shift;
        my $mode = shift;
	my $sortby = shift || "";
        croak("Sort mode not defined") unless defined($mode);
        croak("Unknown sort mode: $mode") unless ( $mode == SPH_SORT_RELEVANCE
						   || $mode == SPH_SORT_ATTR_DESC
						   || $mode == SPH_SORT_ATTR_ASC 
						   || $mode == SPH_SORT_TIME_SEGMENTS
						   || $mode == SPH_SORT_EXTENDED
						   || $mode == SPH_SORT_EXPR
						   );
	croak("Sortby must be defined") unless ($mode==SPH_SORT_RELEVANCE || length($sortby));
        $self->{_sort} = $mode;
	$self->{_sortby} = $sortby;
	return $self;
}

=head2 SetWeights
    
    $sph->SetWeights([ 1, 2, 3, 4]);

This method is deprecated.  Use L<SetFieldWeights> instead.

Set per-field (integer) weights.  The ordering of the weights correspond to the
ordering of fields as indexed.

Returns $sph.

=cut

sub SetWeights {
        my $self = shift;
        my $weights = shift;
        croak("Weights is not an array reference") unless (ref($weights) eq 'ARRAY');
        foreach my $weight (@$weights) {
                croak("Weight: $weight is not an integer") unless ($weight =~ /^\d+$/);
        }
        $self->{_weights} = $weights;
	return $self;
}

=head2 SetFieldWeights
    
    $sph->SetFieldWeights(\%weights);

Set per-field (integer) weights by field name.  The weights hash provides field
name to weight mappings.

Takes precedence over L<SetWeights>.

Unknown names will be silently ignored.  Missing fields will be given a weight of 1.

Returns $sph.

=cut

sub SetFieldWeights {
        my $self = shift;
        my $weights = shift;
        croak("Weights is not a hash reference") unless (ref($weights) eq 'HASH');
        foreach my $field (keys %$weights) {
	    croak("Weight: $weights->{$field} is not an integer >= 0") unless ($weights->{$field} =~ /^\d+$/);
        }
        $self->{_fieldweights} = $weights;
	return $self;
}

=head2 SetIndexWeights
    
    $sph->SetIndexWeights(\%weights);

Set per-index (integer) weights.  The weights hash is a mapping of index name to integer weight.

Returns $sph.

=cut

sub SetIndexWeights {
        my $self = shift;
        my $weights = shift;
        croak("Weights is not a hash reference") unless (ref($weights) eq 'HASH');
        foreach (keys %$weights) {
                croak("IndexWeight $_: $weights->{$_} is not an integer") unless ($weights->{$_} =~ /^\d+$/);
        }
        $self->{_indexweights} = $weights;
	return $self;
}



=head2 SetIDRange

    $sph->SetIDRange($min, $max);

Set IDs range only match those records where document ID
is between $min and $max (including $min and $max)

Returns $sph.

=cut

sub SetIDRange {
	my $self = shift;
	my $min = shift;
	my $max = shift;
	croak("min_id is not numeric") unless ($min =~  m/$num_re/);
	croak("max_id is not numeric") unless ($max =~  m/$num_re/);
	croak("min_id is larger than or equal to max_id") unless ($min < $max);
	$self->{_min_id} = $min;
	$self->{_max_id} = $max;
	return $self;
}

=head2 SetFilter

    $sph->SetFilter($attr, \@values);
    $sph->SetFilter($attr, \@values, $exclude);

Sets the results to be filtered on the given attribute.  Only results which have
attributes matching the given (numeric) values will be returned.

This may be called multiple times with different attributes to select on
multiple attributes.

If 'exclude' is set, excludes results that match the filter.

Returns $sph.

=cut

sub SetFilter {
    my ($self, $attribute, $values, $exclude) = @_;

    croak("attribute is not defined") unless (defined $attribute);
    croak("values is not an array reference") unless (ref($values) eq 'ARRAY');
    croak("values reference is empty") unless (scalar(@$values));

    foreach my $value (@$values) {
	croak("value $value is not numeric") unless ($value =~ m/$num_re/);
    }
    push(@{$self->{_filters}}, {
	type => SPH_FILTER_VALUES,
	attr => $attribute,
	values => $values,
	exclude => $exclude ? 1 : 0,
    });

    return $self;
}

=head2 SetFilterRange

    $sph->SetFilterRange($attr, $min, $max);
    $sph->SetFilterRange($attr, $min, $max, $exclude);

Sets the results to be filtered on a range of values for the given
attribute. Only those records where $attr column value is between $min and $max
(including $min and $max) will be returned.

$min and $max must be integers.  Use L<SetFilterFloatRange> for floating point values.

If 'exclude' is set, excludes results that fall within the given range.

Returns $sph.

=cut

sub SetFilterRange {
    my ($self, $attribute, $min, $max, $exclude) = @_;
    croak("attribute is not defined") unless (defined $attribute);
    croak("min: $min is not an integer") unless ($min =~ /^-?\d+$/);
    croak("max: $max is not an integer") unless ($max =~ /^-?\d+$/);
    croak("min value should be <= max") unless ($min <= $max);

    push(@{$self->{_filters}}, {
	type => SPH_FILTER_RANGE,
	attr => $attribute,
	min => $min,
	max => $max,
	exclude => $exclude ? 1 : 0,
    });

    return $self;
}

=head2 SetFilterFloatRange 

    $sph->SetFilterFloatRange($attr, $min, $max, $exclude);

Same as L<SetFilterRange>, but allows floating point values.

Returns $sph.

=cut

sub SetFilterFloatRange {
    my ($self, $attribute, $min, $max, $exclude) = @_;
    croak("attribute is not defined") unless (defined $attribute);
    croak("min: $min is not numeric") unless ($min =~ m/$num_re/);
    croak("max: $max is not numeric") unless ($max =~ m/$num_re/);
    croak("min value should be <= max") unless ($min <= $max);

    push(@{$self->{_filters}}, {
	type => SPH_FILTER_FLOATRANGE,
	attr => $attribute,
	min => $min,
	max => $max,
	exclude => $exclude ? 1 : 0,
    });

    return $self;

}

=head2 SetGeoAnchor

    $sph->SetGeoAnchor($attrlat, $attrlong, $lat, $long);

Setup anchor point for using geosphere distance calculations in filters and sorting.
Distance will be computed with respect to this point

=over 4

=item $attrlat is the name of latitude attribute

=item $attrlong is the name of longitude attribute

=item $lat is anchor point latitude, in radians

=item $long is anchor point longitude, in radians

=back

Returns $sph.

=cut

sub SetGeoAnchor {
    my ($self, $attrlat, $attrlong, $lat, $long) = @_;

    croak("attrlat is not defined") unless defined $attrlat;
    croak("attrlong is not defined") unless defined $attrlong;
    croak("lat: $lat is not numeric") unless ($lat =~ m/$num_re/);
    croak("long: $long is not numeric") unless ($long =~ m/$num_re/);

    $self->{_anchor} = { 
			 attrlat => $attrlat, 
			 attrlong => $attrlong, 
			 lat => $lat,
			 long => $long,
		     };
    return $self;
}

=head2 SetGroupBy

    $sph->SetGroupBy($attr, $func);
    $sph->SetGroupBy($attr, $func, $groupsort);

Sets attribute and function of results grouping.

In grouping mode, all matches are assigned to different groups based on grouping
function value. Each group keeps track of the total match count, and the best
match (in this group) according to current sorting function. The final result
set contains one best match per group, with grouping function value and matches
count attached.

$attr is any valid attribute.  Use L<ResetGroupBy> to disable grouping.

$func is one of:

=over 4

=item * SPH_GROUPBY_DAY

Group by day (assumes timestamp type attribute of form YYYYMMDD)

=item * SPH_GROUPBY_WEEK

Group by week (assumes timestamp type attribute of form YYYYNNN)

=item * SPH_GROUPBY_MONTH

Group by month (assumes timestamp type attribute of form YYYYMM)

=item * SPH_GROUPBY_YEAR

Group by year (assumes timestamp type attribute of form YYYY)

=item * SPH_GROUPBY_ATTR

Group by attribute value

=item * SPH_GROUPBY_ATTRPAIR

Group by two attributes, being the given attribute and the attribute that
immediately follows it in the sequence of indexed attributes.  The specified
attribute may therefore not be the last of the indexed attributes.

=back

Groups in the set of results can be sorted by any SQL-like sorting clause,
including both document attributes and the following special internal Sphinx
attributes:

=over 4

=item @id - document ID;

=item @weight, @rank, @relevance -  match weight;

=item @group - group by function value;

=item @count - number of matches in group.

=back

The default mode is to sort by groupby value in descending order,
ie. by "@group desc".

In the results set, "total_found" contains the total amount of matching groups
over the whole index.

WARNING: grouping is done in fixed memory and thus its results
are only approximate; so there might be more groups reported
in total_found than actually present. @count might also
be underestimated. 

For example, if sorting by relevance and grouping by a "published"
attribute with SPH_GROUPBY_DAY function, then the result set will
contain only the most relevant match for each day when there were any
matches published, with day number and per-day match count attached,
and sorted by day number in descending order (ie. recent days first).

=cut

sub SetGroupBy {
	my $self = shift;
	my $attribute = shift;
	my $func = shift;
	my $groupsort = shift || '@group desc';
	croak("attribute is not defined") unless (defined $attribute);
	croak("Unknown grouping function: $func") unless ($func==SPH_GROUPBY_DAY
							  || $func==SPH_GROUPBY_WEEK
							  || $func==SPH_GROUPBY_MONTH
							  || $func==SPH_GROUPBY_YEAR
							  || $func==SPH_GROUPBY_ATTR
							  || $func==SPH_GROUPBY_ATTRPAIR
							  );

	$self->{_groupby} = $attribute;
	$self->{_groupfunc} = $func;
	$self->{_groupsort} = $groupsort;
	return $self;
}

=head2 SetGroupDistinct

    $sph->SetGroupDistinct($attr);

Set count-distinct attribute for group-by queries

=cut

sub SetGroupDistinct {
    my $self = shift;
    my $attribute = shift;
    croak("attribute is not defined") unless (defined $attribute);
    $self->{_groupdistinct} = $attribute;
    return $self;
}

=head2 SetRetries

    $sph->SetRetries($count, $delay);

Set distributed retries count and delay

=cut

sub SetRetries {
    my $self = shift;
    my $count = shift;
    my $delay = shift || 0;

    croak("count: $count is not an integer >= 0") unless ($count =~ /^\d+$/o && $count >= 0);
    croak("delay: $delay is not an integer >= 0") unless ($delay =~ /^\d+$/o && $delay >= 0);
    $self->{_retrycount} = $count;
    $self->{_retrydelay} = $delay;
    return $self;
}


=head2 ResetFilters

    $sph->ResetFilters;

Clear all filters.

=cut

sub ResetFilters {
    my $self = shift;

    $self->{_filters} = [];
    $self->{_anchor} = undef;

    return $self;
}

=head2 ResetGroupBy

    $sph->ResetGroupBy;

Clear all group-by settings (for multi-queries)

=cut

sub ResetGroupBy {
    my $self = shift;

    $self->{_groupby} = "";
    $self->{_groupfunc} = SPH_GROUPBY_DAY;
    $self->{_groupsort} = '@group desc';
    $self->{_groupdistinct} = "";

    return $self;
}


=head2 Query

    $results = $sph->Query($query, $index);

Connect to searchd server and run given search query.

=over 4

=item query is query string

=item index is index name to query, default is "*" which means to query all indexes.  Use a space or comma separated list to search multiple indexes.

=back

Returns undef on failure

Returns hash which has the following keys on success:

=over 4

=item matches
    
Array containing hashes with found documents ( "doc", "weight", "group", "stamp" )
 
=item total

Total amount of matches retrieved (upto SPH_MAX_MATCHES, see sphinx.h)

=item total_found
                    
Total amount of matching documents in index
 
=item time
          
Search time

=item words
           
Hash which maps query terms (stemmed!) to ( "docs", "hits" ) hash

=back

Returns the results array on success, undef on error.

=cut

sub Query {
    my $self = shift;
    my $query = shift;
    my $index = shift || '*';
    my $comment = shift || '';

    croak("_reqs is not empty") unless @{$self->{_reqs}} == 0;

    $self->AddQuery($query, $index, $comment);
    my $results = $self->RunQueries or return;
    $self->_Error($results->[0]->{error}) if $results->[0]->{error};
    $self->_Warning($results->[0]->{warning}) if $results->[0]->{warning};
    return if $results->[0]->{status} && $results->[0]->{status} == SEARCHD_ERROR;

    return $results->[0];
}

# helper to pack floats in network byte order
sub _PackFloat {
    my $f = shift;
    my $t1 = pack ( "f", $f ); # machine order
    my $t2 = unpack ( "L*", $t1 ); # int in machine order
    return pack ( "N", $t2 );
}


=head2 AddQuery

   $sph->AddQuery($query, $index);

Add a query to a batch request.

Batch queries enable searchd to perform internal optimizations,
if possible; and reduce network connection overheads in all cases.

For instance, running exactly the same query with different
groupby settings will enable searched to perform expensive
full-text search and ranking operation only once, but compute
multiple groupby results from its output.

Parameters are exactly the same as in Query() call.

Returns corresponding index to the results array returned by RunQueries() call.

=cut

sub AddQuery {
    my $self = shift;
    my $query = shift;
    my $index = shift || '*';
    my $comment = shift || '';

    ##################
    # build request
    ##################

    my $req;
    $req = pack ( "NNNNN", $self->{_offset}, $self->{_limit}, $self->{_mode}, $self->{_ranker}, $self->{_sort} ); # mode and limits
    $req .= pack ( "N/a*", $self->{_sortby});
    $req .= pack ( "N/a*", $query ); # query itself
    $req .= pack ( "N*", scalar(@{$self->{_weights}}), @{$self->{_weights}});
    $req .= pack ( "N/a*", $index); # indexes
    $req .= pack ( "N", 1) 
	. $self->_sphPack64($self->{_min_id})
	. $self->_sphPack64($self->{_max_id}); # id64 range

    # filters
    $req .= pack ( "N", scalar @{$self->{_filters}} );
    foreach my $filter (@{$self->{_filters}}) {
	$req .= pack ( "N/a*", $filter->{attr});
	$req .= pack ( "N", $filter->{type});

	my $t = $filter->{type};
	if ($t == SPH_FILTER_VALUES) {
	    $req .= pack ( "N*", scalar(@{$filter->{values}}), @{$filter->{values}});
	}
	elsif ($t == SPH_FILTER_RANGE) {
	    $req .= pack ( "NN", $filter->{min}, $filter->{max} );
	}
	elsif ($t == SPH_FILTER_FLOATRANGE) {
	    $req .= _PackFloat ( $filter->{"min"} ) . _PackFloat ( $filter->{"max"} );
	}
	else {
	    croak("Unhandled filter type $t");
	}
	$req .= pack ( "N",  $filter->{exclude});
    }

    # group-by clause, max-matches count, group-sort clause, cutoff count
    $req .= pack ( "NN/a*", $self->{_groupfunc}, $self->{_groupby} );
    $req .= pack ( "N", $self->{_maxmatches} );
    $req .= pack ( "N/a*", $self->{_groupsort});
    $req .= pack ( "NNN", $self->{_cutoff}, $self->{_retrycount}, $self->{_retrydelay} );
    $req .= pack ( "N/a*", $self->{_groupdistinct});

    if (!defined $self->{_anchor}) {
	$req .= pack ( "N", 0);
    }
    else {
	my $a = $self->{_anchor};
	$req .= pack ( "N", 1);
	$req .= pack ( "N/a*", $a->{attrlat});
	$req .= pack ( "N/a*", $a->{attrlong});
	$req .= _PackFloat($a->{lat}) . _PackFloat($a->{long});
    }

    # per-index weights
    $req .= pack( "N", scalar keys %{$self->{_indexweights}});
    $req .= pack ( "N/a*N", $_, $self->{_indexweights}->{$_} ) for keys %{$self->{_indexweights}};

    # max query time
    $req .= pack ( "N", $self->{_maxquerytime} );

    # per-field weights
    $req .= pack ( "N", scalar keys %{$self->{_fieldweights}} );
    $req .= pack ( "N/a*N", $_, $self->{_fieldweights}->{$_}) for keys %{$self->{_fieldweights}};
    # comment
    $req .= pack ( "N/a*", $comment);

    push(@{$self->{_reqs}}, $req);

    return scalar $#{$self->{_reqs}};
}

=head2 RunQueries

    $sph->RunQueries

Run batch of queries, as added by AddQuery.

Returns undef on network IO failure.

Returns an array of result sets on success.

Each result set in the returned array is a hash which contains
the same keys as the hash returned by L<Query>, plus:

=over 4 

=item * error 

Errors, if any, for this query.

=item * warnings
	
Any warnings associated with the query.

=back

=cut

sub RunQueries {
    my $self = shift;

    unless (@{$self->{_reqs}}) {
	$self->_Error("no queries defined, issue AddQuery() first");
	return;
    }

    my $fp = $self->_Connect() or return;

    ##################
    # send query, get response
    ##################
    my $nreqs = @{$self->{_reqs}};
    my $req = pack("Na*", $nreqs, join("", @{$self->{_reqs}}));
    $req = pack ( "nnN/a*", SEARCHD_COMMAND_SEARCH, VER_COMMAND_SEARCH, $req); # add header
    send($fp, $req ,0);

    $self->{_reqs} = [];
		   
    my $response = $self->_GetResponse ( $fp, VER_COMMAND_SEARCH );
    return unless $response;

    ##################
    # parse response
    ##################

    my $p = 0;
    my $max = length($response); # Protection from broken response

    my @results;
    for (my $ires = 0; $ires < $nreqs; $ires++) {
	my $result = {};	# Empty hash ref
	push(@results, $result);
	$result->{matches} = []; # Empty array ref
	$result->{error} = "";
	$result->{warnings} = "";

	# extract status
	my $status = unpack("N", substr ( $response, $p, 4 ) ); $p += 4;
	if ($status != SEARCHD_OK) {
	    my $len = unpack("N", substr ( $response, $p, 4 ) ); $p += 4;
	    my $message = substr ( $response, $p, $len ); $p += $len;
	    if ($status == SEARCHD_WARNING) {
		$result->{warning} = $message;
	    }
	    else {
		$result->{error} = $message;
		next;
	    }	    
	}

	# read schema
	my @fields;
	my (%attrs, @attr_list);

	my $nfields = unpack ( "N", substr ( $response, $p, 4 ) ); $p += 4;
	while ( $nfields-->0 && $p<$max ) {
	    my $len = unpack ( "N", substr ( $response, $p, 4 ) ); $p += 4;
	    push(@fields, substr ( $response, $p, $len )); $p += $len;
	}
	$result->{"fields"} = \@fields;

	my $nattrs = unpack ( "N*", substr ( $response, $p, 4 ) ); $p += 4;
	while ( $nattrs-->0 && $p<$max  ) {
	    my $len = unpack ( "N*", substr ( $response, $p, 4 ) ); $p += 4;
	    my $attr = substr ( $response, $p, $len ); $p += $len;
	    my $type = unpack ( "N*", substr ( $response, $p, 4 ) ); $p += 4;
	    $attrs{$attr} = $type;
	    push(@attr_list, $attr);
	}
	$result->{"attrs"} = \%attrs;

	# read match count
	my $count = unpack ( "N*", substr ( $response, $p, 4 ) ); $p += 4;
	my $id64 = unpack ( "N*", substr ( $response, $p, 4 ) ); $p += 4;

	# read matches
	while ( $count-->0 && $p<$max ) {
	    my $data = {};
	    if ($id64) {
		$data->{doc} = $self->_sphUnpack64(substr($response, $p, 8)); $p += 8;
		$data->{weight} = unpack("N*", substr($response, $p, 4)); $p += 4;
	    }
	    else {
		( $data->{doc}, $data->{weight} ) = unpack("N*N*", substr($response,$p,8));
		$p += 8;
	    }
	    foreach my $attr (@attr_list) {
		if ($attrs{$attr} == SPH_ATTR_FLOAT) {
		    my $uval = unpack( "N*", substr ( $response, $p, 4 ) ); $p += 4;
		    $data->{$attr} = [ unpack("f*", pack("L", $uval)) ];
		    next;
		}
		my $val = unpack ( "N*", substr ( $response, $p, 4 ) ); $p += 4;
		if ($attrs{$attr} & SPH_ATTR_MULTI) {
		    my $nvalues = $val;
		    $data->{$attr} = [];
		    while ($nvalues-->0 && $p < $max) {
			$val = unpack( "N*", substr ( $response, $p, 4 ) ); $p += 4;
			push(@{$data->{$attr}}, $val);
		    }
		}
		else {
		    $data->{$attr} = $val;
		}
	    }
	    push(@{$result->{matches}}, $data);
	}
	my $words;
	($result->{total}, $result->{total_found}, $result->{time}, $words) = unpack("N*N*N*N*", substr($response, $p, 16));
	$result->{time} = sprintf ( "%.3f", $result->{"time"}/1000 );
	$p += 16;

	while ( $words-->0 && $p < $max) {
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
    }

    return \@results;
}

=head2 BuildExcerpts

    $excerpts = $sph->BuildExcerpts($docs, $index, $words, $opts)

Generate document excerpts for the specified documents.

=over 4

=item docs 

An array reference of strings which represent the document
contents

=item index 

A string specifiying the index whose settings will be used
for stemming, lexing and case folding

=item words 

A string which contains the words to highlight

=item opts 

A hash which contains additional optional highlighting parameters:

=over 4

=item before_match - a string to insert before a set of matching words, default is "<b>"

=item after_match - a string to insert after a set of matching words, default is "<b>"

=item chunk_separator - a string to insert between excerpts chunks, default is " ... "

=item limit - max excerpt size in symbols (codepoints), default is 256

=item around - how many words to highlight around each match, default is 5

=item exact_phrase - whether to highlight exact phrase matches only, default is false

=item single_passage - whether to extract single best passage only, default is false

=item use_boundaries

=item weight_order 

=back

=back

Returns undef on failure.

Returns an array of string excerpts on success.

=cut

sub BuildExcerpts {
	my ($self, $docs, $index, $words, $opts) = @_;
	$opts ||= {};
	croak("BuildExcepts() called with incorrect parameters") 
	    unless (ref($docs) eq 'ARRAY' 
		    && defined($index) 
		    && defined($words) 
		    && ref($opts) eq 'HASH');
        my $fp = $self->_Connect() or return;

	##################
	# fixup options
	##################
	$opts->{"before_match"} ||= "<b>";
	$opts->{"after_match"} ||= "</b>";
	$opts->{"chunk_separator"} ||= " ... ";
	$opts->{"limit"} ||= 256;
	$opts->{"around"} ||= 5;
	$opts->{"exact_phrase"} ||= 0;
	$opts->{"single_passage"} ||= 0;
	$opts->{"use_boundaries"} ||= 0;
	$opts->{"weight_order"} ||= 0;

	##################
	# build request
	##################

	# v.1.0 req
	my $req;
	my $flags = 1; # remove spaces
	$flags |= 2 if ( $opts->{"exact_phrase"} );
	$flags |= 4 if ( $opts->{"single_passage"} );
	$flags |= 8 if ( $opts->{"use_boundaries"} );
	$flags |= 16 if ( $opts->{"weight_order"} );
	$req = pack ( "NN", 0, $flags ); # mode=0, flags=$flags

	$req .= pack ( "N", length($index) ) . $index; # req index
	$req .= pack ( "N", length($words) ) . $words; # req words

	# options
	$req .= pack ( "N/a*", $opts->{"before_match"});
	$req .= pack ( "N/a*", $opts->{"after_match"});
	$req .= pack ( "N/a*", $opts->{"chunk_separator"});
	$req .= pack ( "N", int($opts->{"limit"}) );
	$req .= pack ( "N", int($opts->{"around"}) );

	# documents
	$req .= pack ( "N", scalar(@$docs) );
	foreach my $doc (@$docs) {
		croak('BuildExcepts: Found empty document in $docs') unless ($doc);
		$req .= pack("N/a*", $doc);
	}

	##########################
        # send query, get response
	##########################

	$req = pack ( "nnN/a*", SEARCHD_COMMAND_EXCERPT, VER_COMMAND_EXCERPT, $req); # add header
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
			$self->_Error("incomplete reply");
			return 0;
		}
		push(@$res, substr ( $response, $pos, $len ));
		$pos += $len;
        }
        return $res;
}


=head2 BuildKeywords

    $results = $sph->BuildKeywords($query, $index, $hits)

Generate keyword list for a given query
Returns undef on failure,
Returns an array of hashes, where each hash describes a word in the query with the following keys:

=over 4

=item * tokenized 

Tokenised term from query

=item * normalized 

Normalised term from query

=item * docs 

Number of docs in which word was found (if $hits is true)

=item * hits 

Number of occurrences of word (if $hits is true)

=back

=cut

sub BuildKeywords {
    my ( $self, $query, $index, $hits ) = @_;

    my $fp = $self->_Connect() or return;

    # v.1.0 req
    my $req = pack("N/a*", $query);
    $req .= pack("N/a*", $index);
    $req .= pack("N", $hits);

    ##################
    # send query, get response
    ##################

    $req = pack ( "nnN/a*", SEARCHD_COMMAND_KEYWORDS, VER_COMMAND_KEYWORDS, $req);
    send($fp, $req, 0);
    my $response = $self->_GetResponse ( $fp, VER_COMMAND_KEYWORDS );
    return unless $response;

    ##################
    # parse response
    ##################

    my $p = 0;
    my @res;
    my $rlen = length($response);

    my $nwords = unpack("N", substr ( $response, $p, 4 ) ); $p += 4;

    for (my $i=0; $i < $nwords; $i++ ) {
	my $len = unpack("N", substr ( $response, $p, 4 ) ); $p += 4;

	my $tokenized = $len ? substr ( $response, $p, $len ) : ""; $p += $len;
	$len = unpack("N", substr ( $response, $p, 4 ) ); $p += 4;

	my $normalized = $len ? substr ( $response, $p, $len ) : ""; $p += $len;
	my %data = ( tokenized => $tokenized, normalized => $normalized );
	
	if ($hits) {
	    ( $data{docs}, $data{hits} ) = unpack("N*N*", substr($response,$p,8));
	    $p += 8;
	    
	}
	push(@res, \%data);
    }
    if ( $p > $rlen ) {
	$self->_Error("incomplete reply");
	return;
    }

    return \@res;
}

=head2 EscapeString

    $escaped = $sph->EscapeString('abcde!@#$%')

Inserts backslash before all non-word characters in the given string.

=cut

sub EscapeString {
    my $self = shift;
    return quotemeta(shift);
}


=head2 UpdateAttributes

    $sph->UpdateAttributes($index, \@attrs, \%values);

Update specified attributes on specified documents

=over 4

=item index 

Name of the index to be updated

=item attrs 

Array of attribute name strings

=item values 

A hash with key as document id, value as an array of new attribute values

=back

Returns number of actually updated documents (0 or more) on success

Returns undef on failure

Usage example:

 $sph->UpdateAttributes("test1", [ qw/group_id/ ], { 1 => [ 456] }) );

=cut

sub UpdateAttributes  {
    my ($self, $index, $attrs, $values ) = @_;

    croak("index is not defined") unless (defined $index);
    croak("attrs must be an array") unless ref($attrs) eq "ARRAY";
    for my $attr (@$attrs) {
	croak("attribute is not defined") unless (defined $attr);
    }
    croak("values must be a hashref") unless ref($values) eq "HASH";

    for my $id (keys %$values) {
	my $entry = $values->{$id};
	croak("value id $id is not numeric") unless ($id =~ /$num_re/);
	croak("value entry must be an array") unless ref($entry) eq "ARRAY";
	croak("size of values must match size of attrs") unless @$entry == @$attrs;
	for my $v (@$entry) {
	    croak("entry value $v is not an integer") unless ($v =~ /^(\d+)$/o);
	}
    }

    ## build request
    my $req = pack ( "N/a*", $index);

    $req .= pack ( "N", scalar @$attrs );
    for my $attr (@$attrs) {
	$req .= pack ( "N/a*", $attr);
    }
    $req .= pack ( "N", scalar keys %$values );
    foreach my $id (keys %$values) {
	my $entry = $values->{$id};
	$req .= $self->_sphPack64($id);
	for my $v ( @$entry ) {
	    $req .= pack ( "N", $v );
	}
    }

    ## connect, send query, get response
    my $fp = $self->_Connect() or return;

    $req = pack ( "nnN/a*", SEARCHD_COMMAND_UPDATE, VER_COMMAND_UPDATE, $req); ## add header
    send ( $fp, $req, 0);

    my $response = $self->_GetResponse ( $fp, VER_COMMAND_UPDATE );
    return unless $response;

    ## parse response
    my ($updated) = unpack ( "N*", substr ( $response, 0, 4 ) );
    return $updated;
}

=head1 SEE ALSO

L<http://www.sphinxsearch.com>

=head1 NOTES

There is a bundled Sphinx.pm in the contrib area of the Sphinx source
distribution, which was used as the starting point of Sphinx::Search.
Maintenance of that version appears to have lapsed at sphinx-0.9.7, so many of
the newer API calls are not available there.  Sphinx::Search is mostly
compatible with the old Sphinx.pm except:

=over 4

=item On failure, Sphinx::Search returns undef rather than 0 or -1.

=item Sphinx::Search 'Set' functions are cascadable, e.g. you can do
      Sphinx::Search->new
        ->SetMatchMode(SPH_MATCH_ALL)
        ->SetSortMode(SPH_SORT_RELEVANCE)
        ->Query("search terms")

=back

Sphinx::Search also provides documentation and unit tests, which were the main
motivations for branching from the earlier work.

=head1 AUTHOR

Jon Schutz

=head1 BUGS

Please report any bugs or feature requests to
C<bug-sphinx-search at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Sphinx-Search>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Sphinx::Search

You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Sphinx-Search>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Sphinx-Search>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Sphinx-Search>

=item * Search CPAN

L<http://search.cpan.org/dist/Sphinx-Search>

=back

=head1 ACKNOWLEDGEMENTS

This module is based on Sphinx.pm (not deployed to CPAN) for Sphinx version
0.9.7-rc1, by Len Kranendonk, which was in turn based on the Sphinx PHP API.

=head1 COPYRIGHT & LICENSE

Copyright 2007 Jon Schutz, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the terms of the GNU General Public License.

=cut


1;
