package Purl::Config::Writable;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use Purl::Config::EnvMap qw(env_var_for env_mapped_keys is_write_only manages_below is_blank);
use namespace::clean;

# What may reach settings.json: the filter every section write goes through,
# explicit erasure of write-only secrets, and the one-time prune of values the
# environment already supplies.

requires qw(_config _with_lock save is_from_env config_file);

# What a section may actually put on disk.
#
# Two values in a caller's hash are not theirs to write, and both resolve the
# same way: the FILE keeps whatever it already held.
#
# 1. ENV-PROVIDED VALUES. get_section() resolves ENV over file, so the hash a
#    caller just edited also carries whatever the environment supplied —
#    including secrets. Writing it back does two bad things:
#
#      a. it copies the Kubernetes Secret onto the config PVC in plaintext
#         (PURL_CLICKHOUSE_PASSWORD, PURL_API_KEYS, PURL_LDAP_BIND_PASSWORD,
#         PURL_AI_API_KEY), and that PVC is annotated resource-policy: keep;
#      b. it freezes the env value into the file where ENV still wins on READ,
#         so an edit to that key looks saved and has no effect. That is how
#         revoking an API key could report success while the key kept
#         authenticating.
#
#    Keeping the file's value (rather than dropping the key) is the half that
#    matters the day the variable is removed: ENV is what is IN EFFECT, the
#    file is what the instance falls back to. Deleting it turns "unset
#    PURL_TELEGRAM_CHAT_ID" into alerts that silently stop.
#
# 2. BLANK VALUES FOR KEYS THE API NEVER DISCLOSES (%WRITE_ONLY). Their GET
#    reports a 0/1 "is it set" flag, so the input renders empty on every load
#    and comes back empty unless the admin retyped it. Empty means "I did not
#    retype it" — writing it would delete a secret nobody asked to delete.
#
# Nested sections (notifications.telegram.*) are walked with the same rules:
# their keys are addressed by the dotted name %ENV_MAP uses, and the file's
# copy of the same subtree is what they fall back to. Doing that walk by hand
# in a controller is what dropped a file-held chat_id on the first save.
sub _writable_values {
    my ($self, $section, $data, $prefix, $file_node) = @_;
    return $data unless ref $data eq 'HASH';

    $prefix //= '';
    $file_node = $self->_config->{$section} if @_ < 5;

    my %clean = %$data;

    for my $key (keys %clean) {
        my $path      = "$prefix$key";
        my $file_has  = ref $file_node eq 'HASH' && exists $file_node->{$key};
        my $file_value = $file_has ? $file_node->{$key} : undef;

        if (ref $clean{$key} eq 'HASH' && manages_below($section, $path)) {
            $clean{$key} = $self->_writable_values(
                $section, $clean{$key}, "$path.", $file_value);
            next;
        }

        next unless $self->is_from_env($section, $path)
                 || (is_write_only($section, $path) && is_blank($clean{$key}));

        if ($file_has) {
            $clean{$key} = $file_value;
        }
        else {
            delete $clean{$key};
        }
    }

    # OMITTING a key is not an instruction to delete it either, when the key is
    # not the caller's to write. The notification form posts only the fields it
    # has, so a chat_id the environment owns never appears in the body at all —
    # and a whole-section write would drop it from the file on the way past.
    if (ref $file_node eq 'HASH') {
        for my $key (keys %$file_node) {
            next if exists $clean{$key};
            my $path = "$prefix$key";
            next unless $self->is_from_env($section, $path)
                     || is_write_only($section, $path);
            $clean{$key} = $file_node->{$key};
        }
    }

    return \%clean;
}

# ============================================
# Erasing and de-duplicating stored values
# ============================================

# Locate the FILE's own copy of "section" + a possibly dotted key: the hash
# that holds the leaf, plus the leaf name. Returns the empty list when the file
# does not carry it — which is the common case and must never autovivify, or a
# lookup would create the very key it was asking about.
#
# Both the eraser and the de-duplicator below walk the same dotted names
# %ENV_MAP uses, so they walk them through one function.
sub _file_slot {
    my ($self, $section, $key) = @_;

    my $node = $self->_config->{$section};
    my @path = split /\./, $key;
    my $leaf = pop @path;

    for my $step (@path) {
        return () unless ref $node eq 'HASH' && exists $node->{$step};
        $node = $node->{$step};
    }
    return () unless ref $node eq 'HASH' && exists $node->{$leaf};

    return ($node, $leaf);
}

