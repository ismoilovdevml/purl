package Purl::API::Middleware::LDAP;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;

# ============================================
# Attributes
# ============================================

has 'config' => (
    is      => 'ro',
    default => sub { {} },
);

has '_ldap' => (
    is      => 'rw',
    default => sub { undef },
);

# ============================================
# Public Methods
# ============================================

sub authenticate {
    my ($self, $username, $password) = @_;

    return { success => 0, error => 'Username is required' }
        unless defined $username && length $username;
    return { success => 0, error => 'Password is required' }
        unless defined $password && length $password;

    my $ldap = eval { $self->_build_connection() };
    if ($@) {
        warn "LDAP: connection error during authenticate: $@\n";
        return { success => 0, error => 'LDAP unavailable', unavailable => 1 };
    }
    unless ($ldap) {
        return { success => 0, error => 'LDAP unavailable', unavailable => 1 };
    }

    my $cfg         = $self->config;
    my $bind_dn     = $cfg->{bind_dn}       // '';
    my $bind_pass   = $cfg->{bind_password} // '';

    # Service-account bind
    my $bind_result = eval { $ldap->bind($bind_dn, password => $bind_pass) };
    if ($@ || !$bind_result) {
        warn "LDAP: service account bind failed (dn=$bind_dn): $@\n" if $@;
        eval { $ldap->unbind() };
        return { success => 0, error => 'LDAP service account bind failed', unavailable => 1 };
    }
    if ($bind_result->is_error()) {
        my $msg = $bind_result->error();
        warn "LDAP: service account bind error (dn=$bind_dn): $msg\n";
        eval { $ldap->unbind() };
        return { success => 0, error => 'LDAP service account bind failed', unavailable => 1 };
    }

    # Search for the user
    my $user_info = eval { $self->_search_user($ldap, $username) };
    if ($@) {
        warn "LDAP: user search error (username=$username): $@\n";
        eval { $ldap->unbind() };
        return { success => 0, error => 'LDAP search failed', unavailable => 1 };
    }
    unless ($user_info) {
        eval { $ldap->unbind() };
        return { success => 0, error => 'Invalid credentials' };
    }

    my $user_dn = $user_info->{dn};
    my $mail    = $user_info->{mail} // '';

    # User bind — verifies the password
    my $user_bind = eval { $ldap->bind($user_dn, password => $password) };
    if ($@ || !$user_bind) {
        warn "LDAP: user bind error (dn=$user_dn): $@\n" if $@;
        eval { $ldap->unbind() };
        return { success => 0, error => 'Invalid credentials' };
    }
    if ($user_bind->is_error()) {
        my $code = $user_bind->code();
        warn "LDAP: user bind failed (dn=$user_dn, code=$code)\n";
        eval { $ldap->unbind() };
        return { success => 0, error => 'Invalid credentials' };
    }

    # Collect group memberships
    my $groups = eval { $self->_get_groups($ldap, $user_dn) };
    if ($@) {
        warn "LDAP: group lookup error (dn=$user_dn): $@\n";
        $groups = [];
    }

    eval { $ldap->unbind() };

    return {
        success => 1,
        dn      => $user_dn,
        mail    => $mail,
        groups  => $groups,
    };
}

# ============================================
# Private Methods
# ============================================

