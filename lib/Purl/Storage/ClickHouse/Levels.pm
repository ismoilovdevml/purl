package Purl::Storage::ClickHouse::Levels;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use Purl::Util::Level qw(canonical_level canonical_levels level_synonyms level_spellings);
use namespace::clean;

# ============================================
# Level SQL that sees every spelling (#105, #110)
# ============================================
#
# Ingest stores one canonical, upper-case name per level (Purl::Util::Level).
# Rows written before that may say `warn`, `Warning` or `crit`, and `level` is
# a sort-key column ClickHouse will not rewrite. Every filter, facet and count
# on levels therefore goes through here, so a filter on WARN and the WARN
# facet bucket agree on which rows they mean.

# _level_filter_sql(\@levels, $placeholder) -> "level IN (...)"
#
# A plain `level IN (...)` over every stored spelling (level_spellings), so the
# (service, level, timestamp) primary key prunes granules; upper(level)
# cannot (#108). $placeholder->($value) returns the SQL for one value: a bind
# placeholder, or a quoted literal. Returns undef for an empty list.
sub _level_filter_sql {
    my ($self, $levels, $placeholder) = @_;
    my @spellings = level_spellings(@$levels);
    return unless @spellings;
    return 'level IN (' . join(', ', map { $placeholder->($_) } @spellings) . ')';
}

# _level_wildcard_sql($glob, $like_placeholder, $placeholder)
#
# `level:crit*`: a prefix of a synonym that ingest no longer stores must still
# find the rows stored under its canonical name (FATAL). The glob is matched
# against the synonym table here; the LIKE keeps matching any other stored
# level (custom names, old rows).
sub _level_wildcard_sql {
    my ($self, $glob, $like_placeholder, $placeholder) = @_;
    my $re = join '.*', map { quotemeta } split /\*/, uc($glob), -1;
    my %canonical = map { canonical_level($_) => 1 }
        grep { /\A$re\z/ } map { level_synonyms($_) } canonical_levels();
    my $like = 'upper(level) LIKE ' . $like_placeholder;
    my $in   = $self->_level_filter_sql([ sort keys %canonical ], $placeholder);
    return $in ? "($like OR $in)" : $like;
}

# Every stored spelling of the given canonical levels as quoted SQL literals,
# for countIf() buckets. Constants from Purl::Util::Level, never user input.
sub _level_literals {
    my ($self, @levels) = @_;
    return join ', ', map { $self->_quote_string($_) } map { level_synonyms($_) } @levels;
}

# upper(level) folded to its canonical name: the level facet's GROUP BY key.
sub _level_canonical_sql {
    my ($self) = @_;
    my @from = grep { canonical_level($_) ne $_ } map { level_synonyms($_) } canonical_levels();
    my $from = join ', ', map { $self->_quote_string($_) } @from;
    my $to   = join ', ', map { $self->_quote_string(canonical_level($_)) } @from;
    return "transform(upper(level), [$from], [$to], upper(level))";
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::Levels - level filter, facet and bucket SQL

=head1 DESCRIPTION

Role composed by L<Purl::Storage::ClickHouse::Query>. Turns canonical level
names into SQL that also matches older rows stored under another case or a
synonym (C<WARNING> for C<WARN>, C<CRIT> for C<FATAL>, ...).

=cut
