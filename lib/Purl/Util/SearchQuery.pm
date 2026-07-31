package Purl::Util::SearchQuery;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use Purl::Util::KQL qw(parse_kql %FIELD_KIND);

our @EXPORT_OK = qw(plan_search_query looks_like_kql);

# ============================================
# What did the user actually type?
# ============================================
#
# The search box is used for two different things and the backend has to tell
# them apart BEFORE parsing:
#
#   1. an expression   — `level:error AND service:api`
#   2. a piece of text — `at Foo::bar()`, `timeout)`, `connection refused`
#
# Sending (2) through the KQL grammar is what broke plain-text search: a
# pasted stack-trace fragment 400s on `unexpected 'rparen'`, and a two-word
# phrase silently became an AND of two independent terms.
#
# So the grammar is only applied when the string contains an UNAMBIGUOUS KQL
# marker. Everything else is a literal substring search on `message`, which is
# what the search box did before KQL existed.
#
# Once a marker IS present the parse is strict: a syntax error is a 400, never
# a silent fallback. Falling back there would resurrect the original defect —
# `level:error AND service:x` quietly returning MORE rows than `level:error`.

# Longest first so no field name can be shadowed by a prefix of another.
my $FIELD_ALT = join '|',
    (sort { length($b) <=> length($a) || $a cmp $b } keys %FIELD_KIND),
    'meta\.[A-Za-z][A-Za-z0-9_]*';

# A bare, UPPER-CASE boolean operator IN OPERATOR POSITION.
#
# "bare and upper-case" alone is not enough. `404 NOT FOUND` is the single most
# common HTTP search there is, and reading its `NOT` as an operator turns it
# into `404 AND NOT FOUND` — which matches nothing at all, because every line
# carrying the phrase also carries `FOUND`. No error, no 400, just a wrong
# answer: exactly the defect class this module exists to prevent.
#
# So position decides:
#   NOT      prefix — only at the start, after `(`, or after another operator,
#                     and only with something after it to negate.
#   AND / OR infix  — only with an operand (or `)`) before AND an operand,
#                     `(` or `NOT` after.
#
# Everything else — `404 NOT FOUND`, `user NOT authorized`, a lone `OR`,
# `failed (OR timeout)` — is prose and stays a literal search.
#
# Lower-case `and`/`or`/`not` are never markers in any position: "connection
# and timeout" is prose, and promoting it is the same silent meaning-change.
sub _has_operator_marker {
    my ($input) = @_;

    # Parens bind to their neighbours in real log text (`Foo::bar()`), so
    # separate them before splitting into words.
    my $spaced = $input;
    $spaced =~ s/([()])/ $1 /g;
    my @tokens = split ' ', $spaced;

    # True where an operand may begin: string start, after `(`, after an
    # operator. Equivalently: false right after an operand or a `)`.
    my $operand_slot = 1;

    for my $i (0 .. $#tokens) {
        my $token = $tokens[$i];

        if ($token eq '(') { $operand_slot = 1; next }
        if ($token eq ')') { $operand_slot = 0; next }

        # What may legally follow an operator: an operand, a `(`, or a `NOT`.
        my $next = $i < $#tokens ? $tokens[$i + 1] : undef;
        my $operand_follows = defined $next
            && $next ne ')' && $next ne 'AND' && $next ne 'OR';

        if ($token eq 'NOT') {
            return 1 if $operand_slot && $operand_follows;
        }
        elsif ($token eq 'AND' || $token eq 'OR') {
            return 1 if !$operand_slot && $operand_follows;
        }

        # Not an operator here — it is just a word in the search text.
        $operand_slot = 0;
    }

    return 0;
}

sub looks_like_kql {
    my ($input) = @_;
    return 0 unless defined $input && $input =~ /\S/;

    return 1 if _has_operator_marker($input);

    # known_field:value, with NO whitespace around the colon and no second
    # colon. `Foo::bar()` has neither a known field name nor a lone colon, and
    # a log line reading `host: unreachable` keeps its space and stays literal.
    return 1 if $input =~ /(?:^|[\s(])(?:$FIELD_ALT):(?!:)\S/i;

    # A string that is nothing but one quoted literal is an explicit phrase
    # request; without this the quotes themselves would be searched for.
    return 1 if $input =~ /\A\s*"(?:[^"\\]|\\.)*"\s*\z/;
    return 1 if $input =~ /\A\s*'(?:[^'\\]|\\.)*'\s*\z/;

    return 0;
}

# plan_search_query($string) -> (\%storage_params, $error)
#
# %storage_params is merged into the params passed to Storage::search/count:
#   { kql => $ast }   an expression
#   { query => $text} a literal substring match (bound, never interpolated)
#   {}                nothing to filter on
#
# $error is set ONLY for a string that declared itself as KQL and then failed
# to parse; callers must surface it as a 400.
sub plan_search_query {
    my ($input) = @_;

    return ({}, undef) unless defined $input && $input =~ /\S/;

    unless (looks_like_kql($input)) {
        my $literal = $input;
        $literal =~ s/\A\s+//;
        $literal =~ s/\s+\z//;
        return ({ query => $literal }, undef);
    }

    my ($ast, $err) = parse_kql($input);
    return (undef, $err) if $err;
    return (($ast ? { kql => $ast } : {}), undef);
}

1;

__END__

=head1 NAME

Purl::Util::SearchQuery - decide whether a search string is KQL or literal text

=head1 SYNOPSIS

    use Purl::Util::SearchQuery qw(plan_search_query);

    my ($params, $err) = plan_search_query($q);
    die $err if $err;          # only ever set for explicit-but-broken KQL
    $storage->search(%$params, limit => 100);

=head1 DESCRIPTION

C<looks_like_kql> reports whether a raw search string contains an unambiguous
KQL marker: a bare upper-case C<AND>/C<OR>/C<NOT> B<in operator position>, a
C<known_field:value> pair written without spaces around the colon, or a wholly
quoted phrase.

Operator position is what keeps C<404 NOT FOUND> a phrase: C<NOT> only counts
at the start of the string, after C<(>, or after another operator, and C<AND>
and C<OR> only count between two operands.

C<plan_search_query> turns the string into storage filter parameters. Without a
marker the text is searched literally, so pasting C<at Foo::bar()> or
C<timeout)> into the search box works. With a marker the KQL grammar applies
strictly and a syntax error is returned to the caller rather than silently
dropped.

=cut
