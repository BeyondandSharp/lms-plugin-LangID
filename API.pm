package Plugins::LangID::API;

# LangID - offline language identification for Lyrion Music Server.
#
# This module is the run-time half of the plugin. It locates the `langid`
# helper binary shipped in bin/<platform>/, executes it asynchronously with
# IPC::Open3 and returns the parsed result to the caller.
#
# Public API:
#   Plugins::LangID::API->available                       -> true if the helper is usable
#   Plugins::LangID::API->detect($text, $cb)              -> asynchronous; $cb->(\%result)
#   Plugins::LangID::API->detect_suite($text, $target, $cb) -> lingua + fastText result
#   Plugins::LangID::API->languages                       -> arrayref of ISO 639-1 codes
#   Plugins::LangID::API->binary_path                     -> absolute path of the helper
#   Plugins::LangID::API->version                         -> plugin version string
#
# The fastText model (lid.176.ftz) is not shipped with the plugin. The first
# detect_suite() call downloads it to a persistent cache, verifies size and
# SHA-256, and then passes it to the helper with --model. If the download
# fails, the suite still returns the lingua result and fastlang => undef.
#
# Model configuration (environment):
#   LANGID_MODEL_PATH  exact model file to use (as-is)
#   LANGID_MODEL_DIR   cache directory (default: <LMS prefs>/langid)
#   LANGID_MODEL_URL   download URL (default: official fastText lid.176.ftz)
#
# Test hooks (t/api.t, never needed in production):
#   set_model_fetcher($coderef)   sub ($url, $temp_path, $done) - replaces the
#                                 SimpleAsyncHTTP download; $done->($ok, $err)
#   set_model_verifier($coderef)  sub ($path) -> bool - replaces size/SHA checks
#   model_path_override($path)    use exactly $path, bypassing cache dir logic
#
# The module deliberately has no compile-time LMS dependencies so that the
# unit tests can exercise it on a plain Perl installation (see t/api.t).

use strict;
use warnings;

use AnyEvent ();
use AnyEvent::Util qw(fh_nonblocking);
use Config ();
use Digest::SHA ();
use Encode ();
use File::Basename ();
use File::Path ();
use File::Spec::Functions qw(catfile rel2abs tmpdir);
use IPC::Open3 ();
use JSON::PP ();
use Symbol qw(gensym);
use Time::HiRes ();

our $VERSION = '0.1.1';

use constant {
	MAX_CHARS      => 16_000,
	TIMEOUT        => 2,
	KILL_GRACE     => 0.5,
	MAX_OUTPUT     => 1_048_576,
	MAX_STDERR     => 8_192,
	LANGUAGES_TIME => 5,
};

my $JSON = JSON::PP->new->utf8;

# lingua-rs reports language *display names* in the scores array. API
# consumers (for example MusicArtistInfo's lyrics translation) need the
# ISO 639-1 code, so the wrapper maps the display names of every language that
# this project can compile into the helper back to their codes.
my %ISO_BY_NAME = (
	'Chinese'    => 'zh',
	'English'    => 'en',
	'Japanese'   => 'ja',
	'Korean'     => 'ko',
	'French'     => 'fr',
	'German'     => 'de',
	'Spanish'    => 'es',
	'Italian'    => 'it',
	'Portuguese' => 'pt',
	'Dutch'      => 'nl',
	'Russian'    => 'ru',
	'Polish'     => 'pl',
	'Swedish'    => 'sv',
	'Turkish'    => 'tr',
	'Indonesian' => 'id',
	'Vietnamese' => 'vi',
);

# languages() is a cheap query, but it still spawns a process. Cache the answer
# per binary path so repeated calls (UI, CLI, other plugins) do not respawn it.
my %LANGUAGES_CACHE;

# ---------------------------------------------------------------------------
# fastText model download and cache
# ---------------------------------------------------------------------------

