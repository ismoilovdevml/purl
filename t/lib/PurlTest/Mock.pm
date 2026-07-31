package PurlTest::Mock;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
our @EXPORT_OK = qw(mock_ctx mock_storage);

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

sub mock_ctx     { return PurlTest::Mock::Ctx->new(@_) }
sub mock_storage { return PurlTest::Mock::Storage->new }

1;
