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
use File::Path ();
use File::Spec::Functions qw(catfile);
use File::Temp ();
use Test::More;
use Time::HiRes ();

# Load the plugin module directly; it is not installed as a Perl distribution,
# so the package name cannot be resolved through @INC in the source tree.
require "$Bin/../API.pm";

my $API  = 'Plugins::LangID::API';
my $FAKE = "$Bin/fixtures/fake-langid";
my $FAKE_SUITE = "$Bin/fixtures/fake-langid-suite";

chmod 0755, $FAKE unless -x $FAKE;

ok( -x $FAKE, 'fake langid helper is executable' );

chmod 0755, $FAKE_SUITE unless -x $FAKE_SUITE;

ok( -x $FAKE_SUITE, 'fake suite helper is executable' );

# ---------------------------------------------------------------------------
# Model-download test setup (fully offline)
# ---------------------------------------------------------------------------

my $MODEL_DIR = File::Temp::tempdir( CLEANUP => 1 );

$ENV{LANGID_MODEL_DIR} = $MODEL_DIR;
delete $ENV{LANGID_MODEL_PATH};
delete $ENV{LANGID_MODEL_URL};

# Accept any non-empty file as a model in the wrapper tests. The real
# size/SHA-256 verification is covered by the dedicated test block below and
# end-to-end by scripts/smoke.sh against the actual download.
$API->set_model_verifier( sub { my ($path) = @_; return ( -f $path && ( -s $path ) > 0 ) ? 1 : 0; } );

sub model_cache_file { return catfile( $MODEL_DIR, 'lid.176.ftz' ); }

sub reset_model_cache {
	my $file = model_cache_file();
	unlink $file if -e $file;
	return;
}

sub write_fake_model {
	my ($path) = @_;

	open my $handle, '>:raw', $path or die "cannot write $path: $!";
	print {$handle} 'fake lid.176.ftz for unit tests';
	close $handle;
	chmod 0644, $path;

	return $path;
}

sub read_args_file {
	my ($path) = @_;

	open my $handle, '<', $path or return '';

	local $/;
	my $content = <$handle> // '';

	close $handle;

	return $content;
}

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

# ---------------------------------------------------------------------------
# detect_suite(): model handling and detector results
# ---------------------------------------------------------------------------

# A model file that already exists is passed to the helper as --model.
{
	my $model = write_fake_model( catfile( $MODEL_DIR, 'explicit-model.ftz' ) );

	local $ENV{LANGID_BIN}            = $FAKE_SUITE;
	local $ENV{LANGID_MODEL_PATH}     = $model;
	local $ENV{FAKE_SUITE_MODE}       = 'normal';
	local $ENV{FAKE_SUITE_ARGS_FILE}  = catfile( $MODEL_DIR, 'args-present.txt' );

	unlink $ENV{FAKE_SUITE_ARGS_FILE};

	ok( $API->model_available, 'model_available() accepts the test model' );

	my $called = 0;
	my $result;

	$API->detect_suite( '这是一个测试。', 'zh-Hans', sub { $called++; $result = shift } );

	AnyEvent::pump( max_seconds => 10 );

	is( $called, 1, 'detect_suite() invokes the callback exactly once' );
	is( ref $result, 'HASH', 'detect_suite() passes a hash reference' );
	is( $result->{target}, 'zh-Hans', 'detect_suite() echoes the target' );
	is( ref $result->{lingua}, 'HASH', 'detect_suite() returns the lingua block' );
	is( ref $result->{fastlang}, 'HASH', 'detect_suite() returns the fastlang block' );
	is( $result->{lingua}{language}, 'zh', 'lingua language is the ISO code' );
	is( $result->{lingua}{name}, 'Chinese', 'lingua name is the display name' );
	cmp_ok( $result->{lingua}{confidence}, '==', 0.99, 'lingua confidence is passed through' );
	is( $result->{fastlang}{language}, 'zh', 'fastlang language is the ISO code' );
	is( $result->{fastlang}{name}, 'Chinese', 'fastlang name is the display name' );
	cmp_ok( $result->{fastlang}{confidence}, '==', 0.97, 'fastlang confidence is passed through' );

	like(
		read_args_file( $ENV{FAKE_SUITE_ARGS_FILE} ),
		qr/suite --target zh-Hans --model \Q$model\E/,
		'helper is called with --target and --model',
	);
}

# The target is forwarded; the model is reused.
{
	my $model = write_fake_model( catfile( $MODEL_DIR, 'explicit-model.ftz' ) );
	local $ENV{LANGID_BIN}        = $FAKE_SUITE;
	local $ENV{LANGID_MODEL_PATH} = $model;
	local $ENV{FAKE_SUITE_MODE}   = 'normal';

	my $result;

	$API->detect_suite( 'This is a test.', 'en', sub { $result = shift } );

	AnyEvent::pump( max_seconds => 10 );

	is( $result->{target}, 'en', 'detect_suite() forwards the English target' );
	is( $result->{lingua}{language}, 'en', 'detect_suite() returns English for the en target' );
	is( $result->{fastlang}{language}, 'en', 'detect_suite() returns English fastlang for en' );
}

