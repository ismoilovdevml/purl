package Purl::Storage::ClickHouse::Dashboard;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use namespace::clean;

# ============================================
# Dashboard storage — ClickHouse CRUD for
# custom dashboards and widget queries.
# ============================================

sub _init_dashboard_schema {
    my ($self) = @_;
    my $db = $self->database;

    $self->_query(qq{
        CREATE TABLE IF NOT EXISTS ${db}.dashboards (
            id UUID DEFAULT generateUUIDv4(),
            name String,
            description String DEFAULT '',
            widgets String CODEC(ZSTD(3)),
            layout String CODEC(ZSTD(3)),
            owner String DEFAULT '',
            shared UInt8 DEFAULT 0,
            created_at DateTime DEFAULT now(),
            updated_at DateTime DEFAULT now()
        )
        ENGINE = @{[$self->_engine_replacing_mergetree('dashboards', 'updated_at')]}
        ORDER BY (id)
    });
}

sub list_dashboards {
    my ($self, %params) = @_;
    my $db = $self->database;

    my $sql = qq{
        SELECT
            toString(id) as id,
            name,
            description,
            widgets,
            layout,
            owner,
            shared,
            formatDateTime(created_at, '%Y-%m-%dT%H:%i:%SZ') as created_at,
            formatDateTime(updated_at, '%Y-%m-%dT%H:%i:%SZ') as updated_at
        FROM ${db}.dashboards FINAL
        ORDER BY updated_at DESC
    };

    my $results = $self->_crud_read($sql);

    for my $row (@$results) {
        $row->{widgets} = eval { $self->_json->decode($row->{widgets} // '[]') } // [];
        $row->{layout}  = eval { $self->_json->decode($row->{layout}  // '{}') } // {};
        $row->{shared}  = $row->{shared} ? \1 : \0;
    }

    return $results;
}

sub get_dashboard {
    my ($self, $id) = @_;
    return undef unless $id && $id =~ /^[0-9a-f-]+$/i;

    my $db = $self->database;
    my $sql = qq{
        SELECT
            toString(id) as id,
            name,
            description,
            widgets,
            layout,
            owner,
            shared,
            formatDateTime(created_at, '%Y-%m-%dT%H:%i:%SZ') as created_at,
            formatDateTime(updated_at, '%Y-%m-%dT%H:%i:%SZ') as updated_at
        FROM ${db}.dashboards FINAL
        WHERE toString(id) = } . $self->_quote_string($id) . qq{
        LIMIT 1
    };

    my $results = $self->_crud_read($sql);
    return undef unless @$results;

    my $row = $results->[0];
    $row->{widgets} = eval { $self->_json->decode($row->{widgets} // '[]') } // [];
    $row->{layout}  = eval { $self->_json->decode($row->{layout}  // '{}') } // {};
    $row->{shared}  = $row->{shared} ? \1 : \0;
    return $row;
}

sub create_dashboard {
    my ($self, $data) = @_;
    my $db = $self->database;

    my $name        = $self->_quote_string($data->{name} // 'Untitled Dashboard');
    my $description = $self->_quote_string($data->{description} // '');
    my $widgets     = $self->_quote_string($self->_json->encode($data->{widgets} // []));
    my $layout      = $self->_quote_string($self->_json->encode($data->{layout} // {}));
    my $owner       = $self->_quote_string($data->{owner} // '');
    my $shared      = $data->{shared} ? 1 : 0;

    my $sql = qq{
        INSERT INTO ${db}.dashboards (name, description, widgets, layout, owner, shared)
        VALUES ($name, $description, $widgets, $layout, $owner, $shared)
    };

    $self->_crud_write($sql);
    return { status => 'created' };
}

sub update_dashboard {
    my ($self, $id, $data) = @_;
    return undef unless $id && $id =~ /^[0-9a-f-]+$/i;

    my $existing = $self->get_dashboard($id);
    return undef unless $existing;

    my $db = $self->database;

    my $name        = $self->_quote_string($data->{name}        // $existing->{name});
    my $description = $self->_quote_string($data->{description} // $existing->{description});
    my $widgets     = $self->_quote_string(
        $self->_json->encode($data->{widgets} // $existing->{widgets})
    );
    my $layout = $self->_quote_string(
        $self->_json->encode($data->{layout} // $existing->{layout})
    );
    my $owner  = $self->_quote_string($data->{owner}  // $existing->{owner});
    my $shared = exists $data->{shared} ? ($data->{shared} ? 1 : 0) : ($existing->{shared} ? 1 : 0);

    my $sql = qq{
        INSERT INTO ${db}.dashboards (id, name, description, widgets, layout, owner, shared, created_at, updated_at)
        VALUES ('$id', $name, $description, $widgets, $layout, $owner, $shared, '$existing->{created_at}', now())
    };

    $self->_crud_write($sql);
    return { status => 'updated' };
}

sub delete_dashboard {
    my ($self, $id) = @_;
    return unless $id && $id =~ /^[0-9a-f-]+$/i;

    my $db = $self->database;
    my $sql = qq{ALTER TABLE ${db}.dashboards DELETE WHERE toString(id) = } . $self->_quote_string($id);
    $self->_crud_write($sql);
    return { status => 'deleted' };
}

# Normalize widget config: templates store query as a string with top-level
# timeRange/groupBy/limit, but _widget_* methods expect a hashref with
# filter/level/service/time_range/field/limit/interval keys.
sub _normalize_widget_query {
    my ($self, $widget) = @_;
    my $raw = $widget->{query};

    # Already a hashref — merge in any top-level overrides
    if (ref $raw eq 'HASH') {
        $raw->{time_range} //= $widget->{timeRange} if $widget->{timeRange};
        $raw->{field}      //= $widget->{groupBy}   if $widget->{groupBy};
        $raw->{limit}      //= $widget->{limit}     if defined $widget->{limit};
        $raw->{interval}   //= $widget->{interval}  if $widget->{interval};
        return $raw;
    }

    # String query (old template format) — normalize to hashref
    my %q;
    $q{time_range} = $widget->{timeRange} if $widget->{timeRange};
    $q{field}      = $widget->{groupBy}   if $widget->{groupBy};
    $q{limit}      = $widget->{limit}     if defined $widget->{limit};
    $q{interval}   = $widget->{interval}  if $widget->{interval};

    my $str = defined $raw ? "$raw" : '';
    return \%q if $str eq '' || $str eq '*';

    # Simple "level:X"
    if ($str =~ /^level:(\w+)$/i) {
        $q{level} = uc($1);
        return \%q;
    }

    # Simple "service:X"
    if ($str =~ /^service:([\w._-]+)$/i) {
        $q{service} = $1;
        return \%q;
    }

    # "level:X OR level:Y OR ..."
    if ($str =~ /^level:\w+(?:\s+OR\s+level:\w+)+$/i) {
        my @levels;
        while ($str =~ /level:(\w+)/gi) {
            push @levels, uc($1);
        }
        $q{level} = \@levels if @levels;
        return \%q;
    }

    # Fallback: pass as text filter
    $q{filter} = $str;
    return \%q;
}

# Execute a widget query (for counter, chart, table widgets)
sub execute_widget_query {
    my ($self, $widget) = @_;
    my $type  = $widget->{type}  // 'counter';
    my $query = $self->_normalize_widget_query($widget);

    if ($type eq 'counter') {
        return $self->_widget_counter($query);
    } elsif ($type eq 'chart') {
        return $self->_widget_chart($query);
    } elsif ($type eq 'table') {
        return $self->_widget_table($query);
    } elsif ($type eq 'log_stream') {
        return $self->_widget_log_stream($query);
    }

    return { error => 'Unknown widget type' };
}

sub _widget_counter {
    my ($self, $query) = @_;
    my %params;
    $params{query}   = $query->{filter}     if $query->{filter};
    $params{level}   = $query->{level}      if $query->{level};
    $params{service} = $query->{service}    if $query->{service};
    $params{range}   = $query->{time_range} // '1h';

    my $count = $self->count(%params);
    return { value => $count };
}

sub _widget_chart {
    my ($self, $query) = @_;
    my %params;
    $params{query}   = $query->{filter}     if $query->{filter};
    $params{level}   = $query->{level}      if $query->{level};
    $params{service} = $query->{service}    if $query->{service};
    $params{range}   = $query->{time_range} // '1h';

    my $interval = $query->{interval} // '1 minute';
    my $data = $self->histogram(%params, interval => $interval);
    return { data => $data };
}

sub _widget_table {
    my ($self, $query) = @_;
    my $field = $query->{field} // 'service';
    my $limit = $query->{limit} // 10;
    my %params;
    $params{range} = $query->{time_range} // '1h';

    my $stats = $self->field_stats($field, %params, limit => $limit);
    return { data => $stats };
}

sub _widget_log_stream {
    my ($self, $query) = @_;
    my %params;
    $params{query}   = $query->{filter}  if $query->{filter};
    $params{level}   = $query->{level}   if $query->{level};
    $params{service} = $query->{service} if $query->{service};
    $params{range}   = $query->{time_range} if $query->{time_range};
    $params{limit}   = $query->{limit}   // 20;
    $params{order}   = 'DESC';

    my $logs = $self->search(%params);
    return { logs => $logs };
}

1;
