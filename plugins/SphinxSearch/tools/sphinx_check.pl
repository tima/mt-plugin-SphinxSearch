#!/usr/bin/perl

sub validate_pid
{
	my ($proc, $pidfile) = @_;
	$proc = "searchd" if($proc eq '');
	$pidfile = "/var/tmp/sphinx/data/searchd.pid" if($pidfile eq '');

	my $result = 0;
	if ( $pidfile ne ''  && -e "$pidfile" ) {
		$var=`cat /var/tmp/sphinx/data/searchd.pid`;
		$var = chomp($var);

		$result=`pgrep -fl $proc | grep "$var" | wc -l`;
	}
	else {
		$result=`pgrep -fl $proc`;
	}
	$result =~ s/^[\s\t]+//;
	$result =~ s/[\s\t]+$//;
	$result = 0 if($result eq '');
	$result;
}

# main
if ( ! &validate_pid() ) {
	`nohup /usr/local/bin/searchd -c /var/tmp/sphinx/sphinx.conf 2>/dev/null`;
}
