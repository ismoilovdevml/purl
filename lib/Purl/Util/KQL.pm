package Purl::Util::KQL;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
our @EXPORT_OK = qw(parse_kql %FIELD_KIND);

# The field names the language knows, and how a backend is expected to match
# them. SINGLE SOURCE OF TRUTH: Purl::Storage::ClickHouse::KQL builds its
# column maps from this, and Purl::Util::SearchQuery uses it to decide whether
# a raw search string is a KQL expression at all. Three copies of this list
# would drift; one cannot.
our %FIELD_KIND = (
    level      => 'exact',
    service    => 'exact',
    host       => 'exact',
    trace_id   => 'exact',
    request_id => 'exact',
    span_id    => 'exact',
    # Kubernetes metadata: materialized columns of the logs table (#104).
    namespace  => 'exact',
    pod        => 'exact',
    container  => 'exact',
    message    => 'text',
    raw        => 'text',
);

# ============================================
# KQL (Kibana-style Query Language) parser
# ============================================
#
# Produces an AST; it does NOT touch SQL. Compilation to a ClickHouse WHERE
# clause lives in Purl::Storage::ClickHouse::KQL so that the grammar can be
# tested without a database and so that the storage layer owns all SQL.
#
# Grammar (recursive descent, standard Lucene/KQL precedence):
#
#   expr     := or_expr
#   or_expr  := and_expr ( OR and_expr )*
#   and_expr := not_expr ( [AND] not_expr )*      # juxtaposition means AND
#   not_expr := NOT not_expr | primary
#   primary  := '(' expr ')' | term
#   term     := field ':' value | value
#   value    := '"..."' | "'...'" | bare
#
# NOT binds tighter than AND, AND binds tighter than OR. Parentheses override.
# AND/OR/NOT are recognised case-insensitively but ONLY as bare (unquoted)
# words; "AND" in quotes is a literal search term.
#
# AST node shapes:
#   { op => 'and',  children => [ ... ] }
#   { op => 'or',   children => [ ... ] }
#   { op => 'not',  child    => { ... } }
#   { op => 'term', field    => $name_or_undef, value => $string, quoted => 0|1 }

# Guard rails: a query is user input arriving on a public endpoint, so both the
# token count and the nesting depth are bounded before any recursion starts.
our $MAX_TOKENS = 256;
our $MAX_DEPTH  = 32;

my %KEYWORD = (AND => 'and', OR => 'or', NOT => 'not');

# ============================================
# Tokenizer
# ============================================

# Read one value literal at the current pos(): quoted or bare.
# Returns (value, quoted_flag, error).
sub _read_value {
    my ($src_ref) = @_;

    if ($$src_ref =~ /\G"((?:[^"\\]|\\.)*)"/gc) {
        my $v = $1;
        $v =~ s/\\(.)/$1/g;
        return ($v, 1, undef);
    }
    if ($$src_ref =~ /\G'((?:[^'\\]|\\.)*)'/gc) {
        my $v = $1;
        $v =~ s/\\(.)/$1/g;
        return ($v, 1, undef);
    }
    # A quote that did not match above never closes. Fail loudly rather than
    # silently searching for a truncated string.
    if ($$src_ref =~ /\G["']/) {
        return (undef, undef, 'unterminated quoted string');
    }
    if ($$src_ref =~ /\G([^\s()]+)/gc) {
        return ($1, 0, undef);
    }
    return (undef, undef, 'unparsable input');
}

# Turn the raw query string into a flat token list.
# Returns (\@tokens, undef) or (undef, $error).
sub _tokenize {
    my ($src) = @_;
    my @tokens;

    pos($src) = 0;
    my $len = length $src;

    while (pos($src) < $len) {
        return (undef, 'query too complex') if @tokens >= $MAX_TOKENS;

        next if $src =~ /\G\s+/gc;

        if ($src =~ /\G\(/gc) { push @tokens, { type => 'lparen' }; next; }
        if ($src =~ /\G\)/gc) { push @tokens, { type => 'rparen' }; next; }

        # field:value — the field name must be a bare identifier.
        if ($src =~ /\G([A-Za-z_][A-Za-z0-9_.]*)\s*:\s*/gc) {
            my $field = lc $1;
            my ($value, $quoted, $err) = _read_value(\$src);
            return (undef, "missing value for field '$field'")
                if !defined $value && $err eq 'unparsable input';
            return (undef, $err) if $err;
            push @tokens, {
                type   => 'term',
                field  => $field,
                value  => $value,
                quoted => $quoted,
            };
            next;
        }

        my ($value, $quoted, $err) = _read_value(\$src);
        return (undef, $err) if $err;

        if (!$quoted && exists $KEYWORD{uc $value}) {
            push @tokens, { type => $KEYWORD{uc $value} };
            next;
        }

        push @tokens, {
            type   => 'term',
            field  => undef,
            value  => $value,
            quoted => $quoted,
        };
    }

    return (\@tokens, undef);
}

