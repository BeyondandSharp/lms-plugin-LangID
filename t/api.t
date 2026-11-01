#!/usr/bin/perl

# Unit tests for Plugins::LangID::API.
#
# The tests are intentionally plain Perl: no Lyrion Music Server modules and no
# AnyEvent installation are required. t/lib contains a tiny AnyEvent shim that
# drives the asynchronous watchers, and t/fixtures/fake-langid stands in for
# the compiled helper binary so normal, timeout, crash and malformed-JSON
# paths can all be exercised deterministically.

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/lib";

use Config ();
use Encode ();
use File::Spec::Functions qw(catfile);
use Test::More;
use Time::HiRes ();

# Load the plugin module directly; it is not installed as a Perl distribution,
# so the package name cannot be resolved through @INC in the source tree.
require "$Bin/../API.pm";

my $API  = 'Plugins::LangID::API';
my $FAKE = "$Bin/fixtures/fake-langid";

chmod 0755, $FAKE unless -x $FAKE;

ok( -x $FAKE, 'fake langid helper is executable' );

# ---------------------------------------------------------------------------
# Module basics: version, plugin directory and platform mapping
# ---------------------------------------------------------------------------

like( $API->version, qr{\A\d+\.\d+\.\d+}, 'version() returns a version string' );

ok( -d $API->plugin_dir, 'plugin_dir() exists' );
ok( -f catfile( $API->plugin_dir, 'VERSION' ), 'plugin_dir() contains VERSION' );

my $platform = $API->platform;

if ( $^O eq 'linux' && ( $Config::Config{archname} || '' ) =~ m{\A(?:x86_64|amd64)}i ) {
	is( $platform, 'linux-x86_64', 'platform() maps linux/x86_64' );
}
elsif ( $^O eq 'linux' && ( $Config::Config{archname} || '' ) =~ m{\A(?:aarch64|arm64)}i ) {
	is( $platform, 'linux-aarch64', 'platform() maps linux/aarch64' );
}
elsif ( $^O eq 'darwin' ) {
	is( $platform, 'darwin-x86_64', 'platform() maps darwin' );
}
elsif ( $^O eq 'MSWin32' ) {
	is( $platform, 'windows-x86_64', 'platform() maps windows' );
}
else {
	ok( !defined $platform, "platform() returns undef for unsupported $^O" );
}

if ( defined $platform ) {
	like(
		$platform,
		qr{\A(?:linux-(?:x86_64|aarch64)|darwin-(?:x86_64|aarch64)|windows-(?:x86_64|aarch64))\z},
		'platform() uses a known directory name',
	);
}

{
	local $ENV{LANGID_BIN};

	my $default_path = $API->binary_path;

	like(
		$default_path,
		qr{/bin/(?:[a-z0-9_-]+/)?langid(?:[.]exe)?\z},
		"binary_path() resolves the bundled helper ($default_path)",
	);
}

{
	local $ENV{LANGID_BIN} = '/opt/langid/bin/langid';

	is( $API->binary_path, '/opt/langid/bin/langid', 'binary_path() honours LANGID_BIN' );
}

# ---------------------------------------------------------------------------
# available()
# ---------------------------------------------------------------------------

{
	local $ENV{LANGID_BIN} = '/nonexistent/langid';

	ok( !$API->available, 'available() is false for a missing binary' );
}

{
	local $ENV{LANGID_BIN} = $FAKE;

	ok( $API->available, 'available() is true for an executable helper' );
}

# ---------------------------------------------------------------------------
# sanitize_text()
# ---------------------------------------------------------------------------

{
	my $clean = $API->sanitize_text("  Hello\n\tWorld \x00!  ");

	is( $clean, 'Hello World !', 'sanitize_text() trims, collapses and strips controls' );

	is( $API->sanitize_text(''), '', 'sanitize_text() handles empty input' );
	is( $API->sanitize_text(undef), '', 'sanitize_text() handles undef input' );
}

{
	my $clean = $API->sanitize_text( Encode::encode( 'UTF-8', "\x{FEFF}  这是 \x{3000} 测试。  " ) );
	my $expected = Encode::encode( 'UTF-8', '这是 测试。' );

	is( $clean, $expected, 'sanitize_text() keeps UTF-8 text and drops the BOM' );
}

{
	my $long_text = Encode::encode( 'UTF-8', "\x{4E2D}" x 20_000 );
	my $clean     = $API->sanitize_text($long_text);

	is( length( Encode::decode( 'UTF-8', $clean ) ), 16_000, 'sanitize_text() caps the text at 16000 characters' );
}

# ---------------------------------------------------------------------------
# languages()
# ---------------------------------------------------------------------------

