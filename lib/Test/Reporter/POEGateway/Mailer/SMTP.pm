# Declare our package
package Test::Reporter::POEGateway::Mailer::SMTP;
use strict; use warnings;

# Initialize our version
use vars qw( $VERSION );
$VERSION = '0.01';

# Set our base
use base 'Test::Reporter::POEGateway::Mailer::Base';

# The mailer config we use
my $config = undef;

# The smtp object
my $smtp = undef;

# initializes our config
sub DO_CONFIG {
	$config = shift;

	# set some sane defaults
	$config->{'to'} = 'cpan-testers@perl.org' if ! exists $config->{'to'};
	$config->{'smtp_host'} = 'localhost' if ! exists $config->{'smtp_host'};
	$config->{'smtp_opts'} = {} if ! exists $config->{'smtp_opts'};

	# Get rid of our old smtp if needed
	undef $smtp;

	return;
}

sub setup_smtp {
	return if defined $smtp;

	# Do we want ssl?
	my $pkg = 'Net::SMTP';
	if ( exists $config->{'ssl'} ) {
		$pkg .= '::SSL';
	}

	eval "require $pkg"; die $@ if $@;
	$smtp = $pkg->new(
		$config->{'smtp_host'},
		%{ $config->{'smtp_opts'} },
	);

	# Do AUTH if needed
	if ( exists $config->{'auth_user'} ) {
		if ( ! $smtp->auth( $config->{'auth_user'}, $config->{'auth_pass'} ) ) {
			return "Unable to AUTH to the smtp server";
		}
	}

	return;
}

sub DO_SEND {
	my $data = shift;

	# init the smtp if needed
	my $ret = setup_smtp();
	if ( defined $ret ) {
		return $ret;
	}

	# send it!
	if ( ! $smtp->mail( $data->{'from'} ) ) {
		return "Unable to set 'from' address";
	}

	if ( ! $smtp->to( $config->{'to'} ) ) {
		return "Unable to set 'to' address";
	}

	# Prepare the data
	my $msg =	"To: $config->{'to'}\n";
	$msg .=		"Subject: $data->{'subject'}\n";
	$msg .=		"X-Reported-Via: $data->{'_via'}\n";
	$msg .=		"X-Reported-FromHost: $data->{'_host'}\n" if exists $data->{'_host'};
	$msg .=		"\n";
	$msg .=		$data->{'report'} . "\n";

	if ( ! $smtp->data( $msg ) ) {
		return "Unable to send message";
	}

	# Successful send of message!
	return;
}

1;
__END__

=head1 NAME

Test::Reporter::POEGateway::Mailer::SMTP - Sends reports via Net::SMTP

=head1 SYNOPSIS

	#!/usr/bin/perl
	use strict; use warnings;
	use Test::Reporter::POEGateway::Mailer;

	# let it do the work!
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

This module sends reports via Net::SMTP with some extra options.

=head1 DESCRIPTION

You normally use this module via the L<Test::Reporter::POEGateway::Mailer> module. You would need to configure the 'mailer' to 'SMTP' and
set any 'mailer_conf' options if needed.

The config this module accepts is:

=head3 smtp_host

The smtp server we will use to send emails.

The default is: localhost

=head3 smtp_opts

Extra options to pass to Net::SMTP if needed. Useful to set the port, for example.

The default is: {}

=head3 to

The destination address we will send reports to.

The default is: cpan-testers@perl.org

=head3 ssl

If enabled, this module will use Net::SMTP::SSL and attempt a secure connection to the host.

The default is: false

=head3 auth_user

The user to use for SMTP AUTH to the server. If defined, we will issue an AUTH command to the server. If not, we will skip this step on connection.

The default is: undef

=head3 auth_pass

The password to use for SMTP AUTH to the server.

The default is: undef

=head1 EXPORT

None.

=head1 SEE ALSO

L<Test::Reporter::POEGateway::Mailer>

L<Net::SMTP>

L<Net::SMTP::SSL>

=head1 AUTHOR

Apocalypse E<lt>apocal@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2009 by Apocalypse

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