# Empty input: confidence 0 in both detectors when the model is available.
{
	my $model = write_fake_model( catfile( $MODEL_DIR, 'explicit-model.ftz' ) );
	local $ENV{LANGID_BIN}        = $FAKE_SUITE;
	local $ENV{LANGID_MODEL_PATH} = $model;
	local $ENV{FAKE_SUITE_MODE}   = 'empty';

	my $result;

	$API->detect_suite( '   ', 'ja', sub { $result = shift } );

	AnyEvent::pump( max_seconds => 10 );

	is( $result->{target}, 'ja', 'detect_suite() keeps the target for empty input' );
	is( $result->{lingua}{confidence}, 0, 'empty input yields lingua confidence 0' );
	is( $result->{fastlang}{confidence}, 0, 'empty input yields fastlang confidence 0' );
}

# Missing model -> downloaded once -> verified -> passed to the helper.
{
	reset_model_cache();

	my $cache       = model_cache_file();
	my $fetch_count = 0;
	my $url_seen;

	local $ENV{LANGID_BIN}           = $FAKE_SUITE;
	local $ENV{FAKE_SUITE_MODE}      = 'normal';
	local $ENV{FAKE_SUITE_ARGS_FILE} = catfile( $MODEL_DIR, 'args-download.txt' );

	unlink $ENV{FAKE_SUITE_ARGS_FILE};

	$API->set_model_fetcher(
		sub {
			my ( $url, $temp, $done ) = @_;

			$fetch_count++;
			$url_seen = $url;

			open my $handle, '>:raw', $temp or die "cannot write $temp: $!";
			print {$handle} 'downloaded fake lid.176.ftz';
			close $handle;

			$done->( 1, undef );

			return;
		}
	);

	my $result;

	$API->detect_suite( '这是一个测试。', 'zh', sub { $result = shift } );

	AnyEvent::pump( max_seconds => 20 );

	$API->set_model_fetcher(undef);

	is( $fetch_count, 1, 'missing model is downloaded exactly once' );
	is( $url_seen, $API->model_url, 'downloader receives the configured model URL' );
	ok( -f $cache, 'downloaded model is stored in the cache' );
	is( ( stat $cache )[2] & 07777, 0644, 'cached model has mode 0644' );
	is( ref $result, 'HASH', 'suite result is a hash reference' );
	is( $result->{lingua}{language}, 'zh', 'lingua result is present after download' );
	ok( defined $result->{fastlang}, 'fastlang result is present after download' );
	like(
		read_args_file( $ENV{FAKE_SUITE_ARGS_FILE} ),
		qr/--model \Q$cache\E/,
		'helper is called with the downloaded model path',
	);
}

# Download failure -> suite still runs, without --model and with fastlang null.
{
	reset_model_cache();

	my $cache = model_cache_file();

	local $ENV{LANGID_BIN}           = $FAKE_SUITE;
	local $ENV{FAKE_SUITE_MODE}      = 'normal';
	local $ENV{FAKE_SUITE_ARGS_FILE} = catfile( $MODEL_DIR, 'args-failure.txt' );

	unlink $ENV{FAKE_SUITE_ARGS_FILE};

	$API->set_model_fetcher(
		sub {
			my ( $url, $temp, $done ) = @_;

			$done->( 0, 'simulated network failure' );

			return;
		}
	);

	my $result;
	my @warnings;

	local $SIG{__WARN__} = sub { push @warnings, @_ };

	$API->detect_suite( '这是一个测试。', 'zh', sub { $result = shift } );

	AnyEvent::pump( max_seconds => 20 );

	$API->set_model_fetcher(undef);

	ok(
		( grep { m{download failed}i } @warnings ),
		'failed download is logged as a warning',
	);
	is( ref $result, 'HASH', 'failed download still yields a suite result' );
	is( $result->{lingua}{language}, 'zh', 'lingua result survives a failed download' );
	ok( !defined $result->{fastlang}, 'fastlang is null after a failed download' );
	ok( !-e $cache, 'no model file is left behind after a failed download' );

	my $args = read_args_file( $ENV{FAKE_SUITE_ARGS_FILE} );
	like( $args, qr/suite --target zh/, 'suite is called without a model after a failed download', );
	unlike( $args, qr/--model/, 'no --model flag is passed after a failed download' );
}

