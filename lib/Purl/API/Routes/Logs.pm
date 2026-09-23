package Purl::API::Routes::Logs;
use strict;
use warnings;
use 5.024;

# Log search/ingest, traces, stats, analytics, patterns and saved searches.
# All protected. See Purl::API::Routes for %deps.
sub register {
    my (%deps) = @_;
    my $protected = $deps{protected};
    my $ctl       = $deps{controllers};
    my $logs      = $ctl->{logs};
    my $otlp      = $ctl->{otlp};
    my $traces    = $ctl->{traces};
    my $stats     = $ctl->{stats};
    my $analytics = $ctl->{analytics};
    my $patterns  = $ctl->{patterns};
    my $saved     = $ctl->{saved_searches};

    # ============================================
    # Log endpoints
    # ============================================
    $protected->get('/logs' => sub { my ($c) = @_; $logs->search($c) });
    $protected->post('/logs' => sub { my ($c) = @_; $logs->ingest($c) });
    $protected->get('/logs/:id/context' => sub { my ($c) = @_; $logs->context($c) });
    $protected->post('/query' => sub { my ($c) = @_; $logs->query($c) });

    # ============================================
    # OTLP ingest endpoints
    # ============================================
    $protected->post('/v1/otlp/logs' => sub { my ($c) = @_; $otlp->ingest($c) });

    # ============================================
    # Trace endpoints
    # ============================================
    $protected->get('/traces/recent' => sub { my ($c) = @_; $traces->get_recent_traces($c) });
    $protected->get('/traces/:trace_id' => sub { my ($c) = @_; $traces->get_trace($c) });
    $protected->get('/traces/:trace_id/timeline' => sub { my ($c) = @_; $traces->get_trace_timeline($c) });
    $protected->get('/requests/:request_id' => sub { my ($c) = @_; $traces->get_request($c) });

    # ============================================
    # Stats endpoints
    # ============================================
    $protected->get('/stats/fields/#field' => sub { my ($c) = @_; $stats->field_stats($c) });
    $protected->get('/stats/histogram' => sub { my ($c) = @_; $stats->histogram($c) });
    $protected->get('/fields' => sub { my ($c) = @_; $stats->fields($c) });
    $protected->get('/stats' => sub { my ($c) = @_; $stats->db_stats($c) });

    # ============================================
    # Analytics endpoints
    # ============================================
    $protected->get('/analytics/tables' => sub { my ($c) = @_; $analytics->tables($c) });
    $protected->get('/analytics/queries' => sub { my ($c) = @_; $analytics->queries($c) });
    $protected->get('/analytics/notifiers' => sub { my ($c) = @_; $analytics->notifiers($c) });

    # ============================================
    # Pattern endpoints
    # ============================================
    $protected->get('/patterns' => sub { my ($c) = @_; $patterns->list($c) });
    $protected->get('/patterns/:hash/logs' => sub { my ($c) = @_; $patterns->logs($c) });
    $protected->get('/patterns/stats' => sub { my ($c) = @_; $patterns->stats($c) });

    # ============================================
    # Saved Searches endpoints
    # ============================================
    $protected->get('/saved-searches' => sub { my ($c) = @_; $saved->list($c) });
    $protected->post('/saved-searches' => sub { my ($c) = @_; $saved->create($c) });
    $protected->delete('/saved-searches/:id' => sub { my ($c) = @_; $saved->remove($c) });

    return;
}

1;

__END__

=head1 NAME

Purl::API::Routes::Logs - log search/ingest, trace, stats, analytics,
pattern and saved-search routes

=cut