our $MODEL_URL_DEFAULT = 'https://dl.fbaipublicfiles.com/fasttext/supervised-models/lid.176.ftz';
our $MODEL_SIZE        = 938_013;
our $MODEL_SHA256      = '8f3472cfe8738a7b6099e8e999c3cbfae0dcd15696aac7d7738a8039db603e83';
our $MODEL_FILENAME    = 'lid.176.ftz';
our $MODEL_FETCH_TIMEOUT = 30;

my $MODEL_PATH_OVERRIDE;
my $MODEL_FETCHER;
my $MODEL_VERIFIER;
my $MODEL_LOG;
my %MODEL_DOWNLOADS;

# Directory this module was loaded from. The plugin layout keeps API.pm,
# Plugin.pm and the bin/ directory side by side.
sub plugin_dir {
	my ($class) = @_;

	return rel2abs( File::Basename::dirname(__FILE__) );
}

# Map the Perl platform to the directory naming convention used in bin/.
# Returns undef for platforms without a bundle; binary_path() then falls back
# to bin/langid.
sub platform {
	my ($class) = @_;

	my $os   = $^O;
	my $arch = $Config::Config{archname} || '';

	if ( $os eq 'linux' ) {
		# Perl's archname often carries a libc/thread suffix
		# (e.g. x86_64-linux-gnu-thread-multi), so match the prefix.
		return 'linux-x86_64'  if $arch =~ m{\A(?:x86_64|amd64|x64)}i;
		return 'linux-aarch64' if $arch =~ m{\A(?:aarch64|arm64)}i;
		return undef;
	}

	if ( $os eq 'darwin' ) {
		return 'darwin-aarch64' if $arch =~ m{\A(?:arm64|aarch64)}i;
		return 'darwin-x86_64';
	}

	if ( $os eq 'MSWin32' ) {
		return 'windows-aarch64' if $arch =~ m{\A(?:arm64|aarch64)}i;
		return 'windows-x86_64';
	}

	return undef;
}

sub binary_name {
	my ($class) = @_;

	return $^O eq 'MSWin32' ? 'langid.exe' : 'langid';
}

sub binary_path {
	my ($class) = @_;

	# Explicit override, mainly for tests and for installations that ship the
	# binary somewhere else (LANGID_BIN=/usr/local/bin/langid).
	if ( defined $ENV{LANGID_BIN} && length $ENV{LANGID_BIN} ) {
		return $ENV{LANGID_BIN};
	}

	my $name = $class->binary_name;

	if ( my $platform = $class->platform ) {
		my $candidate = catfile( $class->plugin_dir, 'bin', $platform, $name );

		return $candidate if -f $candidate;
	}

	return catfile( $class->plugin_dir, 'bin', $name );
}

sub available {
	my ($class) = @_;

	my $path = $class->binary_path;

	return 0 unless defined $path && length $path;

	return ( -f $path && -x $path ) ? 1 : 0;
}

sub version {
	my ($class) = @_;

	my $version_file = catfile( $class->plugin_dir, 'VERSION' );

	if ( open my $handle, '<', $version_file ) {
		my $version = do { local $/; <$handle> };

		close $handle;

		if ( defined $version ) {
			$version =~ s{\A\s+}{}xms;
			$version =~ s{\s+\z}{}xms;

			return $version if length $version;
		}
	}

	return $VERSION;
}

# Normalise UTF-8 text before it is handed to the helper: strip control
# characters, collapse whitespace runs, trim and cap the length. The binary
# repeats the same normalisation, but doing it here keeps the process input
# small and the wrapper behaviour independent of the binary version.
sub sanitize_text {
	my ( $class, $text ) = @_;

	return '' unless defined $text;

	my $chars = $text;

	unless ( utf8::is_utf8($chars) ) {
		my $decoded = eval { Encode::decode( 'UTF-8', $chars, Encode::FB_DEFAULT ) };

		$chars = $decoded if defined $decoded;
	}

	$chars =~ s{\A\x{FEFF}}{}xms;
	$chars =~ s{[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]}{}gxms;
	$chars =~ s{\s+}{ }gxms;
	$chars =~ s{\A\x20}{}xms;
	$chars =~ s{\x20\z}{}xms;

	if ( length($chars) > MAX_CHARS ) {
		$chars = substr( $chars, 0, MAX_CHARS );
		$chars =~ s{\x20\z}{}xms;
	}

	return Encode::encode( 'UTF-8', $chars );
}