# Concurrent requests share a single download.
{
	reset_model_cache();

	my $fetch_count = 0;
	my $pending;
	my $timer_guard;

	local $ENV{LANGID_BIN}           = $FAKE_SUITE;
	local $ENV{FAKE_SUITE_MODE}      = 'normal';
	local $ENV{FAKE_SUITE_ARGS_FILE} = catfile( $MODEL_DIR, 'args-concurrent.txt' );

	unlink $ENV{FAKE_SUITE_ARGS_FILE};

	$API->set_model_fetcher(
		sub {
			my ( $url, $temp, $done ) = @_;

			$fetch_count++;

			$pending = sub {
				open my $handle, '>:raw', $temp or die "cannot write $temp: $!";
				print {$handle} 'concurrent fake model';
				close $handle;
				$done->( 1, undef );
				return;
			};

			# The guard must stay referenced, otherwise the timer is canceled
			# before it can fire.
			$timer_guard = AnyEvent->timer(
				after => 0.05,
				cb    => sub {
					$timer_guard = undef;
					my $finish = $pending;
					$pending = undef;
					$finish->() if $finish;
					return;
				},
			);

			return;
		}
	);

	my @results;
	my $calls = 0;

	$API->detect_suite( 'first', 'zh', sub { $calls++; push @results, shift } );
	$API->detect_suite( 'second', 'zh', sub { $calls++; push @results, shift } );

	AnyEvent::pump( max_seconds => 20 );

	$API->set_model_fetcher(undef);

	is( $fetch_count, 1, 'concurrent detect_suite() calls coalesce into one download' );
	is( $calls, 2, 'both concurrent callbacks are invoked' );
	is( scalar @results, 2, 'both concurrent results are returned' );
	ok( defined $results[0]{fastlang}, 'first concurrent result has fastlang' );
	ok( defined $results[1]{fastlang}, 'second concurrent result has fastlang' );
}

# Missing fastlang field is tolerated (model unavailable) instead of an error.
{
	my $model = write_fake_model( catfile( $MODEL_DIR, 'explicit-model.ftz' ) );

	local $ENV{LANGID_BIN}        = $FAKE_SUITE;
	local $ENV{LANGID_MODEL_PATH} = $model;
	local $ENV{FAKE_SUITE_MODE}   = 'nofastlang';

	my $result;

	$API->detect_suite( '这是一个测试。', 'zh', sub { $result = shift } );

	AnyEvent::pump( max_seconds => 10 );

	is( ref $result, 'HASH', 'missing fastlang field yields a result hash' );
	ok( !defined $result->{fastlang}, 'missing fastlang field becomes undef' );
	is( $result->{lingua}{language}, 'zh', 'lingua result is still present' );
}

# Default (real) verifier rejects a wrong-size file; the test hook restores it.
{
	$API->set_model_verifier(undef);

	my $bad = catfile( $MODEL_DIR, 'bad-model.ftz' );

	open my $handle, '>:raw', $bad or die "cannot write $bad: $!";
	print {$handle} 'not the real model';
	close $handle;

	local $ENV{LANGID_MODEL_PATH} = $bad;

	ok( !$API->model_available, 'default verifier rejects a wrong-size model file' );

	$API->set_model_verifier( sub { my ($path) = @_; return ( -f $path && ( -s $path ) > 0 ) ? 1 : 0; } );
}

# Binary errors are still surfaced when a usable model is present.
{
	my $model = write_fake_model( catfile( $MODEL_DIR, 'explicit-model.ftz' ) );

	local $ENV{LANGID_BIN}        = $FAKE_SUITE;
	local $ENV{LANGID_MODEL_PATH} = $model;
	local $ENV{FAKE_SUITE_MODE}   = 'error';

	my $result;

	$API->detect_suite( 'texte', 'fr', sub { $result = shift } );

	AnyEvent::pump( max_seconds => 10 );

	ok( ref $result eq 'HASH' && defined $result->{error}, 'detect_suite() reports a binary error' );
	like( $result->{error} // '', qr/unsupported target: fr/, 'binary JSON error is surfaced to the caller' );
}

{
	my $model = write_fake_model( catfile( $MODEL_DIR, 'explicit-model.ftz' ) );

	local $ENV{LANGID_BIN}        = $FAKE_SUITE;
	local $ENV{LANGID_MODEL_PATH} = $model;
	local $ENV{FAKE_SUITE_MODE}   = 'crash';

	my $result;

	$API->detect_suite( 'crash', 'zh', sub { $result = shift } );

	AnyEvent::pump( max_seconds => 10 );

	ok( ref $result eq 'HASH' && defined $result->{error}, 'detect_suite() reports a crashing helper' );
	like( $result->{error} // '', qr/status 3/, 'suite crash error contains the exit status' );
}

{
	my $result;

	# Missing target fails synchronously, before spawning a process.
	$API->detect_suite( 'text', undef, sub { $result = shift } );

	ok( ref $result eq 'HASH' && defined $result->{error}, 'detect_suite() requires a target' );
	like( $result->{error} // '', qr/target/i, 'missing target error is descriptive' );
}

{
	local $ENV{LANGID_BIN} = '/nonexistent/langid';

	my $result;

	$API->detect_suite( 'text', 'zh', sub { $result = shift } );

	ok( ref $result eq 'HASH' && defined $result->{error}, 'detect_suite() reports a missing binary' );
	like( $result->{error} // '', qr/not available/i, 'suite missing binary error is descriptive' );
}

done_testing();
