# Declare our package
package Test::Reporter::POEGateway::Mailer::Base;
use strict; use warnings;

# Initialize our version
use vars qw( $VERSION );
$VERSION = '0.01';

# Load some necessary modules
use POE::Filter::Reference;

# Sysread error hits
my $sysreaderr = 0;

# Our Filter object
my $filter = POE::Filter::Reference->new();

# This is the subroutine that will get executed upon the fork() call by our parent
sub main {
	# Autoflush to avoid weirdness
	$|++;

	# set binmode, thanks RT #43442
	binmode( STDIN );
	binmode( STDOUT );

	# Okay, now we listen for commands from our parent :)
	while ( sysread( STDIN, my $buffer = '', 1024 ) ) {
		# Feed the line into the filter
		my $data = $filter->get( [ $buffer ] );

		# INPUT STRUCTURE IS:
		# $d->{'ACTION'}	= SCALAR	->	WHAT WE SHOULD DO
		# $d->{'DATA'}		= HASH		->	DATA FOR THE ACTION

		# Process each data structure
		foreach my $input ( @$data ) {
			# Now, we do the actual work depending on what kind of query it was
			if ( $input->{'ACTION'} eq 'CONFIG' ) {
				# Setup the config
				DO_CONFIG( $input->{'DATA'} );
			} elsif ( $input->{'ACTION'} eq 'SEND' ) {
				# Send a report!
				my $ret = DO_SEND( $input->{'DATA'} );
				if ( defined $ret ) {
					DO_SENDFINISH( 0, $ret );
				} else {
					DO_SENDFINISH( 1, $input->{'DATA'}->{'_file'} );
				}
			} else {
				# Unrecognized action!
				print "ERROR Unknown action ($input->{'ACTION'})\n";
			}
		}
	}

	# Arrived here due to error in sysread/etc
	print "ERROR SYSREAD\n";

	# If we got more than 5 sysread errors, abort!
	if ( ++$sysreaderr == 5 ) {
		exit 0;
	} else {
		goto &main;
	}

	return;
}

sub DO_SENDFINISH {
	my( $result, $file ) = @_;

	if ( $result ) {
		print "OK $file\n";
	} else {
		print "NOK $file\n";
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
