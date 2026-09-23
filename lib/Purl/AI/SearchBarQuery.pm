package Purl::AI::SearchBarQuery;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use Purl::Util::SearchQuery qw(plan_search_query);
use Purl::Util::KQL qw(%FIELD_KIND);

our @EXPORT_OK = qw(search_bar_query);

# ============================================
# Vet a model-written search-bar query before it is handed to the dashboard
# (#98). The search bar speaks KQL (Purl::Util::KQL via plan_search_query);
# an AI answer is only returned if it is KQL that the SAME parser accepts and
# every field it names is one the search backend really knows.
#
# Why stricter than the search bar itself: the search bar falls back to a
# literal text search for anything that is not KQL, and compiles an unknown
# field to a message substring match. For text a person typed that is the
# right forgiveness; for text a model produced it means a hallucinated field
# (`status:500`) or a repeated SQL statement silently searches for the wrong
# thing. Such an answer is dropped, never "repaired".
# ============================================

# The same meta.<key> shape Purl::Storage::ClickHouse::KQL compiles.
my $META_FIELD = qr/\Ameta\.[a-z][a-z0-9_]{0,31}\z/;

# search_bar_query($text) -> the cleaned query string, or undef when it is
# empty, NONE, not KQL, fails to parse, or names an unknown field.
sub search_bar_query {
    my ($text) = @_;
    return unless defined $text;

    my $q = $text;
    $q =~ s/\A\s*`+//;
    $q =~ s/`+\s*\z//;
    $q =~ s/\A\s+|\s+\z//g;
    return if $q eq '' || $q =~ /\ANONE\z/i;
    # SQL echoed into the search slot tokenizes as bare words joined by AND,
    # which the parser happily accepts as a full-text search.
    return if $q =~ /\A(?:SELECT|WITH)\b/i;

    my ($plan, $err) = plan_search_query($q);
    return if $err || !$plan || !$plan->{kql};
    return unless _fields_known($plan->{kql});
    return $q;
}

sub _fields_known {
    my ($node) = @_;
    my $op = $node->{op} // '';
    return _fields_known($node->{child}) if $op eq 'not';
    if ($op eq 'and' || $op eq 'or') {
        _fields_known($_) || return 0 for @{ $node->{children} // [] };
        return 1;
    }
    return 0 unless $op eq 'term';
    my $field = $node->{field};
    return 1 unless defined $field;    # bare term: full-text on message
    return $FIELD_KIND{$field} || $field =~ $META_FIELD ? 1 : 0;
}

1;

__END__

=head1 NAME

Purl::AI::SearchBarQuery - accept a model-written search-bar (KQL) query only
if the search parser does

=head1 SYNOPSIS

    use Purl::AI::SearchBarQuery qw(search_bar_query);

    my $q = search_bar_query($model_output);   # undef => do not return one

=cut
