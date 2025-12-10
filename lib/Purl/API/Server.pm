package Purl::API::Server;
use strict;
use warnings;
use 5.024;

use Mojolicious::Lite -signatures;
use Mojo::JSON qw(encode_json decode_json);

use Purl::Storage::SQLite;
use Purl::Storage::ClickHouse;
use Purl::Query::KQL;

# Package-level state
my $storage;
my $kql;
my $config = {};
my $websockets = [];

sub new {
    my ($class, %args) = @_;
    $config = $args{config} // {};
    return bless {}, $class;
}

sub _build_storage {
    my $storage_config = $config->{storage} // {};
    my $storage_type = $ENV{PURL_STORAGE_TYPE} // $storage_config->{type} // 'sqlite';
    my $retention_days = $storage_config->{retention_days} // 30;

    if ($storage_type eq 'clickhouse') {
        my $ch_config = $storage_config->{clickhouse} // {};
        return Purl::Storage::ClickHouse->new(
            host           => $ENV{PURL_CLICKHOUSE_HOST} // $ch_config->{host} // 'localhost',
            port           => $ENV{PURL_CLICKHOUSE_PORT} // $ch_config->{port} // 8123,
            database       => $ENV{PURL_CLICKHOUSE_DATABASE} // $ch_config->{database} // 'purl',
            username       => $ENV{PURL_CLICKHOUSE_USER} // $ch_config->{username} // 'default',
            password       => $ENV{PURL_CLICKHOUSE_PASSWORD} // $ch_config->{password} // '',
            buffer_size    => $ch_config->{buffer_size} // 1000,
            retention_days => $retention_days,
        );
    }

    # Default: SQLite
    my $sqlite_config = $storage_config->{sqlite} // {};
    return Purl::Storage::SQLite->new(
        db_path        => $ENV{PURL_DB_PATH} // $sqlite_config->{path} // './data/purl.db',
        fts_enabled    => $sqlite_config->{fts_enabled} // 1,
        retention_days => $retention_days,
    );
}

sub setup_routes {
    my ($self) = @_;

    $storage //= _build_storage();
    $kql //= Purl::Query::KQL->new();

    # Serve static files from web/public
    app->static->paths->[0] = '/app/web/public';

    # CORS middleware
    app->hook(before_dispatch => sub ($c) {
        $c->res->headers->header('Access-Control-Allow-Origin' => '*');
        $c->res->headers->header('Access-Control-Allow-Methods' => 'GET, POST, OPTIONS');
        $c->res->headers->header('Access-Control-Allow-Headers' => 'Content-Type');

        # Handle preflight
        if ($c->req->method eq 'OPTIONS') {
            $c->render(text => '', status => 200);
            return;
        }
    });

    # API routes
    my $api = app->routes->under('/api');

    # Health check
    $api->get('/health' => sub ($c) {
        $c->render(json => { status => 'ok', timestamp => time() });
    });

    # Search logs
    $api->get('/logs' => sub ($c) {
        my $query   = $c->param('q') // '';
        my $from    = $c->param('from');
        my $to      = $c->param('to');
        my $level   = $c->param('level');
        my $service = $c->param('service');
        my $host    = $c->param('host');
        my $limit   = $c->param('limit') // 500;
        my $offset  = $c->param('offset') // 0;
        my $order   = $c->param('order') // 'DESC';

        # Handle time range shortcuts
        if (my $range = $c->param('range')) {
            ($from, $to) = _parse_time_range($range);
        }

        my %params = (
            limit  => int($limit),
            offset => int($offset),
            order  => $order,
        );

        $params{from}    = $from if $from;
        $params{to}      = $to if $to;
        $params{level}   = $level if $level;
        $params{service} = $service if $service;
        $params{host}    = $host if $host;

        # Parse KQL query
        if ($query) {
            my $parsed = $kql->parse($query);
            $params{query} = $query;
        }

        my $results = $storage->search(%params);
        my $total = $storage->count(%params);

        $c->render(json => {
            hits  => $results,
            total => $total,
            query => $query,
        });
    });

    # KQL query endpoint (POST)
    $api->post('/query' => sub ($c) {
        my $body = decode_json($c->req->body);

        my $query = $body->{query} // '';
        my $from  = $body->{from};
        my $to    = $body->{to};
        my $limit = $body->{limit} // 500;

        my %params = (limit => int($limit));
        $params{from} = $from if $from;
        $params{to}   = $to if $to;

        if ($query) {
            my $parsed = $kql->parse($query);
            $params{query} = $query;
        }

        my $results = $storage->search(%params);

        $c->render(json => {
            hits  => $results,
            total => scalar(@$results),
        });
    });

    # Field statistics
    $api->get('/stats/fields/:field' => sub ($c) {
        my $field = $c->param('field');
        my $limit = $c->param('limit') // 10;
        my $from  = $c->param('from');
        my $to    = $c->param('to');

        # Validate field name
        unless ($field =~ /^(level|service|host)$/) {
            $c->render(json => { error => 'Invalid field' }, status => 400);
            return;
        }

        my %params = (limit => int($limit));
        $params{from} = $from if $from;
        $params{to}   = $to if $to;

        my $stats = $storage->field_stats($field, %params);

        $c->render(json => {
            field  => $field,
            values => $stats,
        });
    });

    # Time histogram
    $api->get('/stats/histogram' => sub ($c) {
        my $interval = $c->param('interval') // '1 hour';
        my $from     = $c->param('from');
        my $to       = $c->param('to');
        my $level    = $c->param('level');
        my $service  = $c->param('service');

        my %params = (interval => $interval);
        $params{from}    = $from if $from;
        $params{to}      = $to if $to;
        $params{level}   = $level if $level;
        $params{service} = $service if $service;

        my $histogram = $storage->histogram(%params);

        $c->render(json => {
            interval => $interval,
            buckets  => $histogram,
        });
    });

    # Available fields
    $api->get('/fields' => sub ($c) {
        my $fields = $storage->get_fields();
        $c->render(json => { fields => $fields });
    });

    # Database stats
    $api->get('/stats' => sub ($c) {
        my $stats = $storage->stats();
        $c->render(json => $stats);
    });

    # Configured sources
    $api->get('/sources' => sub ($c) {
        my $sources = $config->{sources} // [];
        $c->render(json => { sources => $sources });
    });

    # WebSocket for live tail
    $api->websocket('/logs/stream' => sub ($c) {
        my $ws = $c->tx;

        # Add to websocket list
        push @$websockets, $ws;

        $c->on(message => sub ($c, $msg) {
            my $data = eval { decode_json($msg) };
            if ($data && $data->{type} eq 'subscribe') {
                $ws->{filter} = $data->{filter} // {};
            }
        });

        $c->on(finish => sub ($c, $code, $reason) {
            $websockets = [grep { $_ != $ws } @$websockets];
        });

        $c->send(encode_json({
            type    => 'connected',
            message => 'Connected to log stream',
        }));
    });

    # Serve SPA for all other routes
    app->routes->get('/*catchall' => { catchall => '' } => sub ($c) {
        $c->reply->static('index.html');
    });

    return app;
}

