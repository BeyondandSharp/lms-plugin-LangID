package Plugins::LangID::API;

# LangID - offline language identification for Lyrion Music Server.
#
# This module is the run-time half of the plugin. It locates the `langid`
# helper binary shipped in bin/<platform>/, executes it asynchronously with
# IPC::Open3 and returns the parsed result to the caller.
#
# Public API:
#   Plugins::LangID::API->available            -> true if the helper is usable
#   Plugins::LangID::API->detect($text, $cb)   -> asynchronous; $cb->(\%result)
#   Plugins::LangID::API->languages            -> arrayref of ISO 639-1 codes
#   Plugins::LangID::API->binary_path          -> absolute path of the helper
#   Plugins::LangID::API->version              -> plugin version string
#
# The module deliberately has no compile-time LMS dependencies so that the
# unit tests can exercise it on a plain Perl installation (see t/api.t).

use strict;
use warnings;

use AnyEvent ();
use AnyEvent::Util qw(fh_nonblocking);
use Config ();
use Encode ();
use File::Basename ();
use File::Spec::Functions qw(catfile rel2abs);
use IPC::Open3 ();
use JSON::PP ();
use Symbol qw(gensym);
use Time::HiRes ();

our $VERSION = '0.1.0';

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
# The helper is executed directly (no shell). Its stdin is closed after the
# normalised text has been written. Stdout is parsed as JSON. If the helper
# does not finish within TIMEOUT seconds it receives SIGTERM and, after
# KILL_GRACE more seconds, SIGKILL; the callback then receives a timeout error.
sub detect {
	my ( $class, $text, $callback ) = @_;

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
		IPC::Open3::open3( $stdin_handle, $stdout_handle, $stderr_handle, $path );
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

		my $name = ( defined $decoded->{language} && !ref $decoded->{language} && length $decoded->{language} )
			? "$decoded->{language}"
			: undef;

		# The helper reports null for empty/blank input: no language, no scores.
		unless ( defined $name ) {
			$finish->( {
				language   => undef,
				name       => undef,
				iso        => undef,
				confidence => 0,
				scores     => [],
			} );

			return;
		}

		my $iso = ( defined $decoded->{iso} && !ref $decoded->{iso} && length $decoded->{iso} )
			? lc $decoded->{iso}
			: _iso_from_name($name);

		my $raw_scores = ref $decoded->{scores} eq 'ARRAY' ? $decoded->{scores} : [];
		my @scores     = grep { defined } map { _normalize_score($_) } @$raw_scores;

		$finish->( {
			language   => $iso,
			name       => $name,
			iso        => $iso,
			confidence => ( defined $decoded->{confidence} && !ref $decoded->{confidence} ) ? 0 + $decoded->{confidence} : 0,
			scores     => \@scores,
		} );
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

					$finish->( { error => "failed to write to langid: $!" } );

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

1;
