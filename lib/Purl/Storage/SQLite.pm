package Purl::Storage::SQLite;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use DBI;
use JSON::XS ();
use Path::Tiny;
use Time::Piece;

has 'db_path' => (
    is      => 'ro',
    default => './data/purl.db',
);

has 'fts_enabled' => (
    is      => 'ro',
    default => 1,
);

has 'retention_days' => (
    is      => 'ro',
    default => 30,
);

has '_dbh' => (
    is      => 'rw',
    lazy    => 1,
    builder => '_build_dbh',
);

has '_json' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { JSON::XS->new->utf8->canonical },
);

has '_insert_sth' => (
    is      => 'rw',
);

sub BUILD {
    my ($self) = @_;

    # Ensure data directory exists
    my $dir = path($self->db_path)->parent;
    $dir->mkpath unless $dir->exists;
}

sub _build_dbh {
    my ($self) = @_;

    my $dbh = DBI->connect(
        "dbi:SQLite:dbname=" . $self->db_path,
        '', '',
        {
            RaiseError     => 1,
            PrintError     => 0,
            AutoCommit     => 1,
            sqlite_unicode => 1,
        }
    );

    # Performance optimizations
    $dbh->do('PRAGMA journal_mode = WAL');
    $dbh->do('PRAGMA synchronous = NORMAL');
    $dbh->do('PRAGMA cache_size = -64000');  # 64MB cache
    $dbh->do('PRAGMA temp_store = MEMORY');

    $self->_init_schema($dbh);

    return $dbh;
}

sub _init_schema {
    my ($self, $dbh) = @_;

    # Main logs table
    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            level TEXT NOT NULL,
            service TEXT NOT NULL,
            host TEXT NOT NULL,
            message TEXT NOT NULL,
            raw TEXT,
            meta_json TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        )
    });

    # Indexes for common queries
    $dbh->do('CREATE INDEX IF NOT EXISTS idx_logs_timestamp ON logs(timestamp)');
    $dbh->do('CREATE INDEX IF NOT EXISTS idx_logs_level ON logs(level)');
    $dbh->do('CREATE INDEX IF NOT EXISTS idx_logs_service ON logs(service)');
    $dbh->do('CREATE INDEX IF NOT EXISTS idx_logs_host ON logs(host)');
    $dbh->do('CREATE INDEX IF NOT EXISTS idx_logs_level_timestamp ON logs(level, timestamp)');
    $dbh->do('CREATE INDEX IF NOT EXISTS idx_logs_service_timestamp ON logs(service, timestamp)');

    # FTS5 virtual table for full-text search
    if ($self->fts_enabled) {
        $dbh->do(q{
            CREATE VIRTUAL TABLE IF NOT EXISTS logs_fts USING fts5(
                message,
                raw,
                content='logs',
                content_rowid='id'
            )
        });

        # Triggers to keep FTS in sync
        $dbh->do(q{
            CREATE TRIGGER IF NOT EXISTS logs_ai AFTER INSERT ON logs BEGIN
                INSERT INTO logs_fts(rowid, message, raw)
                VALUES (new.id, new.message, new.raw);
            END
        });

        $dbh->do(q{
            CREATE TRIGGER IF NOT EXISTS logs_ad AFTER DELETE ON logs BEGIN
                INSERT INTO logs_fts(logs_fts, rowid, message, raw)
                VALUES ('delete', old.id, old.message, old.raw);
            END
        });

        $dbh->do(q{
            CREATE TRIGGER IF NOT EXISTS logs_au AFTER UPDATE ON logs BEGIN
                INSERT INTO logs_fts(logs_fts, rowid, message, raw)
                VALUES ('delete', old.id, old.message, old.raw);
                INSERT INTO logs_fts(rowid, message, raw)
                VALUES (new.id, new.message, new.raw);
            END
        });
    }

    # Field statistics table
    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS field_stats (
            field_name TEXT NOT NULL,
            field_value TEXT NOT NULL,
            count INTEGER DEFAULT 1,
            last_seen TEXT,
            PRIMARY KEY (field_name, field_value)
        )
    });
}

# Insert single log
sub insert {
    my ($self, $log) = @_;

    $self->_insert_sth //= $self->_dbh->prepare(q{
        INSERT INTO logs (timestamp, level, service, host, message, raw, meta_json)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    });

    $self->_insert_sth->execute(
        $log->{timestamp},
        $log->{level},
        $log->{service},
        $log->{host},
        $log->{message},
        $log->{raw},
        $self->_json->encode($log->{meta} // {}),
    );

    return $self->_dbh->last_insert_id;
}

