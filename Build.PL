# Build.PL
use strict; use warnings;
use Module::Build;

my $build = Module::Build->new(
	# look up Module::Build::API for the info!
	'dynamic_config'	=> 0,
	'module_name'		=> 'Test::Reporter::POEGateway',
	'license'		=> 'perl',

	'dist_abstract'		=> "A Test::Reporter::HTTPGateway using the power of POE",
	'dist_author'		=> 'Apocalypse <APOCAL@cpan.org>',

	'create_packlist'	=> 1,
	'create_makefile_pl'	=> 'traditional',
	'create_readme'		=> 1,

	'test_files'		=> 't/*.t',

	'add_to_cleanup'	=> [ 'META.yml', 'Makefile.PL', 'README', 'Makefile' ],	# automatically generated

	'requires'		=> {
		# POE Stuff
		'POE'					=> 0,
		'POE::Session::AttributeBased'		=> 0,
		'POE::Component::Server::SimpleHTTP'	=> 0,
		'POE::Component::DirWatch'		=> 0,

		# FIXME POE stuff that Test::Dependencies needs to see
		'POE::Session'			=> 0,
		'POE::Wheel::Run'		=> 0,
		'POE::Filter::Reference'	=> 0,
		'POE::Filter::Line'		=> 0,

		# Misc stuff
		'HTTP::Request::Params'		=> 0,
		'YAML::Tiny'			=> 0,
		'Digest::SHA'			=> 0,
		'File::Spec'			=> 0,
		'Array::Unique'			=> 0,

		# for our mailers
		'Net::SMTP'			=> 0,

		# set our minimum perl version
		'perl'				=> '5.006',
	},

	'recommends'		=> {
		# for our mailers
		'Net::SMTP::SSL'		=> 0,
		'Authen::SASL'			=> 0,
	},
);

# all done!
$build->create_build_script;
