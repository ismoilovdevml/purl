package Purl::Config::EnvOwnership;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use Purl::Config::EnvMap qw(env_var_for env_mapped_keys is_write_only is_blank same_scalar);
use namespace::clean;

# Who owns a key: is it set by the environment, which keys can the environment
# manage, which of a caller's edits would ENV shadow, and may a key be cleared.

requires qw(get);

# Public face of %WRITE_ONLY, for the endpoints that have to answer "may this
# key be erased on request?" (see clear_secrets). The list is lexical on
# purpose — one source of truth — so callers ask instead of keeping a copy.
sub is_clearable {
    my ($self, $section, $key) = @_;
    return is_write_only($section, $key);
}

# Public face of _is_blank. What counts as "the admin did not fill this in" is
# the whole basis of the write-only rule, so the endpoints that need the same
# question answered must not re-spell it.
sub value_is_blank {
    my ($self, $value) = @_;
    return is_blank($value);
}

# Check if value is from env (read-only)
sub is_from_env {
    my ($self, $section, $key) = @_;

    my $full_key = "$section.$key";
    if (my $env = env_var_for($full_key)) {
        return exists $ENV{$env} && defined $ENV{$env} && $ENV{$env} ne '';
    }

    return 0;
}

# Every key of $section that %ENV_MAP can manage, whether or not the variable
# is currently set.
#
# The read side had the same twin-site defect as the write side: get_ldap
# reported from_env for three of its fourteen mappable keys, get_sso for eight
# of fifteen, so the UI happily left a field editable that the environment
# owned. Building those responses from this list instead of a hand-kept qw()
# means a new entry in %ENV_MAP shows up in the UI the day it is added.
sub env_managed_keys {
    my ($self, $section) = @_;

    my $prefix = "$section.";
    # Sorted into a list first: `return sort ...` is undefined in scalar
    # context, so a caller writing `my $n = env_managed_keys(...)` would get
    # something arbitrary rather than a count or an error.
    my @keys = sort map { substr($_, length $prefix) }
               grep { index($_, $prefix) == 0 } env_mapped_keys();
    return @keys;
}

# Which of a caller's proposed changes does the environment own?
#
# ENV wins on every read, so a key with a live ENV value cannot be changed
# through the API: set_section strips it before writing, and set() writes a
# value that get() will never return. Either way the edit does nothing — and
# answering such a request with 200 is the bug this exists to stop. It has now
# been shipped five times over (backups, alert filters, auth middleware, the
# CronJob, and the API-key pair), every time because a fix was applied to the
# endpoint in the report and not to its siblings.
#
# So the decision is made HERE, from %ENV_MAP, for any section and any key. A
# new ENV-managed key is covered by every caller the moment it is added to the
# map; there is no per-endpoint list to forget.
#
# A submitted value EQUAL to the effective one is not a change and is not
# reported: a UI that GETs a config and PUTs the whole form back must keep
# working, and reporting success for a no-op is honest.
#
# $changes is the caller's proposed values keyed by config key (nested keys use
# the dotted form %ENV_MAP uses, e.g. 'telegram.bot_token'). Returns the
# blocked keys, sorted.
sub env_shadowed_keys {
    my ($self, $section, $changes) = @_;
    return () unless ref $changes eq 'HASH';

    my @shadowed;
    for my $key (sort keys %$changes) {
        next unless $self->is_from_env($section, $key);

        # A key the API never discloses comes back EMPTY from a UI that was only
        # told whether it is set (see %WRITE_ONLY). That is "I did not retype
        # it", so it is not an attempted edit — refusing it made every save of
        # such a panel a 409 the admin could not clear, because the field they
        # would have had to correct was never populated in the first place.
        next if is_write_only($section, $key) && is_blank($changes->{$key});

        next if same_scalar($self->get($section, $key), $changes->{$key});
        push @shadowed, $key;
    }

    return @shadowed;
}

1;

__END__

=head1 NAME

Purl::Config::EnvOwnership - ENV-ownership queries for Purl::Config
(is_from_env, env_managed_keys, env_shadowed_keys, is_clearable, value_is_blank).

=cut
