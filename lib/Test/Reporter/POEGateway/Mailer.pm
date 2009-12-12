# Declare our package
package Test::Reporter::POEGateway::Mailer;
use strict; use warnings;

# Initialize our version
use vars qw( $VERSION );
$VERSION = '0.01';

# Import what we need from the POE namespace
use POE;
use POE::Wheel::Run;
use POE::Filter::Reference;
use POE::Filter::Line;
use base 'POE::Session::AttributeBased';

# Misc modules we need
use YAML::Tiny qw( LoadFile );
use File::Spec;
use File::Copy qw( move );

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

	if ( exists $opt{'poegateway'} ) {
		if ( DEBUG ) {
			warn "Not using REPORTS, we will receive reports directly from POEGateway";
		}

		if ( exists $opt{'reports'} ) {
			warn "You cannot use REPORTS with POEGATEWAY at the same time, preferring POEGATEWAY!";
			delete $opt{'reports'};
		}
	} else {
		# setup the path to read reports from
		if ( ! exists $opt{'reports'} or ! defined $opt{'reports'} ) {
			my $path = File::Spec->catdir( $ENV{HOME}, 'cpan_reports' );
			if ( DEBUG ) {
				warn "Using default REPORTS = $path";
			}

			# Set the default
			$opt{'reports'} = $path;
		}

		# validate the report path
		if ( ! -d $opt{'reports'} ) {
			warn "The report path does not exist ($opt{'reports'}), please make sure it is a writable directory!";
			return 0;
		}

		# setup the dirwatch alias
		if ( ! exists $opt{'dirwatch_alias'} or ! defined $opt{'dirwatch_alias'} ) {
			if ( DEBUG ) {
				warn 'Using default dirwatch_alias = POEGateway-Mailer-DirWatch';
			}

			# Set the default
			$opt{'dirwatch_alias'} = 'POEGateway-Mailer-DirWatch';
		}

		# setup the dirwatch interval
		if ( ! exists $opt{'dirwatch_interval'} or ! defined $opt{'dirwatch_interval'} ) {
			if ( DEBUG ) {
				warn 'Using default dirwatch_interval = 120';
			}

			# Set the default
			$opt{'dirwatch_interval'} = 120;
		}
	}

	# setup the alias
	if ( ! exists $opt{'alias'} or ! defined $opt{'alias'} ) {
		if ( DEBUG ) {
			warn 'Using default ALIAS = POEGateway-Mailer';
		}

		# Set the default
		$opt{'alias'} = 'POEGateway-Mailer';
	}

	# setup the mailing subprocess
	if ( ! exists $opt{'mailer'} or ! defined $opt{'mailer'} ) {
		if ( DEBUG ) {
			warn 'Using default mailer = SMTP';
		}

		# Set the default
		$opt{'mailer'} = 'SMTP';
	} else {
		# TODO verify the mailer actually exists?
	}

	# setup the mailing subprocess config
	if ( ! exists $opt{'mailer_conf'} or ! defined $opt{'mailer_conf'} ) {
		if ( DEBUG ) {
			warn 'Using default mailer_conf = {}';
		}

		# Set the default
		$opt{'mailer_conf'} = {};
	} else {
		if ( ref( $opt{'mailer_conf'} ) ne 'HASH' ) {
			warn "The mailer_conf argument is not a valid HASH reference!";
			return 0;
		}
	}

	# setup the host aliases
	if ( ! exists $opt{'host_aliases'} or ! defined $opt{'host_aliases'} ) {
		if ( DEBUG ) {
			warn 'Using default host_aliases = {}';
		}

		# Set the default
		$opt{'host_aliases'} = {};
	} else {
		if ( ref( $opt{'host_aliases'} ) ne 'HASH' ) {
			warn "The host_aliases argument is not a valid HASH reference!";
			return 0;
		}
	}

	# Create our session
	POE::Session->create(
		__PACKAGE__->inline_states(),
		'heap'	=>	{
			'ALIAS'			=> $opt{'alias'},
			'MAILER'		=> $opt{'mailer'},
			'MAILER_CONF'		=> $opt{'mailer_conf'},
			'HOST_ALIASES'		=> $opt{'host_aliases'},

			( exists $opt{'poegateway'} ? ( 'POEGATEWAY' => 1 ) : (
				'REPORTS'		=> $opt{'reports'},
				'DIRWATCH_ALIAS'	=> $opt{'dirwatch_alias'},
				'DIRWATCH_INTERVAL'	=> $opt{'dirwatch_interval'},
			) ),

			'NEWFILES'		=> [],
			'WHEEL'			=> undef,
			'WHEEL_WORKING'		=> 0,
			'WHEEL_RETRIES'		=> 0,
			'SHUTDOWN'		=> 0,
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

	# spawn the dirwatch
	if ( ! exists $_[HEAP]->{'POEGATEWAY'} ) {
		require POE::Component::DirWatch;
		POE::Component::DirWatch->import;	# needed to set AIO stuff, darn it!
		$_[HEAP]->{'DIRWATCH'} = POE::Component::DirWatch->new(
			'alias'		=> $_[HEAP]->{'DIRWATCH_ALIAS'},
			'directory'	=> $_[HEAP]->{'REPORTS'},
			'file_callback'	=> $_[SESSION]->postback( 'got_new_file' ),
			'interval'	=> $_[HEAP]->{'DIRWATCH_INTERVAL'},
		);
	}

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

	# tell dirwatcher to shutdown
	if ( exists $_[HEAP]->{'DIRWATCH'} and defined $_[HEAP]->{'DIRWATCH'} ) {
		$_[HEAP]->{'DIRWATCH'}->shutdown;
		undef $_[HEAP]->{'DIRWATCH'};
	}

	$_[HEAP]->{'SHUTDOWN'} = 1;
	undef $_[HEAP]->{'WHEEL'};

	return;
}

# received a postback from DirWatch
sub got_new_file : State {
	my $file = $_[ARG1]->[0]->stringify;

	# Have we seen this file before?
	if ( ! grep { $_ eq $file } @{ $_[HEAP]->{'NEWFILES'} } ) {
		if ( DEBUG ) {
			warn "Got a new file -> $file";
		}

		# Add it to the newfile list
		push( @{ $_[HEAP]->{'NEWFILES'} }, $file );

		# We're done!
		$_[KERNEL]->yield( 'send_report' );
	}

	return;
}

# We got a report directly from the POEGateway httpd!
sub http_report : State {
	my $report = $_[ARG0];

	if ( DEBUG ) {
		warn "Got a new report from POEGateway -> $report->{subject}";
	}

	# Shove it in the queue
	push( @{ $_[HEAP]->{'NEWFILES'} }, $report );
	$_[KERNEL]->yield( 'send_report' );
	return;
}

sub send_report : State {
	if ( ! defined $_[HEAP]->{'WHEEL'} ) {
		# Setup the subprocess!
		$_[KERNEL]->yield( 'setup_wheel' );
		return;
	}

	if ( $_[HEAP]->{'WHEEL_WORKING'} ) {
		return;
	}

	# Grab the first file from the array
	my $file = $_[HEAP]->{'NEWFILES'}->[0];
	if ( ! defined $file ) {
		return;
	}

	# Is it a filename or hashref?
	my $data;
	if ( ! ref $file ) {
		# TODO Sometimes DirWatch gives us a new file notification *AFTER* we delete it... WTF???
		if ( ! -f $file ) {
			shift @{ $_[HEAP]->{'NEWFILES'} };
			return;
		}

		eval {
			$data = LoadFile( $file );
		};
		if ( $@ ) {
			if ( DEBUG ) {
				warn "Failed to load '$file': $@";
			}

			$_[KERNEL]->yield( 'save_failure', shift @{ $_[HEAP]->{'NEWFILES'} }, 'load' );
			return;
		} elsif ( ! defined $data ) {
			if ( DEBUG ) {
				warn "Malformed file: $file";
			}
			$_[KERNEL]->yield( 'save_failure', shift @{ $_[HEAP]->{'NEWFILES'} }, 'malformed' );
			return;
		}
	} else {
		$data = $file;
	}

	# do some housekeeping
	if ( exists $_[HEAP]->{'HOST_ALIASES'}->{ $data->{'_sender'} } ) {
		# do some regex tricks...
		$data->{'report'} =~ s/Environment\s+variables\:\n\n/Environment variables:\n\n    CPAN_SMOKER = $_[HEAP]->{'HOST_ALIASES'}->{ $data->{'_sender'} } ( $data->{'_sender'} )\n/;
	}

	# send it off to the subprocess!
	$_[HEAP]->{'WHEEL'}->put( {
		'ACTION'	=> 'SEND',
		'DATA'		=> $data,
	} );
	$_[HEAP]->{'WHEEL_WORKING'} = 1;

	return;
}

sub save_failure : State {
	my( $file, $reason ) = @_[ARG0, ARG1];

	# Get the filename only
	my $filename = ( File::Spec->splitpath( $file ) )[2];

	# Create the "fail" subdirectory if it doesn't exist
	my $faildir = File::Spec->catdir( $_[HEAP]->{'REPORTS'}, "fail" );
	if ( ! -d $faildir ) {
		mkdir( $faildir ) or die "Unable to mkdir '$faildir': $!";
	}

	# come up with a new name and move it
	$filename = File::Spec->catfile( $faildir, $filename . '.' . $reason );
	move( $file, $filename ) or die "Unable to move '$file': $!";

	# done with saving, let's retry the next report
	$_[KERNEL]->yield( 'send_report' );

	return;
}

sub setup_wheel : State {
	# skip setup if we already have a wheel, eh?
	if ( defined $_[HEAP]->{'WHEEL'} ) {
		$_[KERNEL]->yield( 'send_report' );
		return;
	}

	# Check if we should set up the wheel
	if ( $_[HEAP]->{'WHEEL_RETRIES'} == 5 ) {
		die 'Tried ' . 5 . ' times to create a subprocess and is giving up...';
	}

	# Set up the SubProcess we communicate with
	my $pkg = __PACKAGE__ . '::' . $_[HEAP]->{'MAILER'};
	$_[HEAP]->{'WHEEL'} = POE::Wheel::Run->new(
		# What we will run in the separate process
		'Program'	=>	"$^X -M$pkg -e '${pkg}::main()'",

		# Kill off existing FD's
		'CloseOnCall'	=>	1,

		# Redirect errors to our error routine
		'ErrorEvent'	=>	'ChildError',

		# Send child died to our child routine
		'CloseEvent'	=>	'ChildClosed',

		# Send input from child
		'StdoutEvent'	=>	'Got_STDOUT',

		# Send input from child STDERR
		'StderrEvent'	=>	'Got_STDERR',

		# Set our filters
		'StdinFilter'	=>	POE::Filter::Reference->new(),		# Communicate with child via Storable::nfreeze
		'StdoutFilter'	=>	POE::Filter::Line->new(),		# Receive input via plain lines ( OK/NOK )
		'StderrFilter'	=>	POE::Filter::Line->new(),		# Plain ol' error lines
	);

	# Check for errors
	if ( ! defined $_[HEAP]->{'WHEEL'} ) {
		die 'Unable to create a new wheel!';
	} else {
		# smart CHLD handling
		if ( $_[KERNEL]->can( "sig_child" ) ) {
			$_[KERNEL]->sig_child( $_[HEAP]->{'WHEEL'}->PID => 'Got_CHLD' );
		} else {
			$_[KERNEL]->sig( 'CHLD', 'Got_CHLD' );
		}

		# Increment our retry count
		$_[HEAP]->{'WHEEL_RETRIES'}++;

		# it's obviously not working...
		$_[HEAP]->{'WHEEL_WORKING'} = 0;

		# Since we created a new wheel, we have to give it the config
		$_[HEAP]->{'WHEEL'}->put( {
			'ACTION'	=> 'CONFIG',
			'DATA'		=> $_[HEAP]->{'MAILER_CONF'},
		} );

		# Do we need to send something?
		$_[KERNEL]->yield( 'send_report' );
	}

	return;
}

# Handles child DIE'ing
sub ChildClosed : State {
	# Emit debugging information
	if ( DEBUG ) {
		warn "The subprocess died!";
	}

	# Get rid of the wheel
	undef $_[HEAP]->{'WHEEL'};

	# Should we process the next file?
	if ( scalar @{ $_[HEAP]->{'NEWFILES'} } and ! $_[HEAP]->{'SHUTDOWN'} ) {
		$_[KERNEL]->yield( 'wheel_setup' );
	}

	return;
}

# Handles child error
sub ChildError : State {
	# Emit warnings only if debug is on
	if ( DEBUG ) {
		# Copied from POE::Wheel::Run manpage
		my ( $operation, $errnum, $errstr ) = @_[ ARG0 .. ARG2 ];
		warn "Got an $operation error $errnum: $errstr\n";
	}

	return;
}

# Got a CHLD event!
sub Got_CHLD : State {
	$_[KERNEL]->sig_handled();
	return;
}

# Handles child STDERR output
sub Got_STDERR : State {
	my $input = $_[ARG0];

	# Skip empty lines as the POE::Filter::Line manpage says...
	if ( $input eq '' ) { return }

	warn "Got STDERR from child, which should never happen ( $input )";

	return;
}

# Handles child STDOUT output
sub Got_STDOUT : State {
	# The data!
	my $data = $_[ARG0];

	if ( DEBUG ) {
		warn "Got stdout ($data)";
	}

	# We should get: "OK" or "NOK $error"
	if ( $data =~ /^N?OK/ ) {
		my $file = shift( @{ $_[HEAP]->{'NEWFILES'} } );
		$_[HEAP]->{'WHEEL_WORKING'} = 0;

		if ( $data eq 'OK' ) {
			if ( ! ref $file ) {
				if ( DEBUG ) {
					warn "Successfully sent report: $file";
				}

				# get rid of the file and move on!
				unlink( $file ) or die "Unable to delete $file: $!";
			} else {
				if ( DEBUG ) {
					warn "Successfully sent report: $file->{subject}";
				}
			}

			$_[KERNEL]->yield( 'send_report' );
		} elsif ( $data =~ /^NOK\s+(.+)$/ ) {
			my $err = $1;

			# argh!
			if ( ! ref $file ) {
				warn "Unable to send report for '$file': $err";
				$_[KERNEL]->yield( 'save_failure', $file, 'send' );
			} else {
				warn "Unable to send report for '$file->{subject}': $err";
				$_[KERNEL]->yield( 'send_report' );
			}
		}
	} elsif ( $data =~ /^ERROR\s+(.+)$/ ) {
		# hmpf!
		my $err = $1;
		warn "Unexpected error: $err";
	} else {
		warn "Unknown line: $data";
	}

	return;
}

1;
__END__

=for stopwords DirWatch TODO VM gentoo ip poegateway

=head1 NAME

Test::Reporter::POEGateway::Mailer - Sends reports via a configured mailer

=head1 SYNOPSIS

	#!/usr/bin/perl
	use strict; use warnings;
	use Test::Reporter::POEGateway::Mailer;

	# A sample using SMTP+SSL with AUTH
	Test::Reporter::POEGateway::Mailer->spawn(
		'mailer'	=> 'SMTP',
		'mailer_conf'	=> {
			'smtp_host'	=> 'smtp.mydomain.com',
			'smtp_opts'	=> {
				'Port'	=> '465',
				'Hello'	=> 'mydomain.com',
			},
			'ssl'		=> 1,
			'auth_user'	=> 'myuser',
			'auth_pass'	=> 'mypass',
		},
	);

	# run the kernel!
	POE::Kernel->run();

=head1 ABSTRACT

This module is the companion to L<Test::Reporter::POEGateway> and handles the task of actually mailing out reports. Typically you just
spawn the module, select a mailer and let it do it's work.

=head1 DESCRIPTION

Really, all you have to do is load the module and call it's spawn() method:

	use Test::Reporter::POEGateway::Mailer;
	Test::Reporter::POEGateway::Mailer->spawn( ... );

This method will return failure on errors or return success. Normally you would select the mailer and set various options.

This constructor accepts either a hashref or a hash, valid options are:

=head3 alias

This sets the alias of the session.

The default is: POEGateway-Mailer

=head3 poegateway

If this option is present in the arguments, this module will receive reports directly from the L<Test::Reporter::POEGateway> session. You cannot
enable this option and use the reports argument below at the same time. If you enable this, this component will not use L<POE::Component::DirWatch>
and ignores any options for it.

The default is: undef ( not used )

	use Test::Reporter::POEGateway;
	use Test::Reporter::POEGateway::Mailer;

	Test::Reporter::POEGateway->spawn(
		'mailer'	=> 'mymailer',
	);
	Test::Reporter::POEGateway::Mailer->spawn(
		'alias'		=> 'mymailer',
		'poegateway'	=> 1,
		'mailer'	=> 'SMTP',
		'mailer_conf'	=> { ... },
	);

=head3 reports

This sets the path where it will read received report submissions. Should be the same path you set in L<Test::Reporter::POEGateway>.

NOTE: If this module fails to send a report due to various reasons, it will move the file to '$reports/fail' to avoid re-sending it over and over.

The default is: $ENV{HOME}/cpan_reports

=head3 mailer

This sets the mailer subclass. The only one bundled with this distribution is L<Test::Reporter::POEGateway::Mailer::SMTP>.

NOTE: This module automatically prepends "Test::Reporter::POEGateway::Mailer::" to the string.

The default is: SMTP

=head3 mailer_conf

This sets the configuration for the selected mailer. Please look at the POD for your selected mailer for what options is accepted.

NOTE: This needs to be a hashref!

The default is: {}

=head3 dirwatch_alias

This sets the alias of the L<POE::Component::DirWatch> session. Normally you don't need to touch the DirWatch session, but it is useful in certain
situations. For example, if you wanted to pause the watcher or re-configure - all you need to do is to send events to this alias.

The default is: POEGateway-Mailer-DirWatch

=head3 dirwatch_interval

This sets the interval passed to L<POE::Component::DirWatch>, please see the pod for more detail.

The default is: 120

=head3 host_aliases

This is a value-added change from L<Test::Reporter::HTTPGateway>. This sets up a hash of ip => description. When the mailer sends a report, it
will munge the report by adding a "fake" environment variable: SMOKER_HOST and put the description there if the sender ip matches. This is extremely
useful if you have multiple smokers running and want to keep track of which smoker sent which report.

Here's a sample alias list:
	host_aliases => {
		'192.168.0.2' => 'my laptop',
		'192.168.0.5' => 'my smoke box',
		'192.168.0.7' => 'gentoo VM on smoke box',
	},

The default is: {}

=head2 Commands

There is only one command you can use, as this is a very simple module.

=head3 shutdown

Tells this module to shut down the underlying httpd session and terminate itself.

	$_[KERNEL]->post( 'POEGateway-Mailer', 'shutdown' );

=head2 More Ideas

Additional mailers ( sendmail ), that's for sure. However, L<Test::Reporter::POEGateway::Mailer::SMTP> fits the bill for me; I'm lazy now :)

=head1 EXPORT

None.

=head1 SEE ALSO

L<Test::Reporter::POEGateway>

L<Test::Reporter::POEGateway::Mailer::SMTP>

=head1 AUTHOR

Apocalypse E<lt>apocal@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2009 by Apocalypse

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
