#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../lib";
use Mojo::JSON qw(encode_json);

use Purl::API::Controller::Settings::Redis;
use Purl::Config;

# ============================================
# Mock objects
# ============================================
{
    package MockLog;
    sub new { bless {}, $_[0] }
    sub error { }
    sub warn  { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockReq;
    sub new { bless { body => '{}' }, $_[0] }
    sub body { $_[0]->{body} }

    package MockResHeaders;
    sub new { bless { h => {} }, $_[0] }
    sub header { $_[0]->{h}{$_[1]} = $_[2] if @_ > 2; $_[0]->{h}{$_[1]} }

    package MockRes;
    sub new { bless { headers => MockResHeaders->new }, $_[0] }
    sub headers { $_[0]->{headers} }

    package MockCtrl;
    sub new {
        my ($class, %args) = @_;
        bless {
            req      => MockReq->new,
            res      => MockRes->new,
            rendered => undef,
            stash    => {},
            app      => MockApp->new,
            %args,
        }, $class;
    }
    sub req      { $_[0]->{req} }
    sub res      { $_[0]->{res} }
    sub app      { $_[0]->{app} }
    sub render {
        my ($self, %args) = @_;
        $self->{rendered} = \%args;
    }
    sub rendered { $_[0]->{rendered} }
    sub stash {
        my ($self, $key, $val) = @_;
        # The principal check_auth records for a signed-in user
        # (Purl::Util::Principal); require_role reads it, not the cookie.
        $self->{stash}{'purl.principal'} //= { via => 'session', username => 'admin', role => 'admin' };
        return $self->{stash} unless defined $key;
        $self->{stash}{$key} = $val if defined $val;
        return $self->{stash}{$key};
    }
    sub session {
        my ($self, $key) = @_;
        my $s = { role => 'admin' };
        return defined $key ? $s->{$key} : $s;
    }

    package MockStorage;
    sub new { bless {}, $_[0] }

    package MockSettings;
    sub new {
        my ($class, %args) = @_;
        bless {
            redis      => $args{redis}      // { url => '', mode => 'auto' },
            from_env   => $args{from_env}   // {},
            saved      => undef,
            save_fails => $args{save_fails} // 0,
        }, $class;
    }
    sub get_section {
        my ($self, $section) = @_;
        return $self->{redis} if $section eq 'redis';
        return {};
    }
    sub set_section {
        my ($self, $section, $data) = @_;
        return 0 if $self->{save_fails};
        $self->{saved} = { section => $section, data => $data };
        return 1;
    }
    sub is_from_env {
        my ($self, $section, $key) = @_;
        return $self->{from_env}{"$section.$key"} // 0;
    }
    sub get {
        my ($self, $section, $key) = @_;
        return $section eq 'redis' ? $self->{redis}{$key} : undef;
    }
    # Borrow the REAL decision procedure rather than reimplementing it here —
    # a mock that reimplements it can (and did, before #53) disagree with
    # production about which keys the environment owns.
    sub env_shadowed_keys { return Purl::Config::env_shadowed_keys(@_) }
    sub env_managed_keys  { return Purl::Config::env_managed_keys(@_) }
}

# ============================================
# get_redis — returns current config
# ============================================
subtest 'get_redis returns config and from_env flags' => sub {
    my $settings = MockSettings->new(
        redis    => { url => 'redis://localhost:6379', mode => 'redis' },
        from_env => {},
    );
    my $ctrl = Purl::API::Controller::Settings::Redis->new(settings => $settings, storage => MockStorage->new);
    my $c    = MockCtrl->new;

    $ctrl->get_redis($c);
    my $r = $c->rendered;

    ok $r, 'response rendered';
    is $r->{json}{config}{url},  'redis://localhost:6379', 'url returned';
    is $r->{json}{config}{mode}, 'redis',                  'mode returned';
    is $r->{json}{from_env}{url},  0, 'url not from env';
    is $r->{json}{from_env}{mode}, 0, 'mode not from env';
};

subtest 'get_redis marks env-locked fields' => sub {
    my $settings = MockSettings->new(
        redis    => { url => 'redis://env-host:6379', mode => 'redis' },
        from_env => { 'redis.url' => 1, 'redis.mode' => 1 },
    );
    my $ctrl = Purl::API::Controller::Settings::Redis->new(settings => $settings, storage => MockStorage->new);
    my $c    = MockCtrl->new;

    $ctrl->get_redis($c);
    my $r = $c->rendered;

    is $r->{json}{from_env}{url},  1, 'url from env';
    is $r->{json}{from_env}{mode}, 1, 'mode from env';
};

# ============================================
# update_redis — saves valid config
# ============================================
subtest 'update_redis saves broadcast_mode=local' => sub {
    my $settings = MockSettings->new;
    my $ctrl     = Purl::API::Controller::Settings::Redis->new(settings => $settings, storage => MockStorage->new);
    my $c        = MockCtrl->new;
    $c->req->{body} = encode_json({ mode => 'local' });

    $ctrl->update_redis($c);
    my $r = $c->rendered;

    ok $r, 'response rendered';
    is $r->{json}{status}, 'ok', 'status ok';
    is $settings->{saved}{data}{mode}, 'local', 'mode saved as local';
};

subtest 'update_redis saves redis_url' => sub {
    my $settings = MockSettings->new;
    my $ctrl     = Purl::API::Controller::Settings::Redis->new(settings => $settings, storage => MockStorage->new);
    my $c        = MockCtrl->new;
    $c->req->{body} = encode_json({ url => 'redis://myhost:6379', mode => 'redis' });

    $ctrl->update_redis($c);
    my $r = $c->rendered;

    is $r->{json}{status},             'ok',                   'status ok';
    is $settings->{saved}{data}{url},  'redis://myhost:6379',  'url saved';
    is $settings->{saved}{data}{mode}, 'redis',                'mode saved';
};

subtest 'update_redis rejects invalid mode' => sub {
    my $settings = MockSettings->new;
    my $ctrl     = Purl::API::Controller::Settings::Redis->new(settings => $settings, storage => MockStorage->new);
    my $c        = MockCtrl->new;
    $c->req->{body} = encode_json({ mode => 'invalid_mode' });

    $ctrl->update_redis($c);
    my $r = $c->rendered;

    is $r->{status}, 400, 'HTTP 400 for invalid mode';
    ok exists $r->{json}{error}, 'error message present';
};

subtest 'update_redis rejects invalid JSON' => sub {
    my $settings = MockSettings->new;
    my $ctrl     = Purl::API::Controller::Settings::Redis->new(settings => $settings, storage => MockStorage->new);
    my $c        = MockCtrl->new;
    $c->req->{body} = 'not-json';

    $ctrl->update_redis($c);
    my $r = $c->rendered;

    is $r->{status}, 400, 'HTTP 400 for bad JSON';
};

# ============================================
# REGRESSION (#53): an edit the environment owns must be REFUSED, not
# silently skipped and answered 'ok'.
#
# This subtest used to assert the opposite ("skips env-locked fields"): it
# accepted a 200 for a request that changed nothing, so the UI reported a save
# that never happened. PURL_REDIS_URL wins on every read, so the only honest
# answer is 409.
# ============================================
subtest 'update_redis refuses an env-owned url with 409' => sub {
    my $settings = MockSettings->new(
        redis    => { url => 'redis://env:6379', mode => 'redis' },
        from_env => { 'redis.url' => 1 },
    );
    my $ctrl = Purl::API::Controller::Settings::Redis->new(settings => $settings, storage => MockStorage->new);
    my $c    = MockCtrl->new;
    $c->req->{body} = encode_json({ url => 'redis://new:6379', mode => 'local' });

    $ctrl->update_redis($c);
    my $r = $c->rendered;

    is $r->{status}, 409, 'conflict — PURL_REDIS_URL owns this value';
    is_deeply $r->{json}{from_env}, ['url'], 'names the key that is not ours to change';
    is $settings->{saved}, undef, 'and nothing was written';
};

subtest 'update_redis still saves the keys the environment does NOT own' => sub {
    my $settings = MockSettings->new(
        redis    => { url => 'redis://env:6379', mode => 'redis' },
        from_env => { 'redis.url' => 1 },
    );
    my $ctrl = Purl::API::Controller::Settings::Redis->new(settings => $settings, storage => MockStorage->new);
    my $c    = MockCtrl->new;
    # No `url` in the body: nothing env-owned is being changed.
    $c->req->{body} = encode_json({ mode => 'local' });

    $ctrl->update_redis($c);
    my $r = $c->rendered;

    is $r->{json}{status}, 'ok', 'a request that touches no env-owned key succeeds';
    is $settings->{saved}{data}{mode}, 'local', 'mode updated';
};

subtest 'resubmitting the env value unchanged is not an error' => sub {
    my $settings = MockSettings->new(
        redis    => { url => 'redis://env:6379', mode => 'redis' },
        from_env => { 'redis.url' => 1 },
    );
    my $ctrl = Purl::API::Controller::Settings::Redis->new(settings => $settings, storage => MockStorage->new);
    my $c    = MockCtrl->new;
    # This is what "load the form, change one field, save" sends: the env-owned
    # field comes back with the value the GET handed out. Nothing changes, so
    # 200 is the truth — 409 here would make the settings page unsaveable.
    $c->req->{body} = encode_json({ url => 'redis://env:6379', mode => 'local' });

    $ctrl->update_redis($c);
    my $r = $c->rendered;

    is $r->{json}{status}, 'ok', 'no-op on the env key is accepted';
    is $settings->{saved}{data}{mode}, 'local', 'the real change went through';
};

subtest 'update_redis returns 500 on save failure' => sub {
    my $settings = MockSettings->new(save_fails => 1);
    my $ctrl     = Purl::API::Controller::Settings::Redis->new(settings => $settings, storage => MockStorage->new);
    my $c        = MockCtrl->new;
    $c->req->{body} = encode_json({ mode => 'local' });

    $ctrl->update_redis($c);
    my $r = $c->rendered;

    is $r->{status}, 500, 'HTTP 500 on save failure';
};

done_testing;