# Parse time range shortcut (15m, 1h, 24h, 7d)
sub _parse_time_range {
    my ($range) = @_;

    my $now = time();
    my $from;

    if ($range =~ /^(\d+)m$/) {
        $from = $now - ($1 * 60);
    }
    elsif ($range =~ /^(\d+)h$/) {
        $from = $now - ($1 * 3600);
    }
    elsif ($range =~ /^(\d+)d$/) {
        $from = $now - ($1 * 86400);
    }
    else {
        return (undef, undef);
    }

    my $from_ts = _epoch_to_iso($from);
    my $to_ts = _epoch_to_iso($now);

    return ($from_ts, $to_ts);
}

sub _epoch_to_iso {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# Start the server
sub run {
    my ($self, %options) = @_;

    my $server_config = $config->{server} // {};

    my $host    = $options{host} // $server_config->{host} // '0.0.0.0';
    my $port    = $options{port} // $server_config->{port} // 3000;
    my $workers = $options{workers} // $server_config->{workers} // 4;

    $self->setup_routes();

    # Configure and start
    app->config(hypnotoad => {
        listen  => ["http://$host:$port"],
        workers => $workers,
    });

    app->log->level('info');
    app->log->info("Starting Purl server on http://$host:$port");

    app->start('daemon', '-l', "http://$host:$port");
}

1;

__END__

=head1 NAME

Purl::API::Server - Mojolicious REST API server

=head1 SYNOPSIS

    use Purl::API::Server;

    my $server = Purl::API::Server->new(
        config => $config,
    );

    $server->run(port => 3000);

=head1 API ENDPOINTS

    GET  /api/health              - Health check
    GET  /api/logs                - Search logs
    POST /api/query               - KQL query
    GET  /api/stats/fields/:field - Field statistics
    GET  /api/stats/histogram     - Time histogram
    GET  /api/fields              - Available fields
    GET  /api/stats               - Database stats
    GET  /api/sources             - Configured log sources
    WS   /api/logs/stream         - Live log stream

=cut
