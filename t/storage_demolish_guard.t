#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use File::Temp qw(tempdir);
use File::Spec ();

# ============================================================================
# DEMOLISH is a guarded best-effort flush (#90).
#
# The real shutdown flush is explicit (Purl::API::Server::Shutdown, proven
# against ClickHouse in t/ingest_shutdown_flush.t). DEMOLISH must:
#   - still flush an object freed at RUNTIME (old storage after a rebuild);
#   - do NOTHING during global destruction, where the HTTP client / JSON
#     encoder may already be freed ("Can't call method encode ... during
#     global destruction");
#   - never die (a failed flush is a warning, not an exception from DESTROY).
# No ClickHouse needed: the HTTP client is a recording fake.
# ============================================================================

{
    package FakeHTTP;
    sub new  { my ($class, %a) = @_; return bless { posts => [], %a }, $class }
    sub post {
        my ($self, $url, $req) = @_;
        push @{$self->{posts}}, $req->{content};
        return $self->{fail}
            ? { success => 0, status => 500, content => 'boom' }
            : { success => 1, status => 200, content => '' };
    }
}

require Purl::Storage::ClickHouse;
{
    no warnings 'redefine';
    *Purl::Storage::ClickHouse::_init_schema = sub { 1 };   # no ClickHouse
}

sub storage_with { return Purl::Storage::ClickHouse->new(_http => shift) }

subtest 'runtime destroy still flushes the buffer (best effort)' => sub {
    my $http = FakeHTTP->new;
    {
        my $s = storage_with($http);
        $s->insert({ message => 'freed at runtime', service => 'demolish-t' });
        is scalar @{$http->{posts}}, 0, 'buffered, not yet sent';
    }
    is scalar @{$http->{posts}}, 1, 'DEMOLISH flushed once when the object went away';
    like $http->{posts}[0], qr/freed at runtime/, 'the buffered log was sent';
};

subtest 'in_global_destruction flag => no flush' => sub {
    my $http = FakeHTTP->new;
    my $s = storage_with($http);
    $s->insert({ message => 'gd', service => 'demolish-t' });
    $s->DEMOLISH(1);
    is scalar @{$http->{posts}}, 0, 'nothing sent when Moo reports global destruction';
    is $s->buffer_depth, 1, 'buffer untouched';
    $s->_buffer([]);    # keep the runtime DEMOLISH of $s quiet
};

subtest 'a failing flush in DEMOLISH warns, never dies' => sub {
    my $http = FakeHTTP->new(fail => 1);
    my @warn;
    local $SIG{__WARN__} = sub { push @warn, @_ };
    my $ok = eval {
        my $s = storage_with($http);
        $s->insert({ message => 'will fail', service => 'demolish-t' });
        1;
    };
    ok $ok, 'object destruction did not throw';
    ok((grep { /buffer flush on destroy failed/ } @warn), 'failure reported as a warning')
        or diag explain \@warn;
};

subtest 'real global destruction: skipped cleanly, no "(in cleanup)" noise' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $hits = File::Spec->catfile($dir, 'posts');
    my $err  = File::Spec->catfile($dir, 'stderr');
    my $lib  = "$Bin/../lib";

    # A storage object that is still alive at exit (package global, like the
    # server's) with a buffered log, and an HTTP fake that records any post.
    my $code = <<'PERL';
package FileHTTP;
sub new  { bless { f => $_[1] }, $_[0] }
sub post { open my $fh, '>>', $_[0]{f} or die; print {$fh} "post\n"; close $fh;
           return { success => 1, status => 200, content => '' } }
package main;
require Purl::Storage::ClickHouse;
{ no warnings 'redefine'; *Purl::Storage::ClickHouse::_init_schema = sub { 1 }; }
our $S = Purl::Storage::ClickHouse->new(_http => FileHTTP->new($ARGV[0]));
$S->insert({ message => 'left in buffer at exit', service => 'demolish-t' });
exit 0;
PERL

    my $rc = system {$^X} $^X, "-I$lib", (map { "-I$_" } grep { !ref } @INC),
        '-e', "open STDERR, '>', q{$err} or die; $code", $hits;
    is $rc, 0, 'process exited cleanly';

    my $stderr = do { local (@ARGV, $/) = ($err); <> } // '';
    unlike $stderr, qr/in cleanup|during global destruction/,
        'no flush attempted during global destruction' or diag $stderr;
    ok !-e $hits, 'DEMOLISH did not try to POST in the DESTRUCT phase';
};

done_testing;