# Collapse a possibly undefined, multi-line message to one short line.
sub _trim {
	my ( $value, $limit ) = @_;

	return '' unless defined $value;

	$value =~ s{\s+}{ }gxms;
	$value =~ s{\A\x20}{}xms;
	$value =~ s{\x20\z}{}xms;

	if ( defined $limit && length($value) > $limit ) {
		$value = substr( $value, 0, $limit ) . '...';
	}

	return $value;
}

# Map a lingua display name ("Chinese") to its ISO 639-1 code ("zh").
# Unknown names fall back to the lowercased name, matching the wrapper's
# documented behaviour.
sub _iso_from_name {
	my ($name) = @_;

	return '' unless defined $name && !ref $name && length $name;

	return $ISO_BY_NAME{$name} if defined $ISO_BY_NAME{$name};

	return lc $name;
}

# Normalise one entry of the helper's scores array to the wrapper's public
# shape: { language = ISO 639-1 code, name = display name, confidence = float }.
sub _normalize_score {
	my ($score) = @_;

	return undef unless ref $score eq 'HASH';

	my $name       = ( defined $score->{language} && !ref $score->{language} ) ? "$score->{language}" : '';
	my $confidence = ( defined $score->{confidence} && !ref $score->{confidence} ) ? 0 + $score->{confidence} : 0;

	return {
		language   => _iso_from_name($name),
		name       => $name,
		confidence => $confidence,
	};
}

# Run the helper synchronously (only used for --languages, which is a fast
# query) and capture stdout, stderr and the wait status.
sub _run_sync {
	my ( $class, $timeout, @arguments ) = @_;

	my $path = $class->binary_path;

	my ( $stdin_handle, $stdout_handle );
	my $stderr_handle = gensym();

	my $pid = eval {
		IPC::Open3::open3( $stdin_handle, $stdout_handle, $stderr_handle, $path, @arguments );
	};

	unless ($pid) {
		return ( undef, undef, undef, "cannot execute $path: $@" );
	}

	close $stdin_handle;

	my ( $output, $errors ) = ( '', '' );

	my $completed = eval {
		local $SIG{ALRM} = sub { die "language helper timed out\n" };

		alarm $timeout;
		local $/;
		$output = <$stdout_handle> // '';
		$errors = <$stderr_handle> // '';
		alarm 0;

		1;
	};

	my $failure = $@;

	alarm 0;
	close $stdout_handle;
	close $stderr_handle;

	if ( !$completed ) {
		kill 'KILL', $pid;
		waitpid $pid, 0;

		return ( undef, undef, undef, "language helper failed: $failure" );
	}

	waitpid $pid, 0;

	return ( $output, $errors, $? , undef );
}