{
	local $ENV{LANGID_BIN} = $FAKE;

	my $languages = $API->languages;

	is_deeply( $languages, [qw(en ja ko zh)], 'languages() parses the --languages output' );
	is_deeply( $API->languages, $languages, 'languages() caches its result' );
}

{
	local $ENV{LANGID_BIN} = '/nonexistent/langid';

	is_deeply( $API->languages, [], 'languages() returns an empty list without a binary' );
}

# ---------------------------------------------------------------------------
# detect(): success
# ---------------------------------------------------------------------------

{
	local $ENV{LANGID_BIN}       = $FAKE;
	local $ENV{FAKE_LANGID_MODE} = 'normal';

	my $called = 0;
	my $result;

	$API->detect( '这是一个语言检测测试。', sub { $called++; $result = shift } );

	AnyEvent::pump( max_seconds => 10 );

	is( $called, 1, 'detect() invokes the callback exactly once' );
	is( ref $result, 'HASH', 'detect() passes a hash reference' );
	is( $result->{language}, 'zh', 'detect() normalises language to the ISO 639-1 code' );
	like( $result->{language}, qr{\A[a-z]{2}\z}, 'language is a lowercase ISO 639-1 code' );
	is( $result->{name}, 'Chinese', 'detect() keeps the display name in name' );
	is( $result->{iso}, 'zh', 'detect() returns the ISO 639-1 code' );
	cmp_ok( $result->{confidence}, '==', 0.98, 'detect() returns the confidence' );
	is_deeply(
		$result->{scores},
		[
			{ language => 'zh', name => 'Chinese', confidence => 0.98 },
			{ language => 'en', name => 'English', confidence => 0.02 },
		],
		'detect() normalises the score list to ISO codes',
	);
}

# ---------------------------------------------------------------------------
# detect(): empty input (the helper reports a null language)
# ---------------------------------------------------------------------------

{
	local $ENV{LANGID_BIN}       = $FAKE;
	local $ENV{FAKE_LANGID_MODE} = 'empty';

	my $result;

	$API->detect( '   ', sub { $result = shift } );

	AnyEvent::pump( max_seconds => 10 );

	is( ref $result, 'HASH', 'detect() returns a hash for empty input' );
	ok( !defined $result->{language}, 'empty input yields no language' );
	is( $result->{confidence}, 0, 'empty input yields confidence 0' );
	is_deeply( $result->{scores}, [], 'empty input yields no scores' );
}

# ---------------------------------------------------------------------------
# detect(): timeout, crash, malformed JSON and missing binary
# ---------------------------------------------------------------------------

{
	local $ENV{LANGID_BIN}       = $FAKE;
	local $ENV{FAKE_LANGID_MODE} = 'timeout';

	my $result;
	my $started = Time::HiRes::time();

	$API->detect( 'timeout test', sub { $result = shift } );

	AnyEvent::pump( max_seconds => 15 );

	my $elapsed = Time::HiRes::time() - $started;

	ok( ref $result eq 'HASH' && defined $result->{error}, 'detect() reports a timeout error' );
	like( $result->{error} // '', qr/timeout/i, 'timeout error mentions the timeout' );
	cmp_ok( $elapsed, '>=', 2, 'detect() waited for the 2s timeout' );
	cmp_ok( $elapsed, '<', 8, 'detect() escalated to KILL and finished in time' );
}

{
	local $ENV{LANGID_BIN}       = $FAKE;
	local $ENV{FAKE_LANGID_MODE} = 'crash';

	my $result;

	$API->detect( 'crash test', sub { $result = shift } );

	AnyEvent::pump( max_seconds => 10 );

	ok( ref $result eq 'HASH' && defined $result->{error}, 'detect() reports a crashing helper' );
	like( $result->{error} // '', qr/status 3/, 'crash error contains the exit status' );
	like( $result->{error} // '', qr/simulated crash/, 'crash error contains the stderr output' );
}

{
	local $ENV{LANGID_BIN}       = $FAKE;
	local $ENV{FAKE_LANGID_MODE} = 'badjson';

	my $result;

	$API->detect( 'bad json test', sub { $result = shift } );

	AnyEvent::pump( max_seconds => 10 );

	ok( ref $result eq 'HASH' && defined $result->{error}, 'detect() reports malformed JSON' );
	like( $result->{error} // '', qr/invalid JSON/i, 'malformed JSON error is descriptive' );
}

{
	local $ENV{LANGID_BIN} = '/nonexistent/langid';

	my $result;

	# No process is spawned, so the callback has to fire synchronously.
	$API->detect( 'missing binary', sub { $result = shift } );

	ok( ref $result eq 'HASH' && defined $result->{error}, 'detect() reports a missing binary' );
	like( $result->{error} // '', qr/not available/i, 'missing binary error is descriptive' );
}

done_testing();