# Insert batch of logs
sub insert_batch {
    my ($self, $logs) = @_;

    return unless $logs && @$logs;

    $self->_dbh->begin_work;

    eval {
        for my $log (@$logs) {
            $self->insert($log);
        }
        $self->_dbh->commit;
    };

    if ($@) {
        $self->_dbh->rollback;
        die $@;
    }

    return scalar @$logs;
}

# Search logs
sub search {
    my ($self, %params) = @_;

    my @where;
    my @bind;

    # Time range
    if ($params{from}) {
        push @where, 'timestamp >= ?';
        push @bind, $params{from};
    }
    if ($params{to}) {
        push @where, 'timestamp <= ?';
        push @bind, $params{to};
    }

    # Level filter
    if ($params{level}) {
        if (ref $params{level} eq 'ARRAY') {
            my $placeholders = join(',', ('?') x @{$params{level}});
            push @where, "level IN ($placeholders)";
            push @bind, @{$params{level}};
        } else {
            push @where, 'level = ?';
            push @bind, $params{level};
        }
    }

    # Service filter
    if ($params{service}) {
        if ($params{service} =~ /\*/) {
            my $pattern = $params{service};
            $pattern =~ s/\*/%/g;
            push @where, 'service LIKE ?';
            push @bind, $pattern;
        } else {
            push @where, 'service = ?';
            push @bind, $params{service};
        }
    }

    # Host filter
    if ($params{host}) {
        push @where, 'host = ?';
        push @bind, $params{host};
    }

    # Full-text search
    if ($params{query} && $self->fts_enabled) {
        push @where, 'id IN (SELECT rowid FROM logs_fts WHERE logs_fts MATCH ?)';
        push @bind, $params{query};
    }

    # Message contains
    if ($params{message}) {
        push @where, 'message LIKE ?';
        push @bind, '%' . $params{message} . '%';
    }

    # Build query
    my $sql = 'SELECT * FROM logs';
    if (@where) {
        $sql .= ' WHERE ' . join(' AND ', @where);
    }

    # Order
    my $order = $params{order} // 'DESC';
    $sql .= " ORDER BY timestamp $order";

    # Limit & offset
    my $limit = $params{limit} // 500;
    $sql .= " LIMIT $limit";

    if ($params{offset}) {
        $sql .= " OFFSET " . int($params{offset});
    }

    my $sth = $self->_dbh->prepare($sql);
    $sth->execute(@bind);

    my @results;
    while (my $row = $sth->fetchrow_hashref) {
        $row->{meta} = eval { $self->_json->decode($row->{meta_json} // '{}') } // {};
        delete $row->{meta_json};
        push @results, $row;
    }

    return \@results;
}

# Count logs matching criteria
sub count {
    my ($self, %params) = @_;

    my @where;
    my @bind;

    if ($params{from}) {
        push @where, 'timestamp >= ?';
        push @bind, $params{from};
    }
    if ($params{to}) {
        push @where, 'timestamp <= ?';
        push @bind, $params{to};
    }
    if ($params{level}) {
        push @where, 'level = ?';
        push @bind, $params{level};
    }
    if ($params{service}) {
        push @where, 'service = ?';
        push @bind, $params{service};
    }

    my $sql = 'SELECT COUNT(*) FROM logs';
    if (@where) {
        $sql .= ' WHERE ' . join(' AND ', @where);
    }

    my ($count) = $self->_dbh->selectrow_array($sql, undef, @bind);
    return $count;
}

# Get field statistics (top values)
sub field_stats {
    my ($self, $field, %params) = @_;

    my $limit = $params{limit} // 10;

    my @where;
    my @bind;

    if ($params{from}) {
        push @where, 'timestamp >= ?';
        push @bind, $params{from};
    }
    if ($params{to}) {
        push @where, 'timestamp <= ?';
        push @bind, $params{to};
    }

    my $where_sql = @where ? 'WHERE ' . join(' AND ', @where) : '';

    my $sql = qq{
        SELECT $field as value, COUNT(*) as count
        FROM logs
        $where_sql
        GROUP BY $field
        ORDER BY count DESC
        LIMIT ?
    };

    my $sth = $self->_dbh->prepare($sql);
    $sth->execute(@bind, $limit);

    my @results;
    while (my $row = $sth->fetchrow_hashref) {
        push @results, $row;
    }

    return \@results;
}

# Get time histogram
sub histogram {
    my ($self, %params) = @_;

    my $interval = $params{interval} // '1 hour';

    # Convert interval to SQLite strftime format
    my $time_format;
    if ($interval =~ /minute/i) {
        $time_format = '%Y-%m-%d %H:%M:00';
    } elsif ($interval =~ /hour/i) {
        $time_format = '%Y-%m-%d %H:00:00';
    } elsif ($interval =~ /day/i) {
        $time_format = '%Y-%m-%d';
    } else {
        $time_format = '%Y-%m-%d %H:00:00';
    }

    my @where;
    my @bind;

    if ($params{from}) {
        push @where, 'timestamp >= ?';
        push @bind, $params{from};
    }
    if ($params{to}) {
        push @where, 'timestamp <= ?';
        push @bind, $params{to};
    }
    if ($params{level}) {
        push @where, 'level = ?';
        push @bind, $params{level};
    }
    if ($params{service}) {
        push @where, 'service = ?';
        push @bind, $params{service};
    }

    my $where_sql = @where ? 'WHERE ' . join(' AND ', @where) : '';

    my $sql = qq{
        SELECT strftime('$time_format', timestamp) as bucket,
               COUNT(*) as count
        FROM logs
        $where_sql
        GROUP BY bucket
        ORDER BY bucket ASC
    };

    my $sth = $self->_dbh->prepare($sql);
    $sth->execute(@bind);

    my @results;
    while (my $row = $sth->fetchrow_hashref) {
        push @results, $row;
    }

    return \@results;
}

# Get available fields
sub get_fields {
    my ($self) = @_;

    return [
        { name => 'timestamp', type => 'date' },
        { name => 'level', type => 'keyword' },
        { name => 'service', type => 'keyword' },
        { name => 'host', type => 'keyword' },
        { name => 'message', type => 'text' },
        { name => 'raw', type => 'text' },
    ];
}

# Cleanup old logs
sub cleanup {
    my ($self, $days) = @_;

    $days //= $self->retention_days;
    return 0 unless $days > 0;

    my $cutoff = Time::Piece->new - ($days * 86400);
    my $cutoff_ts = $cutoff->datetime . 'Z';

    my $deleted = $self->_dbh->do(
        'DELETE FROM logs WHERE timestamp < ?',
        undef, $cutoff_ts
    );

    # Optimize database
    $self->_dbh->do('VACUUM');

    return $deleted;
}

# Get database stats
sub stats {
    my ($self) = @_;

    my ($total) = $self->_dbh->selectrow_array('SELECT COUNT(*) FROM logs');
    my ($oldest) = $self->_dbh->selectrow_array('SELECT MIN(timestamp) FROM logs');
    my ($newest) = $self->_dbh->selectrow_array('SELECT MAX(timestamp) FROM logs');

    my $db_size = -s $self->db_path;

    return {
        total_logs => $total // 0,
        oldest_log => $oldest,
        newest_log => $newest,
        db_size_bytes => $db_size,
        db_size_mb => sprintf('%.2f', ($db_size // 0) / 1024 / 1024),
    };
}

# Close connection
sub disconnect {
    my ($self) = @_;

    if ($self->_insert_sth) {
        $self->_insert_sth->finish;
        $self->_insert_sth(undef);
    }

    if ($self->_dbh) {
        $self->_dbh->disconnect;
        $self->_dbh(undef);
    }
}

sub DEMOLISH {
    my ($self) = @_;
    $self->disconnect;
}

1;

__END__

=head1 NAME

Purl::Storage::SQLite - SQLite storage with FTS5 full-text search

=head1 SYNOPSIS

    use Purl::Storage::SQLite;

    my $storage = Purl::Storage::SQLite->new(
        db_path        => './data/purl.db',
        fts_enabled    => 1,
        retention_days => 30,
    );

    # Insert logs
    $storage->insert_batch(\@normalized_logs);

    # Search
    my $results = $storage->search(
        from    => '2024-12-10T00:00:00Z',
        level   => 'ERROR',
        query   => 'connection refused',
        limit   => 100,
    );

    # Field statistics
    my $top_services = $storage->field_stats('service', limit => 10);

    # Time histogram
    my $histogram = $storage->histogram(interval => '1 hour');

=cut