# ISO 639-1 codes of the language models compiled into the helper binary.
sub languages {
	my ($class) = @_;

	my $path = $class->binary_path;

	return [] unless defined $path && length $path && -f $path && -x $path;

	return $LANGUAGES_CACHE{$path} if $LANGUAGES_CACHE{$path};

	my ( $output, $errors, $status, $failure ) = $class->_run_sync( LANGUAGES_TIME, '--languages' );

	return [] if $failure;
	return [] unless defined $status && $status == 0;

	my $decoded = eval { $JSON->decode( $output // '' ) };

	return [] unless ref $decoded eq 'ARRAY';

	my @codes = grep { defined && !ref && length } @$decoded;

	$LANGUAGES_CACHE{$path} = \@codes;

	return $LANGUAGES_CACHE{$path};
}

# Asynchronously detect the language of $text and invoke $callback with
#   { language => <ISO 639-1>, name => <display name>, iso => <ISO 639-1>,
#     confidence => <float>, scores => [ { language, name, confidence }, ... ] }
# on success, or { error => <message> } on failure.
#
# This method is unchanged from the first version of the plugin; it runs the
# helper binary in its default stdin -> JSON mode.
sub detect {
	my ( $class, $text, $callback ) = @_;

	return $class->_detect_with_arguments( $text, [], \&_parse_detect, $callback );
}

# ---------------------------------------------------------------------------
# fastText model access
# ---------------------------------------------------------------------------

# Download URL, overridable for mirrors or tests.
sub model_url {
	my ($class) = @_;

	return $ENV{LANGID_MODEL_URL}
		if defined $ENV{LANGID_MODEL_URL} && length $ENV{LANGID_MODEL_URL};

	return $MODEL_URL_DEFAULT;
}

# Persistent cache directory for the downloaded model.
sub model_cache_dir {
	my ($class) = @_;

	return $ENV{LANGID_MODEL_DIR}
		if defined $ENV{LANGID_MODEL_DIR} && length $ENV{LANGID_MODEL_DIR};

	my $base;
	if ( eval { require Slim::Utils::Prefs; 1 } ) {
		$base = eval { Slim::Utils::Prefs::dir() };
	}
	$base = tmpdir() unless defined $base && length $base;

	return catfile( $base, 'langid' );
}

# Location of the model file. LANGID_MODEL_PATH / model_path_override() take
# precedence; otherwise the file lives in the cache directory.
sub model_path {
	my ($class) = @_;

	return $MODEL_PATH_OVERRIDE
		if defined $MODEL_PATH_OVERRIDE && length $MODEL_PATH_OVERRIDE;

	return $ENV{LANGID_MODEL_PATH}
		if defined $ENV{LANGID_MODEL_PATH} && length $ENV{LANGID_MODEL_PATH};

	return catfile( $class->model_cache_dir(), $MODEL_FILENAME );
}

# --- test hooks -----------------------------------------------------------

sub model_path_override {
	my ( $class, $path ) = @_;

	$MODEL_PATH_OVERRIDE = $path;

	return;
}

sub set_model_fetcher {
	my ( $class, $fetcher ) = @_;

	$MODEL_FETCHER = $fetcher;

	return;
}

sub set_model_verifier {
	my ( $class, $verifier ) = @_;

	$MODEL_VERIFIER = $verifier;

	return;
}

# --- verification ---------------------------------------------------------

# True when $path is a complete, verified lid.176.ftz model.
sub _verify_model_file {
	my ( $class, $path ) = @_;

	return 0 unless defined $path && length $path && -f $path;

	if ($MODEL_VERIFIER) {
		my $accepted = eval { $MODEL_VERIFIER->($path) };

		return $accepted ? 1 : 0;
	}

	return 0 unless ( -s $path ) == $MODEL_SIZE;

	my $digest = eval {
		open my $handle, '<:raw', $path or die "cannot open $path: $!";
		my $sha = Digest::SHA->new(256);
		$sha->addfile($handle);
		close $handle;
		$sha->hexdigest;
	};

	return 0 unless defined $digest;

	return $digest eq $MODEL_SHA256 ? 1 : 0;
}

# Public helper: is the model currently available?
sub model_available {
	my ($class) = @_;

	return $class->_verify_model_file( $class->model_path ) ? 1 : 0;
}

# --- download orchestration ----------------------------------------------

# Ensure the model exists and is verified, downloading it once if needed.
# $callback->($model_path_or_undef) is invoked exactly once. Concurrent calls
# for the same path share one download.
sub ensure_model {
	my ( $class, $callback ) = @_;

	$callback = sub { } unless ref $callback eq 'CODE';

	my $path = $class->model_path;

	if ( $class->_verify_model_file($path) ) {
		$callback->($path);

		return;
	}

	if ( $MODEL_DOWNLOADS{$path} ) {
		push @{ $MODEL_DOWNLOADS{$path}{waiters} }, $callback;

		return;
	}

	my $job = {
		waiters => [$callback],
		temp    => undef,
		timer   => undef,
	};

	$MODEL_DOWNLOADS{$path} = $job;

	$class->_start_model_download( $path, $job );

	return;
}

sub _start_model_download {
	my ( $class, $path, $job ) = @_;

	my $directory = File::Basename::dirname($path);

	my $directory_ok = eval {
		File::Path::make_path($directory) unless -d $directory;
		1;
	};

	unless ( $directory_ok && -d $directory ) {
		_warn_model("cannot create fastText model directory $directory: $@");
		$class->_finish_model_download( $path, undef );

		return;
	}

	my $temp = sprintf( '%s.part-%d-%d', $path, $$, int( rand(1_000_000) ) );
	$job->{temp} = $temp;

	$job->{timer} = AnyEvent->timer(
		after => $MODEL_FETCH_TIMEOUT,
		cb    => sub {
			return unless $MODEL_DOWNLOADS{$path};

			_warn_model( 'fastText model download timed out after '
				. $MODEL_FETCH_TIMEOUT . 's' );
			$class->_finish_model_download( $path, undef );

			return;
		},
	);

	my $completed = 0;

	my $on_download = sub {
		my ( $ok, $error ) = @_;

		return if $completed;
		$completed = 1;

		return unless $MODEL_DOWNLOADS{$path};

		if ( !$ok ) {
			my $detail = _trim( $error || 'unknown error', 200 );
			_warn_model("fastText model download failed: $detail");
			$class->_finish_model_download( $path, undef );

			return;
		}

		unless ( $class->_verify_model_file($temp) ) {
			_warn_model('downloaded fastText model failed size/SHA-256 verification');
			$class->_finish_model_download( $path, undef );

			return;
		}

		chmod 0644, $temp;
		unless ( rename $temp, $path ) {
			_warn_model("cannot move downloaded fastText model to $path: $!");
			$class->_finish_model_download( $path, undef );

			return;
		}

		$job->{temp} = undef;
		$class->_finish_model_download( $path, $path );

		return;
	};

	my $fetcher = $MODEL_FETCHER || \&_default_model_fetcher;

	my $started = eval {
		$fetcher->( $class->model_url, $temp, $on_download );
		1;
	};

	unless ($started) {
		$on_download->( 0, "could not start the download: $@" );
	}

	return;
}

sub _finish_model_download {
	my ( $class, $path, $model_path ) = @_;

	my $job = delete $MODEL_DOWNLOADS{$path};
	return unless $job;

	undef $job->{timer} if $job->{timer};

	if ( defined $job->{temp} && -e $job->{temp} ) {
		unlink $job->{temp};
	}

	my @waiters = @{ $job->{waiters} || [] };
	@{ $job->{waiters} } = ();

	foreach my $callback (@waiters) {
		my $ok = eval { $callback->($model_path); 1 };
		_warn_model( 'model download callback failed: ' . _trim( $@, 200 ) ) unless $ok;
	}

	return;
}

# Default downloader: Slim::Networking::SimpleAsyncHTTP, 30 s timeout. It only
# writes the response to $temp; verification and the atomic rename happen in
# _start_model_download().
sub _default_model_fetcher {
	my ( $url, $temp, $done ) = @_;

	my $available = eval {
		require Slim::Networking::SimpleAsyncHTTP;
		1;
	};

	unless ($available) {
		$done->( 0, 'Slim::Networking::SimpleAsyncHTTP is not available' );

		return;
	}

	my $completed = 0;

	my $finish = sub {
		my ( $ok, $error ) = @_;

		return if $completed;
		$completed = 1;

		$done->( $ok, $error );

		return;
	};

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $content  = eval { $response->content };

			my $written = eval {
				open my $handle, '>:raw', $temp or die "cannot open $temp: $!";
				print {$handle} $content;
				close $handle;
				1;
			};

			if ( !$written ) {
				$finish->( 0, 'cannot write downloaded model: ' . _trim( $@, 200 ) );

				return;
			}

			$finish->( 1, undef );

			return;
		},
		sub {
			my ( $response, $error ) = @_;

			$finish->( 0, $error || 'network error' );

			return;
		},
		{ timeout => $MODEL_FETCH_TIMEOUT },
	);

	$http->get($url);

	return;
}

