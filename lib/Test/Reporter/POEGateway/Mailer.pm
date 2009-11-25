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
use POE::Component::DirWatch;
use base 'POE::Session::AttributeBased';

# Misc modules we need
use YAML::Tiny qw( LoadFile );
use File::Spec;
use Array::Unique;

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

	# setup the path to read reports from
	if ( ! exists $opt{'reports'} or ! defined $opt{'reports'} ) {
		my $path = File::Spec->catdir( $ENV{HOME}, 'cpan_reports' );
		if ( DEBUG ) {
			warn "Using default REPORTS = '$path'";
		}

		# Set the default
		$opt{'reports'} = $path;
	}

	# validate the report path
	if ( ! -d $opt{'reports'} ) {
		warn "The report path does not exist ($opt{'reports'}), please make sure it is a writable directory!";
		return 0;
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
		# We cannot use the "Base" mailer, hah!
		if ( $opt{'mailer'} eq 'Base' ) {
			warn "The mailer, 'Base' is not supposed to be used directly!";
			return 0;
		}
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
			warn 'Using default dirwatch_interval = 30';
		}

		# Set the default
		$opt{'dirwatch_interval'} = 30;
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

	# create our unique newfiles array
	my @newfiles = ();
	tie @newfiles, 'Array::Unique';

	# Create our session
	POE::Session->create(
		__PACKAGE__->inline_states(),
		'heap'	=>	{
			'ALIAS'			=> $opt{'alias'},
			'MAILER'		=> $opt{'mailer'},
			'MAILER_CONF'		=> $opt{'mailer_conf'},
			'REPORTS'		=> $opt{'reports'},
			'DIRWATCH_ALIAS'	=> $opt{'dirwatch_alias'},
			'DIRWATCH_INTERVAL'	=> $opt{'dirwatch_interval'},
			'HOST_ALIASES'		=> $opt{'host_aliases'},

			'DIRWATCH'		=> undef,
			'NEWFILES'		=> \@newfiles,
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
	my $watcher = POE::Component::DirWatch->new(
		'alias'		=> $_[HEAP]->{'DIRWATCH_ALIAS'},
		'directory'	=> $_[HEAP]->{'REPORTS'},
		'file_callback'	=> $_[SESSION]->postback( 'got_new_file' ),
		'interval'	=> $_[HEAP]->{'DIRWATCH_INTERVAL'},
	);
	$_[HEAP]->{'DIRWATCH'} = $watcher;

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
	$_[HEAP]->{'DIRWATCH'}->shutdown;
	undef $_[HEAP]->{'DIRWATCH'};

	$_[HEAP]->{'SHUTDOWN'} = 1;

	return;
}

# received a postback from DirWatch
sub got_new_file : State {
	my $file = $_[ARG1]->[0];

	if ( DEBUG ) {
		warn "Got a new file -> $file";
	}

	# Add it to the newfile list
	push( @{ $_[HEAP]->{'NEWFILES'} }, $file->stringify );

	# We're done!
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

	my $data = LoadFile( $file );
	if ( ! defined $data ) {
		if ( DEBUG ) {
			warn "Malformed file: $file";
		}
		return;
	}

	# do some housekeeping
	if ( exists $_[HEAP]->{'HOST_ALIASES'}->{ $data->{'_sender'} } ) {
		$data->{'_host'} = $_[HEAP]->{'HOST_ALIASES'}->{ $data->{'_sender'} };
	}

	# send it off to the subprocess!
	$_[HEAP]->{'WHEEL'}->put( {
		'ACTION'	=> 'SEND',
		'DATA'		=> $data,
	} );
	$_[HEAP]->{'WHEEL_WORKING'} = 1;

	return;
}

sub setup_wheel : State {
	# skip setup if we already have a wheel, eh?
	if ( defined $_[HEAP]->{'WHEEL'} ) {
		$_[KERNEL]->yield( 'ready_send' );
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

		if ( $data eq 'OK' ) {
			if ( DEBUG ) {
				warn "Successfully sent $file report";
			}

			# get rid of the file and move on!
			unlink( $file ) or warn "Unable to delete $file: $!";
		} elsif ( $data =~ /^NOK\s+(.+)$/ ) {
			my $err = $1;

			# argh!
			warn "Unable to send report: $err";
		}

		# Send another report?
		$_[HEAP]->{'WHEEL_WORKING'} = 0;
		$_[KERNEL]->yield( 'send_report' );
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

=head1 NAME

POE::Devel::ProcAlike - Exposing the guts of POE via FUSE

=head1 SYNOPSIS

	#!/usr/bin/perl
	use strict; use warnings;
	use POE::Devel::ProcAlike;
	use POE;

	# let it do the work!
	POE::Devel::ProcAlike->spawn();

	# create our own "fake" session
	POE::Session->spawn(
		'inline_states'	=> {
			'_start'	=> sub {
				$_[KERNEL]->alias_set( 'foo' );
				$_[KERNEL]->yield( 'timer' );
				$_[KERNEL]->sig( 'INT' => 'int_handler' );
			},
			'timer'		=> sub {
				$_[KERNEL]->delay_set( 'timer' => 60 );
			},
			'int_handler'	=> sub {
				$_[KERNEL]->post( 'poe-devel-procalike', 'shutdown' );
			},
		},
		'heap'		=> {
			'fakedata'	=> 1,
			'oomph'		=> 'haha',
		},
	);

	# run the kernel!
	POE::Kernel->run();

=head1 ABSTRACT

Using this module will let you expose the guts of a running POE program to the filesystem via FUSE. This also
includes a lot of debugging information about the running perl process :)

=head1 DESCRIPTION

Really, all you have to do is load the module and call it's spawn() method:

	use POE::Devel::ProcAlike;
	POE::Devel::ProcAlike->spawn( ... );

This method will return failure on errors or return success. Normally you don't need to pass any arguments to it,
but if you want to do zany things, you can! Note: the spawn() method will construct a singleton.

This constructor accepts either a hashref or a hash, valid options are:

=head3 fuseopts

This is a hashref of options to pass to the underlying FUSE component, L<POE::Component::Fuse>'s spawn() method. Useful
to change the default mountpoint, for example. Setting the mountpoint is a MUST if you have multiple scripts running
and want to use this.

The default fuseopts is to enable: umount, mkdir, rmdir, and mountpoint of "/tmp/poefuse_$$". You cannot override those
options: alias, vfilesys, and session.

The default is: undef

=head3 vfilesys

This is a L<Filesys::Virtual::Async> subclass object you can provide to expose your own data in the filesystem. It
will be mounted under /misc in the directory.

The default is: undef

=head2 Commands

There is only a few commands you can use, because this module does nothing except export the data to the filesystem.

This module uses a static alias: "poe-devel-procalike" so you can always interact with it anytime it is loaded.

=head3 shutdown

Tells this module to shut down the underlying FUSE session and terminate itself.

	$_[KERNEL]->post( 'poe-devel-procalike', 'shutdown' );

=head3 register

( ONLY for PoCo module authors! )

Registers your L<Filesys::Virtual::Async> subclass with ProcAlike so you can expose your data in the filesystem.

Note: You MUST call() this event so ProcAlike will get the proper caller() info to determine mountpath. Furthermore,
ProcAlike only allows one registration per module!

	$_[KERNEL]->call( 'poe-devel-procalike', 'register', $myfsv );

=head3 unregister

( ONLY for PoCo module authors! )

Removes your registered object from the filesystem.

Note: You MUST call() this event so ProcAlike will get the proper caller() info to determine mountpath.

	$_[KERNEL]->call( 'poe-devel-procalike', 'unregister' );

=head2 Notes for PoCo module authors

You can expose your own data in any format you want! The way to do this is to create your own L<Filesys::Virtual::Async>
object and give it to ProcAlike. Here's how I would do the logic:

	my $ses = $_[KERNEL]->alias_resolve( 'poe-devel-procalike' );
	if ( $ses ) {
		require My::FsV; # a subclass of Filesys::Virtual::Async
		my $fsv = My::FsV->new( ... );
		if ( ! $_[KERNEL]->call( $ses, 'register', $fsv ) ) {
			warn "unable to register!";
		}
	}

Keep in mind that the alias is static, and you should be executing this code in the "preferred" package. What I mean
by this is that ProcAlike will take the info from caller() and determine the mountpoint from it. Here's an example:

	POE::Component::SimpleHTTP does a register, it will be mounted in:
	/modules/poe-component-simplehttp

	My::Module::SubClass does a register, it will be mounted in:
	/modules/my-module-subclass

Furthermore, ProcAlike only allows each package to register once, so you have to figure out how to create a singleton
and use that if your PoCo has been spawned N times. The reasoning behind this is to have a "uniform" filesystem
that would be valid across multiple invocations. If we allowed module authors to register any name, then we would
end up with possible collisions and wacky schemes like "$pkg$ses->ID" as the name...

Also, here's a tip: you don't have to implement the entire L<Filesys::Virtual::Async> API because FUSE doesn't use
them all! The ones you would have to do is: rmtree, scandir, move, copy, load, readdir, rmdir, mkdir, rename, mknod,
unlink, chmod, truncate, chown, utime, stat, write, open. To save even more time, you can subclass the
L<Filesys::Virtual::Async::inMemory> module and set readonly to true. Then you would have to subclass only those
methods: readdir, stat, open.

=head2 TODO

=over 4

=item * tunable parameters

Various people in #poe@magnet suggested having a system where we could do "sysctl-like" stuff with this filesystem.
I'm not entirely sure what we can "tune" in regards to POE but if you have any ideas please feel free to drop them
my way and we'll see what we can do :)

=item * pipe support

Again, people suggested the idea of "telnetting" into the filesystem via a pipe. The interface could be something
like PoCo-DebugShell, and we could expand it to accept zany commands :)

=item * module memory usage

I talked with some people, and this problem is much more complex than you would think it is. If somebody could
let me know of a snippet that measures this, I would love to include it in the perl output!

=item * POE::API::Peek crashes

There are some functions that causes segfaults for me! They are: session_memory_size, signals_watched_by_session, and
kernel_memory_size. If the situation improves, I would love to reinstate them in ProcAlike and expose the data, so
please let me know if it does.

=item * more stats

More stats are always welcome! If you have any ideas, please drop me a line.

=back

=head1 EXPORT

None.

=head1 SEE ALSO

L<POE>

L<Fuse>

L<Filesys::Virtual::Async>

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc POE::Devel::ProcAlike

=head2 Websites

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/POE-Devel-ProcAlike>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/POE-Devel-ProcAlike>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=POE-Devel-ProcAlike>

=item * Search CPAN

L<http://search.cpan.org/dist/POE-Devel-ProcAlike>

=back

=head2 Bugs

Please report any bugs or feature requests to C<bug-poe-devel-procalike at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=POE-Devel-ProcAlike>.  I will be
notified, and then you'll automatically be notified of progress on your bug as I make changes.

=head1 AUTHOR

Apocalypse E<lt>apocal@cpan.orgE<gt>

Props goes to xantus who got me motivated to write this :)

=head1 COPYRIGHT AND LICENSE

Copyright 2009 by Apocalypse

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
