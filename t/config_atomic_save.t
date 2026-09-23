#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);
use File::Spec;
use Mojo::JSON qw(from_json);
use POSIX ();

use Purl::Config;

# ============================================================
# REGRESSION: a torn read must never destroy the credential store.
#
# Workers re-read settings.json whenever its stat stamp moves (that is what
# makes a user created on one prefork worker visible to the others). An
# in-place `open '>'` truncates first and prints second, and truncation moves
# the stamp immediately — so any worker touching config in that window is
# guaranteed to read a partial file.
#
# Before the fix, load() answered a decode failure by blanking _config to {}.
# That dropped every user, API key and saved section, and the next save()
# persisted the emptiness. Two properties close it:
#   1. save() writes to a temp file and rename(2)s it into place, so no reader
#      ever observes a partial file;
#   2. load() keeps the last good config on decode failure and clears the
#      stamp so the next access retries.
# ============================================================

sub new_config {
    my ($dir) = @_;
    return Purl::Config->new(config_file => File::Spec->catfile($dir, 'settings.json'));
}

subtest 'a partial file never blanks users, api keys or other sections' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $cfg  = new_config($dir);
    my $file = File::Spec->catfile($dir, 'settings.json');

    $cfg->set_section('auth', {
        users    => { admin => { password => 'hash', role => 'admin' } },
        api_keys => ['key-1'],
    });
    $cfg->set_section('ldap', { server => 'ldap.example.com' });
    ok $cfg->save, 'saved';

    is_deeply [sort keys %{ $cfg->get_section('auth')->{users} }], ['admin'],
        'user present before the torn read';

    # Simulate exactly what another worker's in-place write looked like
    # mid-flight: the file exists, its stamp has moved, and it is truncated.
    open my $fh, '>:encoding(UTF-8)', $file or die $!;
    print $fh '{ "auth": { "use';   # cut off mid-token
    close $fh;

    my $users = $cfg->get_section('auth')->{users} // {};
    is_deeply [sort keys %$users], ['admin'],
        'user SURVIVES a torn read (was wiped to [] before the fix)';
    is $cfg->get_section('ldap')->{server}, 'ldap.example.com',
        'other sections survive a torn read';
    is_deeply $cfg->get_section('auth')->{api_keys}, ['key-1'],
        'api keys survive a torn read';
};

subtest 'a partial file is never persisted back over good data' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $cfg  = new_config($dir);
    my $file = File::Spec->catfile($dir, 'settings.json');

    $cfg->set_section('auth', { users => { admin => { role => 'admin' } } });
    $cfg->save;

    open my $fh, '>:encoding(UTF-8)', $file or die $!;
    print $fh '{ "auth": { "use';
    close $fh;

    $cfg->get_section('auth');                 # provoke the failed reload
    $cfg->set_section('server', { port => 3000 });
    $cfg->save;                                # any later write

    my $fresh = new_config($dir);
    is_deeply [sort keys %{ $fresh->get_section('auth')->{users} // {} }], ['admin'],
        'on-disk user survives (before the fix the file became {"server":{"port":3000}})';
};

subtest 'a concurrent reader never observes a partial file' => sub {
    # This has to be a real race. A single-threaded test can never sit between
    # truncate() and print(), so it passes just as happily against an in-place
    # write — verified by mutation. A forked reader spinning while the parent
    # rewrites is what actually distinguishes the two.
    my $dir  = tempdir(CLEANUP => 1);
    my $cfg  = new_config($dir);
    my $file = File::Spec->catfile($dir, 'settings.json');

    # Big enough that an in-place write cannot complete within one read.
    $cfg->set_section('auth', {
        users => { map { ("user$_" => { role => 'viewer', note => 'x' x 200 }) } 1 .. 300 },
    });
    $cfg->save;

    my $flag = File::Spec->catfile($dir, 'torn');
    my $pid  = fork();
    plan skip_all => 'fork unavailable' unless defined $pid;

    if ($pid == 0) {
        # Child: read as fast as possible; record any read that fails to decode.
        for (1 .. 4000) {
            open my $fh, '<:encoding(UTF-8)', $file or next;
            local $/;
            my $json = <$fh>;
            close $fh;
            next unless defined $json && length $json;
            unless (eval { from_json($json) }) {
                my $ok = open my $flag_fh, '>', $flag;
                close $flag_fh if $ok;
                last;
            }
        }
        POSIX::_exit(0);
    }

    # Parent: rewrite repeatedly while the child reads.
    for my $i (1 .. 60) {
        $cfg->set_section('server', { port => 3000 + $i });
        $cfg->save;
    }
    waitpid $pid, 0;

    ok !-e $flag,
        'no reader ever saw a partial file (fails against truncate-then-print)';
};

subtest 'no temp files are left behind' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $cfg = new_config($dir);

    $cfg->set_section('server', { port => 3000 });
    $cfg->save for 1 .. 3;

    opendir my $dh, $dir or die $!;
    my @leftovers = grep { /\.tmp/ } readdir $dh;
    closedir $dh;

    is_deeply \@leftovers, [], 'rename consumed every temp file';
};

done_testing();