sub _build_connection {
    my ($self, %override) = @_;

    my $cfg     = $self->config;
    my $server  = $override{server}     // $cfg->{server}      // 'localhost';
    my $port    = $override{port}       // $cfg->{port}        // 389;
    my $timeout = $override{timeout}    // $cfg->{timeout}     // 10;
    my $tls_en  = $override{tls_enabled}// $cfg->{tls_enabled} // 0;
    my $verify  = $cfg->{tls_verify}    // 'none';

    my $ldap;

    eval { require Net::LDAP };
    if ($@) {
        warn "LDAP: Net::LDAP is not installed: $@\n";
        return undef;
    }

    if ($server =~ m{^ldaps://}i) {
        # LDAP over SSL — strip scheme, use port 636
        (my $clean_server = $server) =~ s{^ldaps://}{}i;
        $ldap = eval {
            Net::LDAP->new(
                $clean_server,
                port    => ($port == 389 ? 636 : $port),
                timeout => $timeout,
                verify  => $verify,
                onerror => 'return',
            );
        };
        if ($@ || !$ldap) {
            warn "LDAP: ldaps:// connection failed (server=$clean_server): $@\n" if $@;
            return undef;
        }
    }
    else {
        # Plain LDAP — optionally upgrade with StartTLS
        (my $clean_server = $server) =~ s{^ldap://}{}i;
        $ldap = eval {
            Net::LDAP->new(
                $clean_server,
                port    => $port,
                timeout => $timeout,
                onerror => 'return',
            );
        };
        if ($@ || !$ldap) {
            warn "LDAP: connection failed (server=$clean_server, port=$port): $@\n" if $@;
            return undef;
        }

        if ($tls_en) {
            my $tls_result = eval { $ldap->start_tls(verify => $verify) };
            if ($@ || !$tls_result) {
                warn "LDAP: StartTLS failed (server=$clean_server): $@\n" if $@;
                eval { $ldap->disconnect() };
                return undef;
            }
            if ($tls_result->is_error()) {
                my $msg = $tls_result->error();
                warn "LDAP: StartTLS error (server=$clean_server): $msg\n";
                eval { $ldap->disconnect() };
                return undef;
            }
        }
    }

    return $ldap;
}

sub _search_user {
    my ($self, $ldap, $username) = @_;

    my $cfg         = $self->config;
    my $base        = $cfg->{search_base}   // '';
    my $user_attr   = $cfg->{user_attr}     // 'uid';
    my $mail_attr   = $cfg->{mail_attr}     // 'mail';
    my $raw_filter  = $cfg->{search_filter} // '({user_attr}={username})';

    my $escaped = $self->_escape_filter($username);

    # Substitute placeholders
    (my $filter = $raw_filter) =~ s/\{username\}/$escaped/g;
    $filter =~ s/\{user_attr\}/$user_attr/g;

    my $result = eval {
        $ldap->search(
            base   => $base,
            filter => $filter,
            attrs  => [$user_attr, $mail_attr],
            scope  => 'sub',
        );
    };
    if ($@ || !$result) {
        warn "LDAP: search error (filter=$filter): $@\n" if $@;
        return undef;
    }
    if ($result->is_error()) {
        warn "LDAP: search failed (filter=$filter): " . $result->error() . "\n";
        return undef;
    }

    my @entries = $result->entries();
    return undef unless @entries;

    my $entry = $entries[0];
    my $dn    = $entry->dn();
    my $mail  = $entry->get_value($mail_attr) // '';

    return { dn => $dn, mail => $mail };
}

sub _get_groups {
    my ($self, $ldap, $user_dn) = @_;

    my $cfg        = $self->config;
    my $group_attr = $cfg->{group_attr}  // 'memberOf';
    my $mode       = $cfg->{mode}        // 'openldap';
    my $base       = $cfg->{search_base} // '';

    my @groups;

    if (lc($mode) eq 'ad') {
        # Active Directory: read memberOf attribute directly from the user entry
        my $escaped_dn = $self->_escape_filter($user_dn);
        my $result = eval {
            $ldap->search(
                base   => $user_dn,
                filter => '(objectClass=*)',
                scope  => 'base',
                attrs  => [$group_attr],
            );
        };
        if ($@ || !$result || $result->is_error()) {
            warn "LDAP: AD group lookup error (dn=$user_dn): $@\n" if $@;
            return [];
        }

        my @entries = $result->entries();
        return [] unless @entries;

        my @raw_dns = $entries[0]->get_value($group_attr);
        for my $group_dn (@raw_dns) {
            # Extract CN from DN: CN=GroupName,OU=...
            if ($group_dn =~ /^[Cc][Nn]=([^,]+)/x) {
                push @groups, $1;
            }
            else {
                push @groups, $group_dn;
            }
        }
    }
    else {
        # OpenLDAP / generic: search for groups that list the user as a member
        my $escaped_dn = $self->_escape_filter($user_dn);
        my $filter     = "(|($group_attr=$escaped_dn)(uniqueMember=$escaped_dn))";

        my $result = eval {
            $ldap->search(
                base   => $base,
                filter => $filter,
                scope  => 'sub',
                attrs  => ['cn'],
            );
        };
        if ($@ || !$result || $result->is_error()) {
            warn "LDAP: OpenLDAP group search error (dn=$user_dn): $@\n" if $@;
            return [];
        }

        for my $entry ($result->entries()) {
            my $cn = $entry->get_value('cn') // '';
            push @groups, $cn if length $cn;
        }
    }

    return \@groups;
}

# Public alias used in tests and by callers who need to escape values
sub escape_filter { my ($self, $v) = @_; return $self->_escape_filter($v) }

sub _escape_filter {
    my ($self, $value) = @_;

    return '' unless defined $value;

    # Prefer the canonical Net::LDAP::Util implementation when available
    my $util_ok = eval { require Net::LDAP::Util; 1 };
    if ($util_ok && Net::LDAP::Util->can('escape_filter_value')) {
        return Net::LDAP::Util::escape_filter_value($value);
    }

    # Manual fallback — order matters: backslash must be escaped first
    $value =~ s/\\/\\5c/g;
    $value =~ s/\*/\\2a/g;
    $value =~ s/\(/\\28/g;
    $value =~ s/\)/\\29/g;
    $value =~ s/\x00/\\00/g;
    $value =~ s/\//\\2f/g;

    return $value;
}

sub is_available {
    my ($self) = @_;

    my $available = 0;
    eval {
        local $SIG{ALRM} = sub { die "LDAP availability check timed out\n" };
        alarm(2);
        my $ldap = $self->_build_connection(timeout => 2);
        if ($ldap) {
            eval { $ldap->unbind() };
            $available = 1;
        }
        alarm(0);
    };
    alarm(0);    # ensure alarm is cleared even if eval dies

    if ($@) {
        warn "LDAP: is_available check failed: $@\n" unless $@ =~ /timed out/;
    }

    return $available;
}

1;

__END__

=head1 NAME

Purl::API::Middleware::LDAP - LDAP/Active Directory authentication middleware for Purl

=head1 SYNOPSIS

    use Purl::API::Middleware::LDAP;

    my $ldap = Purl::API::Middleware::LDAP->new(
        config => {
            server        => 'ldap://ldap.example.com',
            port          => 389,
            bind_dn       => 'cn=svc-purl,ou=services,dc=example,dc=com',
            bind_password => 's3cr3t',
            search_base   => 'ou=people,dc=example,dc=com',
            search_filter => '({user_attr}={username})',
            user_attr     => 'uid',
            mail_attr     => 'mail',
            group_attr    => 'memberOf',
            tls_enabled   => 0,
            tls_verify    => 'none',
            timeout       => 10,
            mode          => 'openldap',  # or 'ad'
        },
    );

    # Check if the LDAP server is reachable before attempting login
    if ($ldap->is_available()) {
        my $result = $ldap->authenticate('alice', 'p@ssw0rd');
        if ($result->{success}) {
            printf "Authenticated as %s (mail: %s, groups: %s)\n",
                $result->{dn},
                $result->{mail},
                join(', ', @{ $result->{groups} });
        }
        else {
            printf "Auth failed: %s\n", $result->{error};
        }
    }

=head1 DESCRIPTION

C<Purl::API::Middleware::LDAP> provides LDAP and Active Directory user authentication
for the Purl log aggregation platform.  It implements a two-step bind flow:

=over 4

=item 1. A privileged I<service account> bind is used to locate the user entry via
a configurable search filter.

=item 2. The resolved DN is then bound with the user-supplied password to verify
credentials.  This avoids storing or comparing passwords inside the application.

=back

Both OpenLDAP (posixAccount / groupOfNames) and Microsoft Active Directory
(sAMAccountName / memberOf) schemas are supported via the C<mode> config key.

All LDAP operations are wrapped in C<eval {}> blocks — this module will never
C<die()> or propagate exceptions to the caller.  All user-supplied values are
sanitised with L</_escape_filter> before being interpolated into LDAP filters.

=head1 ATTRIBUTES

=head2 config

A hash-reference of LDAP configuration keys.  Recognised keys:

=over 4

=item C<server> - LDAP server URI or hostname.  Use C<ldaps://host> for SSL or
C<ldap://host> / plain hostname for plain/StartTLS.  Default: C<localhost>.

=item C<port> - TCP port.  Default: 389 (636 when scheme is C<ldaps://>).

=item C<bind_dn> - Distinguished name of the service account used for the
initial search bind.

=item C<bind_password> - Password for the service account.

=item C<search_base> - LDAP subtree to search for users.

=item C<search_filter> - LDAP search filter template.  The placeholders
C<{username}> and C<{user_attr}> are replaced at runtime.
Default: C<({user_attr}={username})>.

=item C<user_attr> - Attribute that holds the login name.  Default: C<uid>.
Use C<sAMAccountName> for Active Directory.

=item C<mail_attr> - Attribute for the user's e-mail address.  Default: C<mail>.

=item C<group_attr> - Attribute used for group membership.  Default: C<memberOf>.

=item C<tls_enabled> - Set to a true value to upgrade a plain LDAP connection
with StartTLS.  Ignored when the scheme is C<ldaps://>.  Default: 0.

=item C<tls_verify> - Peer certificate verification mode passed to
C<Net::LDAP>: C<none>, C<optional>, or C<require>.  Default: C<none>.

=item C<timeout> - Socket / operation timeout in seconds.  Default: 10.

=item C<mode> - Schema mode.  C<ad> enables Active Directory-specific group
resolution (reads C<memberOf> directly from the user object).  Any other value
activates the generic OpenLDAP path (searches the directory for groups that
list the user's DN).  Default: C<openldap>.

=back

=head2 _ldap

Internal cached C<Net::LDAP> connection handle (C<rw>, default C<undef>).
Not intended for direct use outside this module.

=head1 METHODS

=head2 authenticate( $username, $password )

Authenticates a user against the LDAP directory.

Returns a hash-reference with one of the following shapes:

    # Success
    { success => 1, dn => $dn, mail => $mail, groups => \@group_cns }

    # Authentication failure (wrong password, user not found)
    { success => 0, error => 'Invalid credentials' }

    # Infrastructure failure (server unreachable, service-account problem)
    { success => 0, error => 'LDAP unavailable', unavailable => 1 }

The method guarantees a clean C<unbind()> in all code paths and never
propagates exceptions.

=head2 is_available()

Returns C<1> if the configured LDAP server can be connected to within a
two-second wall-clock timeout, C<0> otherwise.  Always safe to call — never
dies.

Typical use: quick health-check before presenting a login form or before
falling back to local authentication.

=head2 _build_connection( [%override] )

B<(Private)> Establishes a C<Net::LDAP> connection according to C<< $self->config >>.
Optional C<%override> keys (C<server>, C<port>, C<timeout>, C<tls_enabled>)
allow callers such as L</is_available> to supply a shorter timeout without
mutating the object's config.

Returns a connected C<Net::LDAP> object on success, C<undef> on failure.

=head2 _search_user( $ldap, $username )

B<(Private)> Searches the directory for a user whose login attribute matches
C<$username>.  The C<search_filter> template is rendered after escaping
C<$username> with L</_escape_filter>.

Returns C<< { dn => $dn, mail => $mail } >> on success, C<undef> when no
matching entry is found.

=head2 _get_groups( $ldap, $user_dn )

B<(Private)> Resolves the group memberships of the user identified by C<$user_dn>.

In C<ad> mode the C<memberOf> attribute is read directly from the user object
and each value is parsed to extract its CN component.

In C<openldap> mode the directory is searched for group objects whose
C<member> or C<uniqueMember> attribute equals C<$user_dn>.

Returns an array-reference of group CN strings (may be empty).

=head2 _escape_filter( $value )

B<(Private)> Sanitises a string for safe interpolation into an LDAP search
filter (RFC 4515).

Delegates to C<Net::LDAP::Util::escape_filter_value()> when available;
falls back to manual substitution of the five RFC-mandated metacharacters
(C<\>, C<*>, C<(>, C<)>, NUL) plus the solidus C</>.

=head1 SECURITY NOTES

=over 4

=item * All user-supplied values are passed through L</_escape_filter> before
appearing in any LDAP filter.

=item * Passwords are never logged.  Only DNs, error codes, and filter strings
appear in C<warn> output.

=item * Every C<Net::LDAP> call is wrapped in C<eval {}>.  LDAP protocol
errors, network timeouts, and unexpected exceptions are caught and converted
to structured error hashrefs.

=item * C<$ldap-E<gt>unbind()> is called in every code path — successful,
error, and exception — to avoid leaking connections.

=item * This module never calls C<die()> or C<croak()>.

=back

=head1 DEPENDENCIES

L<Net::LDAP> (C<perl-ldap> distribution) must be installed.  If it is absent
the module logs a warning and L</authenticate> returns an C<unavailable> error.

L<Net::LDAP::Util> is used opportunistically for L</_escape_filter> and is
not a hard requirement.

=head1 SEE ALSO

L<Purl::API::Middleware::Auth>, L<Net::LDAP>, L<Net::LDAP::Util>

=head1 AUTHOR

Purl Project

=cut
