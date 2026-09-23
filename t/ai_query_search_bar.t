#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

# ============================================
# #98: POST /api/ai/query also returns `query`, the question's filter in the
# search-bar (KQL) syntax, so "Apply" in the dashboard puts something the
# search bar can run. It is validated with the search parser itself and
# omitted — never returned broken — when it does not parse. SQL is unchanged.
# ============================================

BEGIN {
    $ENV{PURL_AI_PROVIDER} = 'openai';
    $ENV{PURL_AI_API_KEY}  = 'test-key';
}
use PurlTest::SessionApp qw(app storage login csrf);
use Purl::AI::QueryGenerator;
use Purl::AI::SearchBarQuery qw(search_bar_query);
use Purl::AI::Factory;

my $SQL = "SELECT formatDateTime(timestamp, '%Y-%m-%dT%H:%i:%S') || 'Z' AS ts, message "
        . "FROM purl.logs WHERE level = 'ERROR' AND service = 'api' LIMIT 500";

# ---- the validator ---------------------------------------------------------

subtest 'search_bar_query: only KQL the search parser accepts, with known fields' => sub {
    is search_bar_query('level:ERROR service:api'), 'level:ERROR service:api', 'plain field terms';
    is search_bar_query('  `level:ERROR AND message:"connection refused"`  '),
        'level:ERROR AND message:"connection refused"', 'backticks and padding stripped';
    is search_bar_query('(level:ERROR OR level:CRITICAL) AND NOT service:auth'),
        '(level:ERROR OR level:CRITICAL) AND NOT service:auth', 'boolean + grouping';
    is search_bar_query('meta.pod:web-1'), 'meta.pod:web-1', 'meta.<key>';
    is search_bar_query('"timeout"'), '"timeout"', 'a quoted phrase';

    for my $bad ('level:ERROR AND', 'level:(ERROR OR CRITICAL)', '(level:ERROR', 'NONE', 'none',
                 '', '   ', undef, 'SELECT * FROM logs', 'timeout errors',
                 'level:ERROR AND status:500', 'foo:bar') {
        is search_bar_query($bad), undef, 'rejected: ' . ($bad // 'undef');
    }
};

# ---- the generator ---------------------------------------------------------

{
    package FakeProvider;
    sub new      { my ($class, $answer) = @_; return bless { answer => $answer }, $class }
    sub generate { my ($self, $q, $ctx) = @_; $self->{context} = $ctx; return $self->{answer} }
}

sub generate_with {
    my ($answer) = @_;
    my $fake = FakeProvider->new($answer);
    my $gen = Purl::AI::QueryGenerator->new(provider => 'openai', api_key => 'k', _provider_obj => $fake);
    return ($gen->generate('errors from api'), $fake);
}

subtest 'generator: a valid search query is returned beside the SQL' => sub {
    my ($r, $fake) = generate_with("SQL:\n```sql\n$SQL;\n```\nSEARCH:\nlevel:ERROR service:api\n");
    is $r->{sql},   $SQL,                      'SQL cleaned as before';
    is $r->{query}, 'level:ERROR service:api', 'query returned';
    like $fake->{context}, qr/SEARCH:/, 'the prompt asks for the search-bar form';
};

subtest 'generator: an invalid search query is omitted, SQL unaffected' => sub {
    for my $search ('level:ERROR AND', 'status:500', 'NONE', $SQL) {
        my ($r) = generate_with("SQL:\n$SQL\nSEARCH:\n$search\n");
        is $r->{sql}, $SQL, "SQL returned ($search)";
        ok !exists $r->{query}, "no query key ($search)";
    }
};

subtest 'generator: a model that ignores the format still yields its SQL' => sub {
    my ($r) = generate_with("```sql\n$SQL\n```");
    is $r->{sql}, $SQL, 'bare SQL answer';
    ok !exists $r->{query}, 'and no query';

    ($r) = generate_with("SEARCH: level:ERROR\nSQL: $SQL");
    is $r->{sql},   $SQL,          'sections in the other order';
    is $r->{query}, 'level:ERROR', 'still parsed';

    ($r) = generate_with("SQL:\nDROP TABLE purl.logs\nSEARCH:\nlevel:ERROR");
    like $r->{error}, qr/Only SELECT/, 'SQL validation still refuses a bad statement';
    ok !exists $r->{query}, 'and nothing else is returned with the error';
};

# ---- the endpoint ----------------------------------------------------------

my $ANSWER;
{
    no warnings 'redefine';
    *Purl::AI::Factory::create = sub { return FakeProvider->new($ANSWER) };
    my @rows = ({ ts => '2026-09-23T10:00:00Z', message => 'boom' });
    *PurlTest::Mock::ServerStorage::_query_json = sub { return [@rows] };
}

sub ask {
    my ($answer) = @_;
    $ANSWER = $answer;
    my $t = login('admin', 'StrongAdminPass123');
    return $t->post_ok('/api/ai/query', { 'X-CSRF-Token' => csrf($t) },
        json => { question => 'errors from api' });
}

subtest 'POST /api/ai/query: valid search query => `query` in the response' => sub {
    ask("SQL:\n$SQL\nSEARCH:\nlevel:ERROR service:api")
      ->status_is(200)
      ->json_is('/sql'   => $SQL)
      ->json_is('/query' => 'level:ERROR service:api')
      ->json_is('/total' => 1)
      ->json_is('/results/0/message' => 'boom');
};

subtest 'POST /api/ai/query: invalid search query => no `query`, the rest unchanged' => sub {
    my $t = ask("SQL:\n$SQL\nSEARCH:\nlevel:ERROR AND")
      ->status_is(200)
      ->json_is('/sql'   => $SQL)
      ->json_is('/total' => 1);
    ok !exists $t->tx->res->json->{query}, 'query omitted';
};

subtest 'POST /api/ai/query: legacy bare-SQL answer still works' => sub {
    my $t = ask($SQL)->status_is(200)->json_is('/sql' => $SQL);
    ok !exists $t->tx->res->json->{query}, 'query omitted';
};

done_testing();