# ============================================
# Parser
# ============================================

# Parser state is a plain hash: the token list plus a cursor. Passed by
# reference through the descent so every level shares one cursor.
sub _peek { my ($s) = @_; return $s->{tokens}[ $s->{pos} ]; }
sub _next { my ($s) = @_; return $s->{tokens}[ $s->{pos}++ ]; }

sub _parse_expr {
    my ($s, $depth) = @_;
    die "query nested too deeply\n" if $depth > $MAX_DEPTH;

    my $left = _parse_and($s, $depth);

    while (my $tok = _peek($s)) {
        last unless $tok->{type} eq 'or';
        _next($s);
        my $right = _parse_and($s, $depth);
        $left = { op => 'or', children => [ $left, $right ] };
    }

    return $left;
}

sub _parse_and {
    my ($s, $depth) = @_;

    my $left = _parse_not($s, $depth);

    while (my $tok = _peek($s)) {
        my $type = $tok->{type};
        if ($type eq 'and') {
            _next($s);
        }
        # Juxtaposition (`level:error service:api`) is an implicit AND. Any
        # token that can START an operand continues the AND chain.
        elsif ($type ne 'term' && $type ne 'not' && $type ne 'lparen') {
            last;
        }
        my $right = _parse_not($s, $depth);
        $left = { op => 'and', children => [ $left, $right ] };
    }

    return $left;
}

sub _parse_not {
    my ($s, $depth) = @_;

    my $tok = _peek($s);
    die "incomplete expression\n" unless $tok;

    if ($tok->{type} eq 'not') {
        _next($s);
        return { op => 'not', child => _parse_not($s, $depth) };
    }

    return _parse_primary($s, $depth);
}

sub _parse_primary {
    my ($s, $depth) = @_;

    my $tok = _next($s);
    die "incomplete expression\n" unless $tok;

    if ($tok->{type} eq 'lparen') {
        my $inner = _parse_expr($s, $depth + 1);
        my $close = _next($s);
        die "unbalanced parentheses\n"
            unless $close && $close->{type} eq 'rparen';
        return $inner;
    }

    if ($tok->{type} eq 'term') {
        return {
            op     => 'term',
            field  => $tok->{field},
            value  => $tok->{value},
            quoted => $tok->{quoted} ? 1 : 0,
        };
    }

    die "unexpected '$tok->{type}'\n";
}

# ============================================
# Public entry point
# ============================================

# parse_kql($string) -> ($ast, $error)
#
# Empty / whitespace-only input returns (undef, undef): no filter, not an error.
# A syntax error returns (undef, $message) — callers MUST surface it. Silently
# dropping an unparsable filter is what made `level:error AND service:x` return
# MORE rows than `level:error`.
sub parse_kql {
    my ($input) = @_;

    return (undef, undef) unless defined $input && $input =~ /\S/;

    my ($tokens, $err) = _tokenize($input);
    return (undef, $err) if $err;
    return (undef, undef) unless @$tokens;

    my $state = { tokens => $tokens, pos => 0 };

    my $ast = eval { _parse_expr($state, 0) };
    if (my $die = $@) {
        chomp $die;
        return (undef, $die);
    }

    if ($state->{pos} < @$tokens) {
        my $left = $tokens->[ $state->{pos} ]{type};
        return (undef, $left eq 'rparen' ? 'unbalanced parentheses'
                                         : "unexpected '$left'");
    }

    return ($ast, undef);
}

1;

__END__

=head1 NAME

Purl::Util::KQL - Kibana-style query language parser

=head1 SYNOPSIS

    use Purl::Util::KQL qw(parse_kql);

    my ($ast, $err) = parse_kql('service:api AND (level:error OR level:warn)');
    die $err if $err;

=head1 DESCRIPTION

Parses a KQL expression into an AST with correct C<NOT> > C<AND> > C<OR>
precedence and parenthesised grouping. Whitespace between operands is an
implicit C<AND>.

Booleans are only recognised as bare words: C<"AND"> in quotes is a literal
term. There is no C<-> negation prefix, because C<-> is a legal character
inside service and host names (C<service:svc-a>); use C<NOT>.

Returns C<(undef, undef)> for an empty query and C<(undef, $message)> for a
syntax error. It never returns a partially-parsed AST.

=cut
