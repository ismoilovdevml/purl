package Purl::Storage::ClickHouse::SavedSearches;
use strict;
use warnings;
use 5.024;

use Moo::Role;

# ============================================
# Saved Searches CRUD Operations
# ============================================

sub get_saved_searches {
    my ($self) = @_;
    my $db = $self->database;
    return $self->_query_json(qq{
        SELECT toString(id) as id, name, query, time_range, formatDateTime(created_at, '%Y-%m-%dT%H:%i:%SZ') as created_at
        FROM ${db}.saved_searches
        ORDER BY created_at DESC
    });
}

sub create_saved_search {
    my ($self, $name, $query, $time_range) = @_;
    my $db = $self->database;
    $time_range //= '15m';

    # Validate time_range format
    $time_range = '15m' unless $time_range =~ /^\d+[mhd]$/;

    $self->_query(qq{
        INSERT INTO ${db}.saved_searches (name, query, time_range)
        VALUES (@{[$self->_quote_string($name)]}, @{[$self->_quote_string($query)]}, @{[$self->_quote_string($time_range)]})
    });
    return 1;
}

sub delete_saved_search {
    my ($self, $id) = @_;
    my $db = $self->database;

    # Validate UUID format
    return 0 unless $self->_validate_uuid($id);

    $self->_query(qq{
        ALTER TABLE ${db}.saved_searches DELETE WHERE id = @{[$self->_quote_string($id)]}
    });
    return 1;
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::SavedSearches - Saved searches CRUD operations role

=head1 DESCRIPTION

This role provides CRUD operations for managing saved searches in ClickHouse.

=cut