# --- logging --------------------------------------------------------------

sub _model_log {
	return $MODEL_LOG if $MODEL_LOG;

	my $log;
	if ( eval { require Slim::Utils::Log; 1 } ) {
		$log = eval {
			Slim::Utils::Log->addLogCategory( {
				category     => 'plugin.langid',
				defaultLevel => 'WARN',
				description  => 'PLUGIN_LANGID',
			} );
		};
	}

	$MODEL_LOG = $log || 0;

	return $MODEL_LOG || undef;
}

sub _warn_model {
	my ($message) = @_;

	$message = "LangID: $message";

	my $log = _model_log();

	if ( $log && $log->can('warn') ) {
		$log->warn($message);

		return;
	}

	warn "$message\n";

	return;
}

# Asynchronously run both detectors for $target and invoke $callback with
#   { target => <target>, lingua => { confidence, language, name },
#     fastlang => { confidence, language, name } | undef }
# on success, or { error => <message> } on failure.
#
# The helper binary is executed as
#   langid suite --target $target [--model $path]
# The fastText model is downloaded and verified on first use (see
# ensure_model()). If it is unavailable, fastlang is undef and the lingua
# result is still returned.
sub detect_suite {
	my ( $class, $text, $target, $callback ) = @_;

	$callback = sub { } unless ref $callback eq 'CODE';

	unless ( defined $target && !ref $target && length $target ) {
		$callback->( { error => 'detect_suite() requires a target language' } );

		return;
	}

	my $binary = $class->binary_path;

	unless ( $class->available ) {
		my $detail = defined $binary && length $binary ? " ($binary)" : '';
		$callback->( { error => "langid binary is not available$detail" } );

		return;
	}

	$class->ensure_model(
		sub {
			my ($model_path) = @_;

			my @arguments = ( 'suite', '--target', $target );
			push @arguments, '--model', $model_path
				if defined $model_path && length $model_path;

			$class->_detect_with_arguments( $text, \@arguments, \&_parse_suite, $callback );

			return;
		}
	);

	return;
}

