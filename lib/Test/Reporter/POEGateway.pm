# Declare our package
package Test::Reporter::POEGateway;
use strict; use warnings;

# Initialize our version
use vars qw( $VERSION );
$VERSION = '0.01';

# Import what we need from the POE namespace
use POE;
use POE::Component::Server::SimpleHTTP;
use base 'POE::Session::AttributeBased';

# Misc stuff
use HTTP::Request::Params;
use YAML::Tiny qw( DumpFile );
use Digest::SHA qw( sha1_hex );
use File::Spec;

# Set some constants
BEGIN {
	if ( ! defined &DEBUG ) { *DEBUG = sub () { 0 } }
}

# starts the component!
sub spawn {
	my $class = shift;

	# The options hash
	my %opt;

	# Support passing in a hash ref or a regular hash
	if ( ( @_ & 1 ) and ref $_[0] and ref( $_[0] ) eq 'HASH' ) {
		%opt = %{ $_[0] };
	} else {
		# Sanity checking
		if ( @_ & 1 ) {
			warn __PACKAGE__ . ' requires an even number of options passed to spawn()';
			return 0;
		}

		%opt = @_;
	}

	# lowercase keys
	%opt = map { lc($_) => $opt{$_} } keys %opt;

	# setup the HTTPD opts
	if ( ! exists $opt{'httpd'} or ! defined $opt{'httpd'} ) {
		if ( DEBUG ) {
			warn 'Using default HTTPD = { ALIAS => HTTPD, PORT => 11_111, HOSTNAME => POEGateway.net }';
		}

		# Set the default
		$opt{'httpd'} = {};
	} else {
		if ( ref( $opt{'httpd'} ) ne 'HASH' ) {
			warn "The httpd argument is not a valid HASH reference!";
			return 0;
		}
	}

	# Cleanup the httpd opts
	$opt{'httpd'} = {
		'ALIAS'		=> 'HTTPD',
		'PORT'		=> 11_111,
		'HOSTNAME'	=> 'POEGateway.net',
		%{ $opt{'httpd'} },
	};
	delete $opt{'httpd'}->{'HANDLERS'} if exists $opt{'httpd'}->{'HANDLERS'};

	# setup the path to store reports
	if ( ! exists $opt{'reports'} or ! defined $opt{'reports'} ) {
		if ( DEBUG ) {
			warn 'Using default REPORTS = "$ENV{HOME}/cpan_reports"';
		}

		# Set the default
		$opt{'reports'} = File::Spec->catdir( $ENV{HOME}, 'cpan_reports' );
	}

	# validate the report path
	if ( ! -d $opt{'reports'} ) {
		warn "The report path does not exist ($opt{'reports'}), please make sure it is a writable directory!";
		return 0;
	}

	# setup the alias
	if ( ! exists $opt{'alias'} or ! defined $opt{'alias'} ) {
		if ( DEBUG ) {
			warn 'Using default ALIAS = POEGateway';
		}

		# Set the default
		$opt{'alias'} = 'POEGateway';
	}

	# setup the key callback
	if ( ! exists $opt{'key_cb'} or ! defined $opt{'key_cb'} ) {
		if ( DEBUG ) {
			warn 'Using default KEY_CB = { 1 }';
		}

		# Set the default
		$opt{'key_cb'} = sub { 1 };
	} else {
		# make sure it's a sub reference
		if ( ref( $opt{'key_cb'} ) ne 'CODE' ) {
			warn "The key_cb is not a valid code reference!";
			return 0;
		}
	}

	# Create our session
	POE::Session->create(
		__PACKAGE__->inline_states(),
		'heap'	=>	{
			'ALIAS'		=> $opt{'alias'},
			'REPORTS'	=> $opt{'reports'},
			'HTTPD_OPT'	=> $opt{'httpd'},
			'KEY_CB'	=> $opt{'key_cb'},
		},
	);

	# return success
	return 1;
}

# This starts the component
sub _start : State {
	if ( DEBUG ) {
		warn 'Starting alias "' . $_[HEAP]->{'ALIAS'} . '"';
	}

	# Set up the alias for ourself
	$_[KERNEL]->alias_set( $_[HEAP]->{'ALIAS'} );

	# spawn the httpd
	POE::Component::Server::SimpleHTTP->new(
		%{ $_[HEAP]->{'HTTPD_OPT'} },
		'HANDLERS'	=> [
			{
				'DIR'		=> '.*',
				'EVENT'		=> 'got_req',
			},
		],
	) or die 'Unable to create httpd';

	return;
}

# POE Handlers
sub _stop : State {
	if ( DEBUG ) {
		warn 'Stopping alias "' . $_[HEAP]->{'ALIAS'} . '"';
	}

	return;
}

sub _child : State {
	return;
}

sub shutdown : State {
	# cleanup some stuff
	$_[KERNEL]->alias_remove( $_[HEAP]->{'ALIAS'} );

	# tell poco-simplehttp to shutdown
	$_[KERNEL]->post( $_[HEAP]->{'httpd'}->{'alias'}, 'SHUTDOWN' );

	return;
}

