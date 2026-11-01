package Plugins::LangID::Plugin;

# LangID - offline language identification for Lyrion Music Server.
#
# The plugin has no settings page and no UI of its own. It ships the static
# `langid` helper binary and exposes it to other plugins through
# Plugins::LangID::API. For manual testing it also registers the LMS CLI
# command:
#
#   langid detect <text>
#
# which returns language, name, iso, confidence and scores.

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use JSON::PP ();

use Slim::Control::Request;
use Slim::Utils::Log;

use Plugins::LangID::API;

our $VERSION;

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.langid',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_LANGID',
} );

sub initPlugin {
	my ($class) = @_;

	$VERSION = $class->_pluginDataFor('version') || Plugins::LangID::API->version;

	# Test hook only: `langid detect <text>` via CLI or JSON-RPC. The plugin
	# works without any user-facing command or settings page.
	Slim::Control::Request::addDispatch(
		[ 'langid', 'detect', '_text' ],
		[ 0, 1, 1, \&_cliDetect ],
	);

	$class->SUPER::initPlugin();

	if ( $log->is_info ) {
		$log->info( 'LangID helper binary: ' . Plugins::LangID::API->binary_path );
	}

	return;
}

sub shutdownPlugin {
	return;
}

sub _cliDetect {
	my $request = shift;

	my $text = $request->getParam('_text');
	$text = '' unless defined $text;

	# The helper runs asynchronously; keep the CLI request open until the
	# callback has added the results.
	$request->setStatusProcessing();

	Plugins::LangID::API->detect(
		$text,
		sub {
			my ($result) = @_;

			if ( defined $result->{error} ) {
				$log->error( 'langid detect failed: ' . $result->{error} );
				$request->addResult( 'error', $result->{error} );
			}
			else {
				$request->addResult( 'language',   defined $result->{language} ? $result->{language} : '' );
				$request->addResult( 'name',       defined $result->{name} ? $result->{name} : '' );
				$request->addResult( 'iso',        defined $result->{iso} ? $result->{iso} : '' );
				$request->addResult( 'confidence', defined $result->{confidence} ? $result->{confidence} : 0 );
				$request->addResult( 'scores',     JSON::PP::encode_json( $result->{scores} || [] ) );
			}

			$request->setStatusDone();

			return;
		}
	);

	return;
}

1;