# Shared asynchronous process plumbing for detect() and detect_suite().
# Runs $path with @$arguments, writes the normalised $text to stdin, closes it,
# collects stdout/stderr, enforces the timeout and finally calls
# $parse->($decoded_json) to produce the result hash passed to $callback.
sub _detect_with_arguments {
	my ( $class, $text, $arguments, $parse, $callback ) = @_;

	$callback = sub { } unless ref $callback eq 'CODE';

	my $path = $class->binary_path;

	unless ( $class->available ) {
		my $detail = defined $path && length $path ? " ($path)" : '';
		$callback->( { error => "langid binary is not available$detail" } );

		return;
	}

	my $input = $class->sanitize_text($text);

	my ( $stdin_handle, $stdout_handle );
	my $stderr_handle = gensym();

	my $pid = eval {
		IPC::Open3::open3( $stdin_handle, $stdout_handle, $stderr_handle, $path, @$arguments );
	};

	unless ($pid) {
		$callback->( { error => "cannot execute $path: $@" } );

		return;
	}

	fh_nonblocking( $stdin_handle, 1 );
	fh_nonblocking( $stdout_handle, 1 );
	fh_nonblocking( $stderr_handle, 1 );

	my $output = '';
	my $errors = '';
	my ( $stdin_closed, $stdout_closed, $stderr_closed ) = ( 0, 0, 0 );
	my $offset = 0;
	my $length = length $input;
	my ( $finished, $timed_out ) = ( 0, 0 );
	my $wait_status;
	my ( $stdin_watcher, $stdout_watcher, $stderr_watcher, $timeout_watcher, $kill_watcher );

	my $close_stdin = sub {
		return if $stdin_closed;

		$stdin_closed = 1;
		close $stdin_handle if defined $stdin_handle;
		$stdin_handle = undef;
		undef $stdin_watcher;

		return;
	};

	my $close_stdout = sub {
		return if $stdout_closed;

		$stdout_closed = 1;
		close $stdout_handle if defined $stdout_handle;
		$stdout_handle = undef;
		undef $stdout_watcher;

		return;
	};

	my $close_stderr = sub {
		return if $stderr_closed;

		$stderr_closed = 1;
		close $stderr_handle if defined $stderr_handle;
		$stderr_handle = undef;
		undef $stderr_watcher;

		return;
	};

	my $reap = sub {
		return $wait_status if defined $wait_status;

		waitpid $pid, 0;
		$wait_status = $?;

		return $wait_status;
	};

	my $finish = sub {
		my ($result) = @_;

		return if $finished;

		$finished = 1;

		undef $stdin_watcher;
		undef $stdout_watcher;
		undef $stderr_watcher;
		undef $timeout_watcher;
		undef $kill_watcher;

		$close_stdin->();
		$close_stdout->();
		$close_stderr->();

		$reap->();

		$callback->($result);

		return;
	};

	my $exit_error = sub {
		my ($status) = @_;

		return 'langid terminated unexpectedly' unless defined $status;

		if ( $status & 127 ) {
			return 'langid was killed by signal ' . ( $status & 127 );
		}

		my $message = 'langid exited with status ' . ( $status >> 8 );
		my $detail  = _trim( $errors, 200 );

		$message .= ": $detail" if length $detail;

		return $message;
	};

	my $maybe_finish = sub {
		return if $finished;
		return unless $stdout_closed && $stderr_closed;

		my $status = $reap->();

		if ($timed_out) {
			$finish->( { error => 'langid timeout: no response within ' . TIMEOUT . 's' } );

			return;
		}

		if ( !defined $status || $status != 0 ) {
			# The suite command reports unsupported targets as a JSON error
			# object with exit status 2; surface that message to the caller.
			my $decoded_error = eval { $JSON->decode($output) };
			my $decode_failed = $@;

			if ( !$decode_failed
				&& ref $decoded_error eq 'HASH'
				&& defined $decoded_error->{error}
				&& !ref $decoded_error->{error} )
			{
				$finish->( { error => "$decoded_error->{error}" } );

				return;
			}

			$finish->( { error => $exit_error->($status) } );

			return;
		}

		my $decoded = eval { $JSON->decode($output) };
		my $error   = $@;

		if ( $error || ref $decoded ne 'HASH' ) {
			my $detail = $error ? _trim( $error, 200 ) : _trim( $output, 120 );
			$finish->( { error => "invalid JSON from langid: $detail" } );

			return;
		}

		$finish->( $parse->($decoded) );

		return;
	};

	if ( $length == 0 ) {
		$close_stdin->();
	}
	else {
		$stdin_watcher = AnyEvent->io(
			fh   => $stdin_handle,
			poll => 'w',
			cb   => sub {
				return if $finished || $stdin_closed;

				my $written = syswrite( $stdin_handle, substr( $input, $offset ) );

				if ( !defined $written ) {
					return if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR};

					# The child may have exited before reading all of stdin
					# (for example `langid suite --target fr` reports an
					# unsupported target immediately). Stop writing, close the
					# pipe and let the stdout/stderr watchers collect the
					# child's JSON error or exit status.
					$close_stdin->();

					return;
				}

				$offset += $written;

				$close_stdin->() if $offset >= $length;

				return;
			},
		);
	}

	$stdout_watcher = AnyEvent->io(
		fh   => $stdout_handle,
		poll => 'r',
		cb   => sub {
			return if $finished || $stdout_closed;

			my $buffer = '';
			my $read   = sysread( $stdout_handle, $buffer, 8192 );

			if ( !defined $read ) {
				return if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR};

				$close_stdout->();
				$maybe_finish->();

				return;
			}

			if ( $read == 0 ) {
				$close_stdout->();
				$maybe_finish->();

				return;
			}

			if ( length($output) + length($buffer) > MAX_OUTPUT ) {
				$finish->( { error => 'langid produced too much output' } );

				return;
			}

			$output .= $buffer;

			return;
		},
	);

	$stderr_watcher = AnyEvent->io(
		fh   => $stderr_handle,
		poll => 'r',
		cb   => sub {
			return if $finished || $stderr_closed;

			my $buffer = '';
			my $read   = sysread( $stderr_handle, $buffer, 4096 );

			if ( !defined $read ) {
				return if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR};

				$close_stderr->();
				$maybe_finish->();

				return;
			}

			if ( $read == 0 ) {
				$close_stderr->();
				$maybe_finish->();

				return;
			}

			if ( length($errors) < MAX_STDERR ) {
				$errors .= $buffer;
			}

			return;
		},
	);

	$timeout_watcher = AnyEvent->timer(
		after => TIMEOUT,
		cb    => sub {
			return if $finished;

			undef $timeout_watcher;
			$timed_out = 1;

			kill 'TERM', $pid;

			$kill_watcher = AnyEvent->timer(
				after => KILL_GRACE,
				cb    => sub {
					return if $finished;

					undef $kill_watcher;

					kill 'KILL', $pid;

					$finish->( { error => 'langid timeout: no response within ' . TIMEOUT . 's' } );

					return;
				},
			);

			return;
		},
	);

	return;
}

