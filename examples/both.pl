#!/usr/bin/perl
use strict; use warnings;
use Test::Reporter::POEGateway;
use Test::Reporter::POEGateway::Mailer;

# let it do the work!
Test::Reporter::POEGateway->spawn();
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
