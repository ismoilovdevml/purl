package Purl::Storage::ClickHouse::Pipeline;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use namespace::clean;

# ============================================
# Pipeline storage — ClickHouse CRUD for
# log processing pipelines and rules.
# ============================================

sub _init_pipeline_schema {
    my ($self) = @_;
    my $db = $self->database;

    $self->_query(qq{
        CREATE TABLE IF NOT EXISTS ${db}.pipelines (
            id UUID DEFAULT generateUUIDv4(),
            name String,
            description String DEFAULT '',
            filter_service String DEFAULT '',
            rules String CODEC(ZSTD(3)),
            enabled UInt8 DEFAULT 1,
            priority UInt32 DEFAULT 100,
            created_at DateTime DEFAULT now(),
            updated_at DateTime DEFAULT now()
        )
        ENGINE = @{[$self->_engine_replacing_mergetree('pipelines', 'updated_at')]}
        ORDER BY (priority, id)
    });
}

sub list_pipelines {
    my ($self) = @_;
    my $db = $self->database;

    my $sql = qq{
        SELECT
            toString(id) as id,
            name,
            description,
            filter_service,
            rules,
            enabled,
            priority,
            formatDateTime(created_at, '%Y-%m-%dT%H:%i:%SZ') as created_at,
            formatDateTime(updated_at, '%Y-%m-%dT%H:%i:%SZ') as updated_at
        FROM ${db}.pipelines FINAL
        ORDER BY priority ASC, name ASC
    };

    my $results = $self->_crud_read($sql);

    # Parse rules JSON
    for my $row (@$results) {
        $row->{rules}   = eval { $self->_json->decode($row->{rules} // '[]') } // [];
        $row->{enabled} = $row->{enabled} ? \1 : \0;
    }

    return $results;
}

sub get_pipeline {
    my ($self, $id) = @_;
    return undef unless $id && $id =~ /^[0-9a-f-]+$/i;

    my $db = $self->database;
    my $sql = qq{
        SELECT
            toString(id) as id,
            name,
            description,
            filter_service,
            rules,
            enabled,
            priority,
            formatDateTime(created_at, '%Y-%m-%dT%H:%i:%SZ') as created_at,
            formatDateTime(updated_at, '%Y-%m-%dT%H:%i:%SZ') as updated_at
        FROM ${db}.pipelines FINAL
        WHERE toString(id) = } . $self->_quote_string($id) . qq{
        LIMIT 1
    };

    my $results = $self->_crud_read($sql);
    return undef unless @$results;

    my $row = $results->[0];
    $row->{rules}   = eval { $self->_json->decode($row->{rules} // '[]') } // [];
    $row->{enabled} = $row->{enabled} ? \1 : \0;
    return $row;
}

sub create_pipeline {
    my ($self, $data) = @_;
    my $db = $self->database;

    my $name        = $self->_quote_string($data->{name} // 'Unnamed Pipeline');
    my $description = $self->_quote_string($data->{description} // '');
    my $filter      = $self->_quote_string($data->{filter_service} // '');
    my $rules       = $self->_quote_string($self->_json->encode($data->{rules} // []));
    my $enabled     = $data->{enabled} ? 1 : 0;
    my $priority    = int($data->{priority} // 100);

    my $sql = qq{
        INSERT INTO ${db}.pipelines (name, description, filter_service, rules, enabled, priority)
        VALUES ($name, $description, $filter, $rules, $enabled, $priority)
    };

    $self->_crud_write($sql);
    $self->invalidate_logs_cache() if $self->can('invalidate_logs_cache');
    return { status => 'created' };
}

sub update_pipeline {
    my ($self, $id, $data) = @_;
    return unless $id && $id =~ /^[0-9a-f-]+$/i;

    # ClickHouse ReplacingMergeTree: insert new version with same id
    my $existing = $self->get_pipeline($id);
    return undef unless $existing;

    my $db = $self->database;

    my $name        = $self->_quote_string($data->{name}           // $existing->{name});
    my $description = $self->_quote_string($data->{description}    // $existing->{description});
    my $filter      = $self->_quote_string($data->{filter_service} // $existing->{filter_service});
    my $rules       = $self->_quote_string(
        $self->_json->encode($data->{rules} // $existing->{rules})
    );
    my $enabled  = exists $data->{enabled} ? ($data->{enabled} ? 1 : 0) : ($existing->{enabled} ? 1 : 0);
    my $priority = int($data->{priority} // $existing->{priority} // 100);

    my $sql = qq{
        INSERT INTO ${db}.pipelines (id, name, description, filter_service, rules, enabled, priority, created_at, updated_at)
        VALUES ('$id', $name, $description, $filter, $rules, $enabled, $priority, '$existing->{created_at}', now())
    };

    $self->_crud_write($sql);
    $self->invalidate_logs_cache() if $self->can('invalidate_logs_cache');
    return { status => 'updated' };
}

sub delete_pipeline {
    my ($self, $id) = @_;
    return unless $id && $id =~ /^[0-9a-f-]+$/i;

    my $db = $self->database;
    my $sql = qq{ALTER TABLE ${db}.pipelines DELETE WHERE toString(id) = } . $self->_quote_string($id);
    $self->_crud_write($sql);
    return { status => 'deleted' };
}

1;
