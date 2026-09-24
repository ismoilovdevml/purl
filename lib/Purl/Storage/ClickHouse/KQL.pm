package Purl::Storage::ClickHouse::KQL;
use strict;
use warnings;
use 5.024;

use Moo::Role;

use Purl::Util::KQL qw(%FIELD_KIND);

# ============================================
# KQL AST -> ClickHouse WHERE fragment
# ============================================
#
# Consumes the AST produced by Purl::Util::KQL and emits SQL. EVERY user value
# leaves through a bind parameter ({p_kql_N:String}); nothing from the query is
# ever interpolated into the statement text.
#
# Kept out of Purl::Storage::ClickHouse::Query on purpose: Query owns the
# flat "filter params" builder, this owns the boolean expression compiler.

# Columns compared for equality / searched as substrings. Derived from the
# language's field registry so the parser, the intent detector and this
# compiler can never disagree about which names are fields.
my %EXACT_COLUMN = map { $_ => 1 } grep { $FIELD_KIND{$_} eq 'exact' } keys %FIELD_KIND;
my %TEXT_COLUMN  = map { $_ => 1 } grep { $FIELD_KIND{$_} eq 'text' }  keys %FIELD_KIND;

# ClickHouse LIKE metacharacters. A user searching for `svc_a` must not get
# `svc-a` back, so escape them before splicing in the wildcards.
sub _kql_like_pattern {
    my ($self, $value) = @_;
    $value =~ s/([\\%_])/\\$1/g;
    $value =~ s/\*/%/g;
    return $value;
}

# Register a bind value and return its placeholder.
sub _kql_bind {
    my ($self, $bind, $seq, $value) = @_;
    my $name = 'p_kql_' . $$seq++;
    $bind->{$name} = $value;
    return "{${name}:String}";
}

sub _kql_term_sql {
    my ($self, $node, $bind, $seq) = @_;

    my $field = $node->{field};
    my $value = $node->{value};

    # Bare term (no field) => full-text on the message column.
    if (!defined $field) {
        return 'position(message, ' . $self->_kql_bind($bind, $seq, $value) . ') > 0';
    }

    if ($field =~ /^meta\.([a-z][a-z0-9_]{0,31})$/) {
        my $sub_field = $1;
        # meta is stored as a JSON string; the flat-param builder matches it the
        # same way (field name present AND value present).
        my $clean = $value;
        $clean =~ s/\*//g;
        my $f_ph = $self->_kql_bind($bind, $seq, $sub_field);
        my $v_ph = $self->_kql_bind($bind, $seq, $clean);
        return "(position(meta, $f_ph) > 0 AND position(meta, $v_ph) > 0)";
    }

    if ($TEXT_COLUMN{$field}) {
        return "position($field, " . $self->_kql_bind($bind, $seq, $value) . ') > 0';
    }

    if ($EXACT_COLUMN{$field}) {
        my $column = $field;
        # Levels are case-insensitive (#105) and synonyms are one level (#110).
        # Ingest now stores canonical names, but older rows may say `warn` or
        # `WARNING`, and `level` is a sort-key column that ClickHouse will not
        # rewrite — so match every stored spelling (Levels role).
        # A wildcard (`level:crit*`) also expands against the synonym table.
        if ($field eq 'level') {
            my $placeholder = sub { $self->_kql_bind($bind, $seq, $_[0]) };
            return $self->_level_filter_sql([$value], $placeholder)
                if $node->{quoted} || $value !~ /\*/;
            my $like = $self->_kql_bind($bind, $seq, $self->_kql_like_pattern(uc $value));
            return $self->_level_wildcard_sql($value, $like, $placeholder);
        }

        # A wildcard is only a wildcard when unquoted; level:"a*b" is literal.
        if (!$node->{quoted} && $value =~ /\*/) {
            my $pattern = $self->_kql_like_pattern($value);
            return "$column LIKE " . $self->_kql_bind($bind, $seq, $pattern);
        }
        return "$column = " . $self->_kql_bind($bind, $seq, $value);
    }

    # Unknown field: fall back to a message substring search on the value,
    # matching the behaviour the single-field parser had for unknown fields.
    return 'position(message, ' . $self->_kql_bind($bind, $seq, $value) . ') > 0';
}

# Compile a node. Always returns a parenthesised, self-contained fragment so
# the caller can AND it with other filters without precedence surprises.
sub _kql_to_sql {
    my ($self, $node, $bind, $seq) = @_;
    return unless ref $node eq 'HASH';

    my $op = $node->{op} // '';

    if ($op eq 'term') {
        return '(' . $self->_kql_term_sql($node, $bind, $seq) . ')';
    }

    if ($op eq 'not') {
        my $inner = $self->_kql_to_sql($node->{child}, $bind, $seq) or return;
        return "(NOT $inner)";
    }

    if ($op eq 'and' || $op eq 'or') {
        my @parts = grep { defined && length }
            map { $self->_kql_to_sql($_, $bind, $seq) } @{ $node->{children} // [] };
        return unless @parts;
        return '(' . join(" \U$op\E ", @parts) . ')';
    }

    return;
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::KQL - compile a KQL AST into a ClickHouse WHERE fragment

=head1 DESCRIPTION

Role consumed by L<Purl::Storage::ClickHouse>. Turns the AST from
L<Purl::Util::KQL> into a parenthesised SQL boolean expression plus a set of
bind parameters.

Field mapping:

=over 4

=item * C<service>, C<host>, C<namespace>, C<pod>, C<container>, C<trace_id>, C<request_id>, C<span_id> — equality (C<LIKE> when the unquoted value contains C<*>)

=item * C<level> — C<level IN> every stored spelling of the level (C<WARN> also matches C<WARNING>, C<warn>); a wildcard also expands against the synonym table

=item * C<message>, C<raw> — substring match via C<position()>

=item * C<meta.*> — substring match of the sub-field name and value against the meta JSON

=item * bare terms and unknown fields — substring match on C<message>

=back

=cut
