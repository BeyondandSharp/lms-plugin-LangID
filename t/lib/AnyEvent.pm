package AnyEvent;

# Minimal AnyEvent shim used by the LangID unit tests only.
#
# Plugins::LangID::API uses AnyEvent->io and AnyEvent->timer for the
# asynchronous execution of the helper binary. AnyEvent is a run-time
# dependency of Lyrion Music Server and is therefore always available inside
# LMS, but it is not necessarily installed on a plain Perl build host. This
# shim implements exactly the subset the API needs plus a test-only pump()
# that drives the watchers to completion.
#
# It is intentionally not a general AnyEvent replacement: there are no
# condvars, no AE::* helper functions and no signal watchers.

use strict;
use warnings;

use IO::Select;
use Time::HiRes ();

my @io_watchers;
my @timers;
my $next_id = 0;

sub io {
	my ( $class, %args ) = @_;

	my $watcher = {
		id   => ++$next_id,
		fh   => $args{fh},
		poll => $args{poll} || 'r',
		cb   => $args{cb},
	};

	push @io_watchers, $watcher;

	return bless { id => $watcher->{id} }, 'AnyEvent::Guard';
}

sub timer {
	my ( $class, %args ) = @_;

	my $watcher = {
		id  => ++$next_id,
		due => Time::HiRes::time() + ( $args{after} // 0 ),
		cb  => $args{cb},
	};

	push @timers, $watcher;

	return bless { id => $watcher->{id} }, 'AnyEvent::Guard';
}

sub _remove {
	my ($id) = @_;

	@io_watchers = grep { $_->{id} != $id } @io_watchers;
	@timers      = grep { $_->{id} != $id } @timers;

	return;
}

sub _io_watcher {
	my ($id) = @_;

	foreach my $watcher (@io_watchers) {
		return $watcher if $watcher->{id} == $id;
	}

	return undef;
}

sub pending {
	return scalar(@io_watchers) + scalar(@timers);
}

# Test-only event loop driver. Runs callbacks until no watchers remain or
# max_seconds elapsed. The API removes every watcher once its callback has
# fired, so an empty watcher list means "detect() is done".
sub pump {
	my (%args) = @_;

	my $deadline = Time::HiRes::time() + ( $args{max_seconds} // 30 );

	while ( @io_watchers || @timers ) {
		last if Time::HiRes::time() >= $deadline;

		my @readable = grep { $_->{poll} eq 'r' } @io_watchers;
		my @writable = grep { $_->{poll} eq 'w' } @io_watchers;

		my $read_set  = IO::Select->new( map { $_->{fh} } @readable );
		my $write_set = IO::Select->new( map { $_->{fh} } @writable );

		my $wait = 0.02;

		if (@timers) {
			my ($next_due) = sort { $a <=> $b } map { $_->{due} } @timers;
			my $delta = $next_due - Time::HiRes::time();
			$wait = $delta if $delta < $wait;
		}

		$wait = 0 if $wait < 0;

		my ( $ready_read, $ready_write ) = IO::Select->select( $read_set, $write_set, undef, $wait );

		$ready_read  ||= [];
		$ready_write ||= [];

		my %ready;

		foreach my $watcher (@readable) {
			foreach my $handle (@$ready_read) {
				next unless defined $handle;

				if ( fileno($handle) == fileno( $watcher->{fh} ) ) {
					$ready{ $watcher->{id} } = 1;
				}
			}
		}

		foreach my $watcher (@writable) {
			foreach my $handle (@$ready_write) {
				next unless defined $handle;

				if ( fileno($handle) == fileno( $watcher->{fh} ) ) {
					$ready{ $watcher->{id} } = 1;
				}
			}
		}

		foreach my $id ( sort { $a <=> $b } keys %ready ) {
			my $watcher = _io_watcher($id);

			next unless $watcher;

			$watcher->{cb}->();
		}

		my $now = Time::HiRes::time();

		foreach my $timer ( grep { $_->{due} <= $now } @timers ) {
			@timers = grep { $_->{id} != $timer->{id} } @timers;

			$timer->{cb}->();
		}
	}

	return;
}

package AnyEvent::Guard;

sub DESTROY {
	my ($self) = @_;

	AnyEvent::_remove( $self->{id} );

	return;
}

package AnyEvent;

1;
