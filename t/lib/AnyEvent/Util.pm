package AnyEvent::Util;

# Minimal AnyEvent::Util shim for the LangID unit tests. Only fh_nonblocking()
# is needed by Plugins::LangID::API.

use strict;
use warnings;

use Exporter 'import';
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);

our @EXPORT_OK = qw(fh_nonblocking);

sub fh_nonblocking {
	my ( $handle, $enable ) = @_;

	return unless defined $handle;

	my $flags = fcntl( $handle, F_GETFL, 0 );

	return unless defined $flags;

	$flags = $enable ? ( $flags | O_NONBLOCK ) : ( $flags & ~O_NONBLOCK );

	return fcntl( $handle, F_SETFL, $flags ) ? 1 : undef;
}

1;
