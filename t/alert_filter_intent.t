#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Util::SearchQuery qw(plan_search_query);

# ============================================
# REGRESSION (#43): an alert filter and a search box entry are the SAME
# language and must mean the SAME thing.
#
# check_alerts() called parse_kql unconditionally while the search endpoints
# went through Purl::Util::SearchQuery. The moment search learned to tell an
# expression from a piece of text, the two drifted:
#
#   `at Foo::bar()`      search: literal phrase
#                        alert : parse error -> WHERE 0 -> can never fire,
#                                the only trace being a warn
#   `connection refused` search: one phrase
#                        alert : `connection AND refused`, which also matches a
#                                line with the two words far apart
#
# "test it in search, then save it as an alert" has to survive the round trip.
# ============================================

{
    package MockAlertCH;
    use Moo;
    with 'Purl::Storage::ClickHouse::Query';
    with 'Purl::Storage::ClickHouse::KQL';
    with 'Purl::Storage::ClickHouse::Alerts';

    has alerts   => (is => 'rw', default => sub { [] });
    has last_sql => (is => 'rw');
    has last_params => (is => 'rw', default => sub { {} });

    sub database { 'purl' }
    sub table    { 'logs' }
    sub _convert_to_clickhouse_ts { return $_[1] }

    sub _crud_read  { return $_[0]->alerts }
    sub _crud_write { return 1 }

    sub _query_json {
        my ($self, $sql, %opts) = @_;
        $self->last_sql($sql);
        $self->last_params($opts{params} // {});
        return [];
    }
}

# Run check_alerts() over a single enabled alert carrying $filter and return
# the WHERE fragment it produced plus the bind values it produced it with.
sub alert_where {
    my ($filter) = @_;

    my $ch = MockAlertCH->new(alerts => [{
        id                => '11111111-1111-1111-1111-111111111111',
        name              => 'probe',
        query             => $filter,
        condition         => 'count',
        threshold         => 1,
        window_minutes    => 5,
        notify_type       => 'webhook',
        notify_target     => '',
        last_triggered_ts => 0,
        now_ts            => 1_800_000_000,
    }]);

    $ch->check_alerts;

    my $sql = $ch->last_sql // '';
    my ($where) = $sql =~ /INTERVAL \d+ MINUTE\s+AND\s+(.*?)\s*\z/s;
    return ($where, $ch->last_params);
}

# The search side of the same string, compiled the way the search endpoints do.
sub search_where {
    my ($query) = @_;
    my ($params, $err) = plan_search_query($query);
    return (undef, undef, $err) if $err;
    my ($sql, $bind) = MockAlertCH->new->_build_where_clause(%$params);
    $sql =~ s/\A\s*WHERE\s+//;    # the alert side splices its fragment in bare
    return ($sql, $bind, undef);
}

# Bind NAMES legitimately differ (the search path names its literal p_query,
# the alert path allocates p_kql_N). The shape and the values must not.
sub normalize {
    my ($sql) = @_;
    return '' unless defined $sql;
    $sql =~ s/\{p_\w+:String\}/{BIND}/g;
    $sql =~ s/\s+/ /g;
    $sql =~ s/\A\s+|\s+\z//g;
    return $sql;
}

# ============================================
# The literal branch
# ============================================

subtest 'a plain-text alert filter becomes one bound phrase match' => sub {
    my ($where, $params) = alert_where('connection refused');

    like $where, qr/position\(message, \{p_kql_0:String\}\) > 0/,
        'compiled to a substring match on message';
    is $params->{p_kql_0}, 'connection refused',
        'the whole phrase travels as ONE bind value, not two terms';

    my @positions = $where =~ /(position\()/g;
    is scalar @positions, 1,
        'exactly one position() — `connection AND refused` would emit two';
};

subtest 'a stack-trace fragment no longer disables the alert' => sub {
    # This is the P0: parse_kql 400s on `at Foo::bar()`, and the old code
    # turned that into WHERE 0, so the alert silently never fired.
    my ($where, $params) = alert_where('at Foo::bar()');

    isnt $where, '0', 'the filter did NOT collapse to match-nothing';
    like $where, qr/position\(message, \{p_kql_0:String\}\) > 0/,
        'it is a literal phrase match';
    is $params->{p_kql_0}, 'at Foo::bar()', 'searched verbatim';
};

subtest '404 NOT FOUND means the same thing in an alert' => sub {
    my ($where, $params) = alert_where('404 NOT FOUND');
    unlike $where, qr/\bNOT\b/, 'no negation was invented';
    is $params->{p_kql_0}, '404 NOT FOUND', 'the phrase is the bind value';
};

subtest 'the literal branch is a bind value, never interpolated SQL' => sub {
    my $evil = q{x'); DROP TABLE logs;--};
    my ($where, $params) = alert_where($evil);
    unlike $where, qr/DROP TABLE/, 'nothing from the filter reached the SQL text';
    is $params->{p_kql_0}, $evil, 'it travelled as a parameter';
};

# ============================================
# The expression branch still works
# ============================================

subtest 'a real KQL filter is still compiled as an expression' => sub {
    my ($where, $params) = alert_where('level:error AND service:api');
    like $where, qr/upper\(level\) = /, 'level compiled to a case-insensitive equality (#105)';
    like $where, qr/service = /, 'service compiled to an equality';
    is_deeply [sort values %$params], [sort qw(ERROR api)],
        'both operand values bound';
};

subtest 'an empty filter matches every row in the window' => sub {
    for my $filter (undef, '', '   ') {
        my ($where) = alert_where($filter);
        is $where, '1=1', 'no filter condition added';
    }
};

subtest 'explicit-but-broken KQL still matches nothing, never everything' => sub {
    # Rows written before Controller::Alerts got its create-time gate. Widening
    # to 1=1 here would notify on every single log line.
    my $warned = '';
    local $SIG{__WARN__} = sub { $warned .= $_[0] };
    my ($where) = alert_where('level:error AND (service:api');
    is $where, '0', 'matches nothing';
    like $warned, qr/unparsable query/, 'and leaves a trace';
};

# ============================================
# Search and alert agree — the actual invariant
# ============================================

subtest 'the same string compiles identically for search and for alerts' => sub {
    for my $filter ('connection refused', 'at Foo::bar()', '404 NOT FOUND',
                    'timeout)', 'level:error', 'level:error AND service:api',
                    'NOT level:info', '{"level":"error"}') {
        my ($s_sql, $s_bind, $s_err) = search_where($filter);
        my ($a_sql, $a_bind) = alert_where($filter);

        is $s_err, undef, "'$filter' is valid for search";
        is normalize($a_sql), normalize($s_sql),
            "'$filter' compiles to the same condition on both sides";
        is_deeply [sort values %$a_bind], [sort values %$s_bind],
            "'$filter' binds the same values on both sides";
    }
};

done_testing();
