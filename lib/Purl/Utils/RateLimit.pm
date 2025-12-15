package Purl::Utils::RateLimit;
use strict;
use warnings;
use 5.024;

use Exporter 'import';

our @EXPORT_OK = qw(
    make_rate_limiter
);

# Create rate limiter with shared state
# Returns: $check_rate_limit coderef
sub make_rate_limiter {
    my (%opts) = @_;
    my $max_requests = $opts{max_requests} // 1000;
    my $window_seconds = $opts{window} // 60;

    my %rate_limit;

    return sub {
        my ($ip) = @_;
        my $now = time();
        my $window_start = int($now / $window_seconds) * $window_seconds;

        my $key = "$ip:$window_start";

        # Cleanup old entries
        for my $k (keys %rate_limit) {
            delete $rate_limit{$k} if $k !~ /:$window_start$/;
        }

        $rate_limit{$key}++;
        return $rate_limit{$key} <= $max_requests;
    };
}

1;

__END__

=head1 NAME

Purl::Utils::RateLimit - Simple rate limiting utilities

=head1 SYNOPSIS

    use Purl::Utils::RateLimit qw(make_rate_limiter);

    my $check_rate_limit = make_rate_limiter(
        max_requests => 1000,
        window => 60,  # seconds
    );

    if ($check_rate_limit->($ip_address)) {
        # Request allowed
    } else {
        # Rate limit exceeded
    }

=cut
