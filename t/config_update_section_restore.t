#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);

# ============================================
# REGRESSION (#91 re-review, MINOR 2): when update_section could not save, it
# put memory back by RELOADING settings.json. With no settings.json yet there
# is nothing to reload, so the failed change stayed live in this worker —
# a user "not created" could sign in here and nowhere else.
#
# It now restores a pre-write snapshot of the section.
# ============================================

use Purl::Config;

plan skip_all => 'running as root: a read-only directory is still writable'
    if $> == 0;

sub readonly_config {
    my $dir = tempdir(CLEANUP => 1);
    my $cfg = Purl::Config->new(config_file => "$dir/settings.json");
    chmod 0555, $dir or die "chmod: $!";
    return ($cfg, $dir);
}

subtest 'no settings.json + unwritable dir: a failed write leaves memory untouched' => sub {
    my ($cfg, $dir) = readonly_config();
    ok !-e "$dir/settings.json", 'precondition: no file';
    my $users_before = { %{ $cfg->get_section('auth')->{users} // {} } };

    my $ok = do {
        local $SIG{__WARN__} = sub {};
        $cfg->update_section('auth', sub { $_[0]{users}{mallory} = { password => 'x', role => 'admin' } });
    };
    ok !$ok, 'update_section reports the failure';
    ok !exists $cfg->get_section('auth')->{users}{mallory}, 'the unsaved user is not live in memory';
    is_deeply $cfg->get_section('auth')->{users} // {}, $users_before, 'users map as before';
    like $cfg->{_last_save_error}, qr/Cannot write/, 'the save error is kept for the caller';
    chmod 0755, $dir;
};

subtest 'an existing section with a nested map is restored, not left half-edited' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $cfg = Purl::Config->new(config_file => "$dir/settings.json");
    ok $cfg->update_section('auth', sub { $_[0]{users}{alice} = { password => 'h1', role => 'viewer' } }),
        'seed saved';
    chmod 0555, $dir or die "chmod: $!";
    # rename() into a read-only dir fails, so save() does.
    my $ok = do {
        local $SIG{__WARN__} = sub {};
        $cfg->update_section('auth', sub { $_[0]{users}{alice}{role} = 'admin' });
    };
    ok !$ok, 'save failed';
    is $cfg->get_section('auth')->{users}{alice}{role}, 'viewer',
        'the in-place edit of the nested users map was rolled back';
    chmod 0755, $dir;
};

subtest 'a cancelled update also rolls back what the callback touched' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $cfg = Purl::Config->new(config_file => "$dir/settings.json");
    $cfg->update_section('auth', sub { $_[0]{users}{bob} = { password => 'h', role => 'viewer' } });
    my $ok = $cfg->update_section('auth', sub {
        my ($s, $cancel) = @_;
        $s->{users}{bob}{role} = 'admin';
        $cancel->();
    });
    ok !$ok, 'cancelled';
    is $cfg->get_section('auth')->{users}{bob}{role}, 'viewer', 'nothing stuck';
};

done_testing();
