package Purl::Util::Level;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
our @EXPORT_OK = qw(canonical_level level_synonyms level_spellings canonical_levels);

# ============================================
# One name per log level (#105, #110)
# ============================================
#
# Shippers disagree on spelling: Vector and OTLP send WARN, syslog sends
# WARNING; Go and Postgres say PANIC, syslog says CRIT/EMERG/ALERT. Stored as
# they arrive, every one of those is its own facet bucket and needs its own
# filter. So ingest stores the canonical name, and queries expand a canonical
# name back into every spelling older rows may still carry — `level` is part
# of the sort key, so ClickHouse will not rewrite rows already written.
#
# Canonical names are the ones the UI colour map, the OTLP severity mapping
# and the dashboard templates already use. Anything not listed here (a custom
# level such as AUDIT) is kept as it is, upper-cased.
my %SYNONYM_OF = (
    WARNING   => 'WARN',
    ERR       => 'ERROR',
    CRIT      => 'FATAL',
    CRITICAL  => 'FATAL',
    EMERG     => 'FATAL',
    EMERGENCY => 'FATAL',
    ALERT     => 'FATAL',
    PANIC     => 'FATAL',
    NOTICE    => 'INFO',
);

my @CANONICAL = qw(TRACE DEBUG INFO WARN ERROR FATAL);

# canonical_level($raw) -> upper-case canonical name, '' for empty/undef.
sub canonical_level {
    my ($raw) = @_;
    my $level = uc($raw // '');
    $level =~ s/\A\s+|\s+\z//g;
    return $SYNONYM_OF{$level} // $level;
}

# level_synonyms($raw) -> every upper-case spelling that means the same level,
# canonical name first. level_synonyms('warning') is ('WARN', 'WARNING').
sub level_synonyms {
    my ($raw) = @_;
    my $canonical = canonical_level($raw);
    return ($canonical, sort grep { $SYNONYM_OF{$_} eq $canonical } keys %SYNONYM_OF);
}

# level_spellings(@levels) -> every spelling a row of these levels may be
# stored under: each synonym in the three cases shippers used before ingest
# normalised them (#105) — ERROR, error, Error, ERR, err, Err. A mixed case
# such as `wArN` is not covered; no known shipper writes one.
sub level_spellings {
    my (@levels) = @_;
    my %seen;
    return grep { length && !$seen{$_}++ }
        map { ($_, lc $_, ucfirst lc $_) }
        map { level_synonyms($_) } @levels;
}

# The levels Purl itself produces and filters on, most to least verbose.
sub canonical_levels { return @CANONICAL }

1;

__END__

=head1 NAME

Purl::Util::Level - canonical log level names and their synonyms

=head1 SYNOPSIS

    use Purl::Util::Level qw(canonical_level level_synonyms);

    canonical_level(' warning ');   # 'WARN'
    level_synonyms('fatal');        # ('FATAL', 'ALERT', 'CRIT', ...)

=head1 DESCRIPTION

Ingest stores C<canonical_level> of every incoming level. Queries use
C<level_synonyms> so a filter on a canonical level still matches rows written
before synonyms were folded together.

=cut
