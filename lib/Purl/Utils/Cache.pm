package Purl::Utils::Cache;
use strict;
use warnings;
use 5.024;

use Exporter 'import';

our @EXPORT_OK = qw(
    make_cache_helpers
);

# Create cache helper functions with shared state
# Returns: ($cache_get, $cache_set, $cache_clear) coderefs
sub make_cache_helpers {
    my (%opts) = @_;
    my $default_ttl = $opts{ttl} // 60;

    my %cache;

    my $cache_get = sub {
        my ($key) = @_;
        my $entry = $cache{$key};
        return unless $entry;
        return if $entry->{expires} < time();
        return $entry->{value};
    };

    my $cache_set = sub {
        my ($key, $value, $ttl) = @_;
        $ttl //= $default_ttl;
        $cache{$key} = {
            value   => $value,
            expires => time() + $ttl,
        };
        return $value;
    };

    my $cache_clear = sub {
        %cache = ();
    };

    return ($cache_get, $cache_set, $cache_clear);
}

1;

__END__

=head1 NAME

Purl::Utils::Cache - Simple in-memory cache utilities

=head1 SYNOPSIS

    use Purl::Utils::Cache qw(make_cache_helpers);

    my ($cache_get, $cache_set, $cache_clear) = make_cache_helpers(ttl => 60);

    $cache_set->('key', { data => 'value' }, 30);  # 30 second TTL
    my $data = $cache_get->('key');
    $cache_clear->();

=cut
