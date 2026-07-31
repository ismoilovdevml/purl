package PurlTest::Mock;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
our @EXPORT_OK = qw(mock_ctx mock_storage mock_auth_ctx mock_server_storage);

# ============================================
# The Mojolicious controller stand-in the settings tests drive endpoints with.
#
# It lived inline in t/settings_env_shadow.t; a second file needing the same
# four-method mock is exactly the "same logic in two places" that drifts, so it
# lives here once and both files use it.
#
# Deliberately tiny: render() records instead of rendering, stash() returns
# undef so there is no license context and every feature is allowed, and
# session('role') is admin so require_role passes.
# ============================================

{
    package PurlTest::Mock::Ctx;

    sub new {
        my ($class, %args) = @_;
        return bless {
            body     => $args{body}   // '{}',
            params   => $args{params} // {},
            rendered => undef,
        }, $class;
    }

    sub req   { return $_[0] }
    sub body  { return $_[0]->{body} }
    sub app   { return $_[0] }
    sub log   { return $_[0] }
    sub error { return }
    sub warn  { return }
    sub param { return $_[0]->{params}{ $_[1] } }
    sub render   { my ($s, %a) = @_; $s->{rendered} = \%a; return }
    sub rendered { return $_[0]->{rendered} }
    sub stash    { return undef }
    sub session  {
        my ($s, $k) = @_;
        my %h = (role => 'admin');
        return defined $k ? $h{$k} : \%h;
    }

    package PurlTest::Mock::Storage;

    sub new { return bless {}, $_[0] }
    sub update_retention { return 1 }
}

# ============================================
# Controller stand-in for Purl::API::Middleware::Auth.
#
# check_auth() reaches for a different surface than the settings mock above:
# request headers, method, URL path, the session hash and stash(). Three test
# files already carry a near-identical inline copy of it; anything new goes
# through this one so the next behaviour change is a single edit.
# ============================================
{
    package PurlTest::Mock::Auth::Path;
    sub new       { return bless { p => $_[1] // '/' }, $_[0] }
    sub to_string { return $_[0]->{p} }

    package PurlTest::Mock::Auth::Url;
    sub new  { return bless { path => PurlTest::Mock::Auth::Path->new($_[1]) }, $_[0] }
    sub path { return $_[0]->{path} }

    package PurlTest::Mock::Auth::Headers;
    sub new           { return bless { h => $_[1] // {} }, $_[0] }
    sub header        { return $_[0]->{h}{ $_[1] } }
    sub authorization { return $_[0]->{h}{Authorization} }
    sub host          { return $_[0]->{h}{Host} }

    package PurlTest::Mock::Auth::Req;
    sub new {
        my ($class, %args) = @_;
        return bless {
            headers => PurlTest::Mock::Auth::Headers->new($args{headers}),
            method  => $args{method} // 'GET',
            url     => PurlTest::Mock::Auth::Url->new($args{path}),
        }, $class;
    }
    sub headers { return $_[0]->{headers} }
    sub method  { return $_[0]->{method} }
    sub url     { return $_[0]->{url} }

    package PurlTest::Mock::Auth::Tx;
    sub new            { return bless { addr => $_[1] // '127.0.0.1' }, $_[0] }
    sub remote_address { return $_[0]->{addr} }

    package PurlTest::Mock::Auth::Ctx;
    sub new {
        my ($class, %args) = @_;
        return bless {
            req     => PurlTest::Mock::Auth::Req->new(%args),
            session => $args{session} // {},
            stash   => {},
            tx      => PurlTest::Mock::Auth::Tx->new($args{remote_address}),
        }, $class;
    }
    sub req { return $_[0]->{req} }
    sub tx  { return $_[0]->{tx} }
    sub session {
        my ($self, $key) = @_;
        return $self->{session} unless defined $key;
        return $self->{session}{$key};
    }
    sub stash {
        my ($self, $key, $val) = @_;
        return $self->{stash} unless defined $key;
        $self->{stash}{$key} = $val if defined $val;
        return $self->{stash}{$key};
    }
}

# ============================================
# Whole-storage stand-in for the tests that boot the real Mojolicious app via
# Purl::API::Server (by overriding _build_storage). Seven test files grew their
# own near-identical `package Purl::Storage::InMemory` copy; anything new uses
# this one so the next storage-interface change is a single edit.
#
# It keeps inserted logs so a test can assert what ingest actually stored.
# ============================================
{
    package PurlTest::Mock::ServerStorage;

    sub new          { return bless { logs => [] }, $_[0] }
    sub logs         { return $_[0]->{logs} }
    sub insert       { push @{ $_[0]->{logs} }, $_[1]; return 1 }
    sub insert_batch { push @{ $_[0]->{logs} }, @{ $_[1] }; return 1 }
    sub flush        { return 1 }
    sub maybe_flush  { return }
    sub search       { return [] }
    sub count        { return 0 }
    sub stats        { return { total_logs => 0, db_size_bytes => 0, db_size_mb => 0 } }
    sub field_stats  { return [] }
    sub get_fields   { return [qw(level service host message timestamp)] }
    sub get_metrics  {
        return { queries_total => 0, inserts_total => 0, errors_total => 0, buffer_size => 0 };
    }
    sub _init_audit_schema { return 1 }
    sub log_audit_event    { return 1 }
}

sub mock_ctx      { return PurlTest::Mock::Ctx->new(@_) }
sub mock_storage  { return PurlTest::Mock::Storage->new }
sub mock_auth_ctx { return PurlTest::Mock::Auth::Ctx->new(@_) }
sub mock_server_storage { return PurlTest::Mock::ServerStorage->new }

1;