# Delete stored %WRITE_ONLY secrets, on an EXPLICIT request (#62).
#
# A blank submission cannot mean this. Those keys are never disclosed — their
# GET reports a 0/1 "is it set" flag — so the input is empty on every page load
# and empty has to mean "I did not retype it", or an unrelated save would wipe
# a token nobody touched (#56). That left no way to say "delete it", and
# offboarding needs one: turning a channel off (enabled => 0) leaves the token
# on the config PVC, which is annotated resource-policy: keep and outlives even
# `helm uninstall`.
#
# So deletion gets its own word — a `clear_<field>` flag on the request, mapped
# here to the dotted key. Never a sentinel value: every string an admin could
# type is a string some secret could legitimately be.
#
# Two refusals, both silent (the endpoint has already answered for them):
#
#   * keys that are not write-only. The MASKED secrets (ldap.bind_password,
#     saml.sp_key, ai.api_key) come back as '********', so their UI can already
#     distinguish "unchanged" from "clear it" and empty must keep clearing
#     them. Giving them a second spelling would be two ways to say one thing.
#   * keys the environment owns. The value in effect comes from ENV on every
#     read, so removing the file's copy would delete the fallback and change
#     nothing that is actually in force.
#
# Callers run this BEFORE their ordinary save. That ordering is what makes the
# result stick without touching the write path: with the file's copy already
# gone, _writable_values sees no value to restore for the blank field and drops
# it, instead of putting the secret back.
#
# Returns the keys actually removed (empty when there was nothing to remove —
# clearing twice is a no-op, not an error), or undef if the save failed.
sub clear_secrets {
    my ($self, $section, @keys) = @_;

    my @targets = grep { is_write_only($section, $_) && !$self->is_from_env($section, $_) }
                  @keys;
    return [] unless @targets;

    my @cleared;
    my $ok = $self->_with_lock(sub {
        for my $key (@targets) {
            my ($node, $leaf) = $self->_file_slot($section, $key) or next;
            delete $node->{$leaf};
            push @cleared, $key;
        }
        return 1 unless @cleared;
        return $self->save();
    });

    return $ok ? \@cleared : undef;
}

# Which file values are a verbatim copy of what the environment supplies right
# now. Scanned twice — once cheaply outside the lock, once for real inside it —
# so the scan is one function.
sub _env_duplicate_keys {
    my ($self) = @_;

    my @dupes;
    for my $full_key (sort { $a cmp $b } env_mapped_keys()) {
        my ($section, $key) = split /\./, $full_key, 2;
        next unless $self->is_from_env($section, $key);

        my ($node, $leaf) = $self->_file_slot($section, $key) or next;
        my $stored = $node->{$leaf};

        # A structure can never equal an ENV string, and anything that merely
        # LOOKS equal ('true' vs 1) is not what the old write path produced —
        # it copied the environment's own string. Exact match keeps this
        # narrow, which is the point.
        next unless defined $stored && !ref $stored;
        next unless "$stored" eq $ENV{ env_var_for($full_key) };

        push @dupes, $full_key;
    }

    return \@dupes;
}

# One-time cleanup of the ENV values older builds baked into settings.json (#52).
#
# Until #45/#59 a section write persisted the MERGED section, so any edit
# copied the environment's values for the other keys onto disk. That path is
# closed; what it already wrote is not. The damage is ongoing:
#
#   a. the Kubernetes Secret sits in plaintext on the config PVC, and that PVC
#      is annotated resource-policy: keep — `helm uninstall` leaves it behind;
#   b. ENV wins on read, so an edit to such a key reports success and does
#      nothing, and the stale copy silently takes over the day the variable is
#      removed.
#
# Deliberately narrow: a file value is removed ONLY when it is byte-identical
# to what the environment supplies. A DIFFERENT value is the operator's own
# fallback — the one that applies once the variable comes off — and deleting it
# is how "unset PURL_TELEGRAM_CHAT_ID" becomes alerts that stop without a word.
# That fallback is exactly what _writable_values exists to protect.
#
# Idempotent: the second run finds nothing and does not rewrite the file. The
# log names the KEYS and never the values — writing a secret to stdout to
# announce that it was removed from disk would defeat the whole exercise.
sub prune_env_duplicates {
    my ($self) = @_;

    # Cheap pre-check outside the lock. On every startup after the first there
    # is nothing to do, and taking the lock creates the sidecar file for a
    # guaranteed no-op.
    return [] unless @{ $self->_env_duplicate_keys };

    my @removed;
    my $ok = $self->_with_lock(sub {
        # Re-scan under the lock: the file we are about to edit is whatever
        # _with_lock just reloaded, not the copy the pre-check saw.
        for my $full_key (@{ $self->_env_duplicate_keys }) {
            my ($section, $key) = split /\./, $full_key, 2;
            my ($node, $leaf) = $self->_file_slot($section, $key) or next;
            delete $node->{$leaf};
            push @removed, $full_key;
        }
        return 1 unless @removed;
        return $self->save();
    });

    if (@removed) {
        warn sprintf(
            "Purl::Config: removed %d environment-duplicated value(s) from %s: %s\n",
            scalar @removed, $self->config_file, join(', ', @removed));
    }

    return $ok ? \@removed : undef;
}

1;

__END__

=head1 NAME

Purl::Config::Writable - the rules for what Purl::Config writes to or erases
from settings.json (ENV-owned and write-only keys).

=cut
