package Purl::API::Middleware::SAML;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;

has 'config' => (
    is      => 'ro',
    default => sub { {} },
);

has '_sp' => (
    is      => 'rw',
    default => sub { undef },
);

# Build a Net::SAML2 SP object from config (lazy)
sub _build_sp_object {
    my ($self) = @_;

    my $sp = eval {
        require Net::SAML2::IdP;
        require Net::SAML2::SP;

        my $cfg = $self->config;

        my $sp = Net::SAML2::SP->new(
            id               => $cfg->{entity_id}  // 'purl-sp',
            url              => $cfg->{acs_url}     // '',
            cert             => $cfg->{sp_cert}     || undef,
            key              => $cfg->{sp_key}      || undef,
            cacert           => $cfg->{idp_cert}    || undef,
            org_name         => 'Purl',
            org_display_name => 'Purl Log Aggregation',
            org_contact      => 'admin@purl.local',
            single_logout_service => [
                {
                    Binding  => 'urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect',
                    Location => ($cfg->{acs_url} // '') . '/slo',
                },
            ],
        );
        $sp;
    };

    if ($@) {
        warn "SAML: Failed to build SP object: $@\n";
        return undef;
    }

    $self->_sp($sp);
    return $sp;
}

# Build an AuthnRequest redirect URL to the IdP
# Returns: { success => 1, redirect_url => $url } or { success => 0, error => $msg }
sub build_authn_request {
    my ($self, $relay_state) = @_;

    my $sp = $self->_sp // $self->_build_sp_object();
    return { success => 0, error => 'SAML SP not available', unavailable => 1 }
        unless $sp;

    my $cfg = $self->config;
    my $idp_sso_url = $cfg->{idp_sso_url} // '';
    return { success => 0, error => 'IdP SSO URL not configured' }
        unless $idp_sso_url;

    my $redirect_url = eval {
        require Net::SAML2::Binding::Redirect;

        # Map name_id_format to URN
        my $format = $cfg->{name_id_format} // 'emailAddress';
        my %format_map = (
            'emailAddress' => 'urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress',
            'unspecified'  => 'urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified',
            'persistent'   => 'urn:oasis:names:tc:SAML:2.0:nameid-format:persistent',
            'transient'    => 'urn:oasis:names:tc:SAML:2.0:nameid-format:transient',
        );
        my $format_urn = $format_map{$format} // $format_map{'emailAddress'};

        my $authn_request = $sp->authn_request(
            $idp_sso_url,
            $format_urn,
        );

        # Use HTTP-Redirect binding
        my $redirect = Net::SAML2::Binding::Redirect->new(
            key => $cfg->{sp_key}  || undef,
            cert => $cfg->{sp_cert} || undef,
            url  => $idp_sso_url,
            param => 'SAMLRequest',
        );

        my $url = $redirect->sign($authn_request->as_xml, $relay_state // '');
        $url;
    };

    if ($@ || !$redirect_url) {
        my $err = $@ || 'Unknown error building AuthnRequest';
        warn "SAML: build_authn_request failed: $err\n";
        return { success => 0, error => "Failed to build AuthnRequest: $err" };
    }

    return { success => 1, redirect_url => $redirect_url };
}

# Validate a SAML Response received at the ACS endpoint
# Returns: { success => 1, username => $u, email => $e, groups => \@g }
#      or: { success => 0, error => $msg }
sub validate_response {
    my ($self, $saml_response_b64, $relay_state) = @_;

    return { success => 0, error => 'Empty SAML response' }
        unless defined $saml_response_b64 && length $saml_response_b64;

    my $sp = $self->_sp // $self->_build_sp_object();
    return { success => 0, error => 'SAML SP not available', unavailable => 1 }
        unless $sp;

    my $cfg = $self->config;

    # Require IdP certificate for signature verification
    my $idp_cert = $cfg->{idp_cert} // '';
    unless ($idp_cert && length($idp_cert) > 10) {
        return { success => 0, error => 'IdP certificate not configured — cannot verify signature' };
    }

    my $result = eval {
        require Net::SAML2::Binding::POST;
        require Net::SAML2::Protocol::Assertion;

        # Parse and verify the SAML Response via POST binding
        my $post = Net::SAML2::Binding::POST->new(
            cacert => $idp_cert,
        );

        my $response = $post->handle_response($saml_response_b64);
        die "SAML response signature verification failed\n" unless $response;

        # Parse the assertion
        my $assertion = Net::SAML2::Protocol::Assertion->new_from_xml(
            xml => $response,
        );
        die "Failed to parse SAML assertion\n" unless $assertion;

        # Verify audience restriction
        my $entity_id = $cfg->{entity_id} // '';
        if ($entity_id && $assertion->audience) {
            my $valid_audience = 0;
            my @audiences = ref $assertion->audience eq 'ARRAY'
                ? @{$assertion->audience}
                : ($assertion->audience);
            for my $aud (@audiences) {
                if ($aud eq $entity_id) {
                    $valid_audience = 1;
                    last;
                }
            }
            die "Audience restriction check failed\n" unless $valid_audience;
        }

        # Verify issuer
        my $idp_entity_id = $cfg->{idp_entity_id} // '';
        if ($idp_entity_id && $assertion->issuer) {
            die "Issuer mismatch: expected '$idp_entity_id', got '" . $assertion->issuer . "'\n"
                unless $assertion->issuer eq $idp_entity_id;
        }

        # Check conditions (NotBefore/NotOnOrAfter)
        if ($assertion->has_expired) {
            die "SAML assertion has expired\n";
        }
        if ($assertion->not_before && !$assertion->valid) {
            die "SAML assertion is not yet valid\n";
        }

        # Extract username
        my $username_attr = $cfg->{username_attr} // 'email';
        my $attrs = $assertion->attributes // {};

        my $username = $attrs->{$username_attr};
        $username = $username->[0] if ref $username eq 'ARRAY';
        $username //= $assertion->nameid // '';

        die "Cannot determine username from SAML assertion\n"
            unless defined $username && length $username;

        # Extract email
        my $email = $attrs->{'email'} // $attrs->{'mail'} // $attrs->{'Email'} // '';
        $email = $email->[0] if ref $email eq 'ARRAY';
        $email = ($username =~ /@/) ? $username : '' unless $email;

        # Extract groups
        my $groups_attr = $cfg->{groups_attr} // 'groups';
        my $raw_groups = $attrs->{$groups_attr} // [];
        my @groups = ref $raw_groups eq 'ARRAY' ? @$raw_groups : ($raw_groups);

        # Group allowlist filter
        my $allowed = $cfg->{allowed_groups} // '';
        if (defined $allowed && length $allowed) {
            my %allowed_map = map { $_ => 1 } split /,\s*/, $allowed;
            my @matched = grep { $allowed_map{$_} } @groups;
            unless (@matched) {
                die "User '$username' is not in an allowed group\n";
            }
        }

        { success => 1, username => $username, email => $email, groups => \@groups };
    };

    if ($@) {
        my $err = "$@";
        chomp $err;
        warn "SAML: validate_response error: $err\n";
        return { success => 0, error => "SAML validation failed: $err" };
    }

    return $result // { success => 0, error => 'Unknown validation error' };
}

# Generate SP metadata XML
sub generate_metadata {
    my ($self) = @_;

    my $sp = $self->_sp // $self->_build_sp_object();
    return undef unless $sp;

    my $meta = eval { $sp->metadata };
    if ($@) {
        warn "SAML: metadata generation failed: $@\n";
        return undef;
    }

    return $meta;
}

# Health check — is SAML properly configured and SP object buildable?
sub is_available {
    my ($self) = @_;

    my $cfg = $self->config;

    # Must have IdP SSO URL and cert at minimum
    return 0 unless $cfg->{idp_sso_url} && length($cfg->{idp_sso_url});
    return 0 unless $cfg->{idp_cert}    && length($cfg->{idp_cert});
    return 0 unless $cfg->{entity_id}   && length($cfg->{entity_id});
    return 0 unless $cfg->{acs_url}     && length($cfg->{acs_url});

    my $sp = eval { $self->_sp // $self->_build_sp_object() };
    return ($sp && !$@) ? 1 : 0;
}

1;

__END__

=head1 NAME

Purl::API::Middleware::SAML - SAML 2.0 Service Provider authentication

=head1 SYNOPSIS

    my $saml = Purl::API::Middleware::SAML->new(config => {
        enabled       => 1,
        entity_id     => 'https://purl.example.com',
        idp_entity_id => 'https://idp.example.com',
        idp_sso_url   => 'https://idp.example.com/sso',
        idp_cert      => '-----BEGIN CERTIFICATE-----...',
        acs_url       => 'https://purl.example.com/api/auth/sso/callback',
    });

    # SP-initiated login
    my $req = $saml->build_authn_request('/dashboard');
    # redirect to $req->{redirect_url}

    # ACS callback
    my $result = $saml->validate_response($saml_response_b64);
    if ($result->{success}) {
        # $result->{username}, $result->{email}, $result->{groups}
    }

=cut