# Turn the decoded output of the default helper mode into detect()'s public
# result shape (ISO codes, display names, normalised scores).
sub _parse_detect {
	my ($decoded) = @_;

	my $name = ( defined $decoded->{language} && !ref $decoded->{language} && length $decoded->{language} )
		? "$decoded->{language}"
		: undef;

	# The helper reports null for empty/blank input: no language, no scores.
	unless ( defined $name ) {
		return {
			language   => undef,
			name       => undef,
			iso        => undef,
			confidence => 0,
			scores     => [],
		};
	}

	my $iso = ( defined $decoded->{iso} && !ref $decoded->{iso} && length $decoded->{iso} )
		? lc $decoded->{iso}
		: _iso_from_name($name);

	my $raw_scores = ref $decoded->{scores} eq 'ARRAY' ? $decoded->{scores} : [];
	my @scores     = grep { defined } map { _normalize_score($_) } @$raw_scores;

	return {
		language   => $iso,
		name       => $name,
		iso        => $iso,
		confidence => ( defined $decoded->{confidence} && !ref $decoded->{confidence} ) ? 0 + $decoded->{confidence} : 0,
		scores     => \@scores,
	};
}

# Normalise one detector block of the `suite` output.
sub _normalize_suite_detector {
	my ($detector) = @_;

	return {
		confidence => ( defined $detector->{confidence} && !ref $detector->{confidence} ) ? 0 + $detector->{confidence} : 0,
		language   => ( defined $detector->{language} && !ref $detector->{language} ) ? "$detector->{language}" : undef,
		name       => ( defined $detector->{name} && !ref $detector->{name} ) ? "$detector->{name}" : undef,
	};
}

# Turn the decoded output of `langid suite` into detect_suite()'s result.
# `fastlang` is null when no fastText model was available, which is a valid
# result, not an error.
sub _parse_suite {
	my ($decoded) = @_;

	my $target = $decoded->{target};

	return { error => 'malformed suite JSON from langid: missing target' }
		unless defined $target && !ref $target && length $target;

	return { error => 'malformed suite JSON from langid: missing lingua result' }
		unless ref $decoded->{lingua} eq 'HASH';

	my $fastlang;

	if ( defined $decoded->{fastlang} ) {
		return { error => 'malformed suite JSON from langid: fastlang must be an object or null' }
			unless ref $decoded->{fastlang} eq 'HASH';

		$fastlang = _normalize_suite_detector( $decoded->{fastlang} );
	}

	return {
		target   => "$target",
		lingua   => _normalize_suite_detector( $decoded->{lingua} ),
		fastlang => $fastlang,
	};
}

1;
