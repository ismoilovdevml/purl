package Purl::API::Routes::Analytics;
use strict;
use warnings;
use 5.024;

use Exporter 'import';

our @EXPORT_OK = qw(setup_analytics_routes);

# ============================================
# Analytics Routes Setup
# ============================================

sub setup_analytics_routes {
    my ($protected, $storage, $notifiers, $cache_funcs) = @_;

    my ($cache_get, $cache_set) = @$cache_funcs;

    # Table statistics
    $protected->get('/analytics/tables' => sub {
        my ($c) = @_;
        my $cache_key = 'analytics_tables';
        if (my $cached = $cache_get->($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        my $tables = $storage->get_table_stats();
        my $response = { tables => $tables };

        $cache_set->($cache_key, $response, 60);
        $c->res->headers->header('X-Cache' => 'MISS');

        $c->render(json => $response);
    });

    # Recent slow queries
    $protected->get('/analytics/queries' => sub {
        my ($c) = @_;
        my $limit = $c->param('limit') // 10;

        my $cache_key = "analytics_queries:$limit";
        if (my $cached = $cache_get->($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        my $queries = $storage->get_slow_queries(int($limit));
        my $response = { queries => $queries };

        $cache_set->($cache_key, $response, 30);
        $c->res->headers->header('X-Cache' => 'MISS');

        $c->render(json => $response);
    });

    # Notifier status
    $protected->get('/analytics/notifiers' => sub {
        my ($c) = @_;
        my %status;
        for my $type (keys %$notifiers) {
            $status{$type} = {
                configured => 1,
                name       => $notifiers->{$type}->name,
            };
        }

        $c->render(json => {
            notifiers => \%status,
            available => [qw(telegram slack webhook)],
        });
    });
}

1;

__END__

=head1 NAME

Purl::API::Routes::Analytics - Analytics and monitoring routes

=cut