# Got a HTTP request
sub got_req : State {
	# ARG0 = HTTP::Request object, ARG1 = HTTP::Response object, ARG2 = the DIR that matched
	my( $request, $response, $dirmatch ) = @_[ ARG0 .. ARG2 ];

	# a sane Test::Reporter submission?
	# mostly copied from Test::Reporter::HTTPGateway, thanks!
	my $form = HTTP::Request::Params->new({ req => $request })->params;
	foreach my $v ( qw( from subject via report ) ) {
		if ( ! exists $form->{ $v } or ! defined $form->{ $v } or ! length( $form->{ $v } ) ) {
			$response->code( 500 );
			$response->content( "ERROR: Missing $v field" );
			last;
		}

		next if $v eq 'report';
		if ( $form->{ $v } =~ /[\r\n]/ ) {
			$response->code( 500 );
			$response->content( "ERROR: Malformed $v field" );
			last;
		}
	}

	# Do we need to check key?
	if ( ! $_[HEAP]->{'KEY_CB'}->( $form->{'key'} ) ) {
		$response->code( 401 );
		$response->content( 'Access denied, please supply a correct key.' );
	}

	# not a malformed request...
	if ( ! defined $response->code ) {
		# store the request somewhere
		save_report( $form, $request, $response );

		# Do our stuff to HTTP::Response
		$response->code( 200 );
		$response->content( 'Report Submitted.' );
	}

	# We are done!
	$_[KERNEL]->post( 'HTTPD', 'DONE', $response );

	return;
}

# does the brunt work of saving posted reports
sub save_report {
	my( $form, $request, $response ) = @_;

	# add some misc info
	$form->{'_sender'} = $response->connection->remote_ip;
	$form->{'via'} .= ', via ' . __PACKAGE__ . ' ' . $VERSION;

	# calculate the filename
	my $filename = time() . '.' . sha1_hex( $form->{'report'} );
	DumpFile( File::Spec->catfile( $_[HEAP]->{'REPORTS'}, $filename ), $form );

	if ( DEBUG ) {
		warn "Saved $form->{subject} report to $filename";
	}

	return;
}

1;
__END__

=head1 NAME

Test::Reporter::POEGateway - A Test::Reporter::HTTPGateway using the power of POE

=head1 SYNOPSIS

	#!/usr/bin/perl
	use strict; use warnings;
	use Test::Reporter::POEGateway;

	# let it do the work!
	Test::Reporter::POEGateway->spawn();

	# run the kernel!
	POE::Kernel->run();

=head1 ABSTRACT

This implements the same logic as L<Test::Reporter::HTTPGateway> but in POE. The reason for this is because I didn't have a cgi host :( Furthermore,
this module splits the relaying logic into 2 separate modules. You can either run both in one process or separate. That way, you have more control over
how the mailer will work. See L<Test::Reporter::POEGateway::Mailer> for the mailing side of the module.

=head1 DESCRIPTION

Really, all you have to do is load the module and call it's spawn() method:

	use Test::Reporter::POEGateway;
	Test::Reporter::POEGateway->spawn( ... );

This method will return failure on errors or return success. Normally you don't need to pass any arguments to it,
but if you want to do zany things, you can!

This constructor accepts either a hashref or a hash, valid options are:

=head3 alias

This sets the alias of the session.

The default is: POEGateway

=head3 reports

This sets the path where it will store received report submissions.

The default is: $ENV{HOME}/cpan_reports

=head3 key_cb

This sets the callback routine if you want to require a key to use the gateway.

The callback will receive one argument: the key. It may be undefined or a string or whatever the submitter put in it. It should return either 1 or 0.

The default is: sub { 1 } # do not require a key

=head3 httpd

Sets various L<POE::Component::Server::SimpleHTTP> options if desired. This should be a hashref. You normally would want to override the port, for example.
Note: You cannot override the HANDLERS!

The default is: { ALIAS => HTTPD, PORT => 11_111, HOSTNAME => POEGateway.net }

=head2 Commands

There is only one command you can use, as this is a very simple module.

=head3 shutdown

Tells this module to shut down the underlying httpd session and terminate itself.

	$_[KERNEL]->post( 'POEGateway', 'shutdown' );

=head2 TODO

None as of now, if you have ideas please submit them to me!

=head1 EXPORT

None.

=head1 SEE ALSO

L<Test::Reporter::POEGateway::Mailer>

L<Test::Reporter::HTTPGateway>

L<Test::Reporter>

L<POE>

L<POE::Component::Server::SimpleHTTP>

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Test::Reporter::POEGateway

=head2 Websites

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Test-Reporter-POEGateway>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Test-Reporter-POEGateway>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Test-Reporter-POEGateway>

=item * Search CPAN

L<http://search.cpan.org/dist/Test-Reporter-POEGateway>

=back

=head2 Bugs

Please report any bugs or feature requests to C<bug-test-reporter-poegateway at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Test-Reporter-POEGateway>.  I will be
notified, and then you'll automatically be notified of progress on your bug as I make changes.

=head1 AUTHOR

Apocalypse E<lt>apocal@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2009 by Apocalypse

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
