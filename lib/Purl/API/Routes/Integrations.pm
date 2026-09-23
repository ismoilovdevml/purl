package Purl::API::Routes::Integrations;
use strict;
use warnings;
use 5.024;

# Third-party ingest/query surfaces and add-on features: Elasticsearch
# compatibility, syslog, pipelines, dashboards, Kubernetes, AI and clusters.
# All protected. See Purl::API::Routes for %deps.
sub register {
    my (%deps) = @_;
    my $protected    = $deps{protected};
    my $auth         = $deps{auth_middleware};
    my $rate_limited = $deps{rate_limited};
    my $ctl          = $deps{controllers};
    my $escompat     = $ctl->{escompat};
    my $syslog       = $ctl->{syslog};
    my $pipeline     = $ctl->{pipeline};
    my $dashboard    = $ctl->{dashboard};
    my $k8saudit     = $ctl->{k8saudit};
    my $k8shealth    = $ctl->{k8shealth};
    my $ai           = $ctl->{ai};
    my $clusters     = $ctl->{clusters};

    # ============================================
    # Elasticsearch-compatible endpoints
    # ============================================
    $protected->post('/es/_search' => sub { my ($c) = @_; $escompat->search($c) });
    $protected->post('/es/_msearch' => sub { my ($c) = @_; $escompat->msearch($c) });
    $protected->get('/es/_field_caps' => sub { my ($c) = @_; $escompat->field_caps($c) });

    # ============================================
    # Syslog ingest endpoint
    # ============================================
    $protected->post('/v1/syslog' => sub { my ($c) = @_; $syslog->ingest($c) });

    # ============================================
    # Pipeline endpoints
    # ============================================
    $protected->get('/pipelines' => sub { my ($c) = @_; $pipeline->list($c) });
    $protected->get('/pipelines/:id' => sub { my ($c) = @_; $pipeline->get($c) });
    $protected->post('/pipelines' => sub { my ($c) = @_; $pipeline->create($c) });
    $protected->put('/pipelines/:id' => sub { my ($c) = @_; $pipeline->update($c) });
    $protected->delete('/pipelines/:id' => sub { my ($c) = @_; $pipeline->remove($c) });
    $protected->post('/pipelines/test' => sub { my ($c) = @_; $pipeline->test($c) });

    # ============================================
    # Dashboard endpoints
    # ============================================
    $protected->get('/dashboards' => sub { my ($c) = @_; $dashboard->list($c) });
    $protected->get('/dashboards/templates' => sub { my ($c) = @_; $dashboard->list_templates($c) });
    $protected->get('/dashboards/:id' => sub { my ($c) = @_; $dashboard->get($c) });
    $protected->post('/dashboards' => sub { my ($c) = @_; $dashboard->create($c) });
    $protected->post('/dashboards/from-template' => sub { my ($c) = @_; $dashboard->create_from_template($c) });
    $protected->put('/dashboards/:id' => sub { my ($c) = @_; $dashboard->update($c) });
    $protected->delete('/dashboards/:id' => sub { my ($c) = @_; $dashboard->remove($c) });
    $protected->post('/dashboards/widget' => sub { my ($c) = @_; $dashboard->execute_widget($c) });

    # ============================================
    # K8s Audit webhook endpoint
    # ============================================
    $protected->post('/v1/k8s-audit' => sub { my ($c) = @_; $k8saudit->ingest($c) });

    # ============================================
    # K8s Health endpoints
    # ============================================
    $protected->get('/k8s/health' => sub { my ($c) = @_; $k8shealth->summary($c) });
    $protected->get('/k8s/health/pods' => sub { my ($c) = @_; $k8shealth->pods($c) });

    # ============================================
    # AI query endpoints
    # ============================================
    # The LLM-backed calls get their own per-user budget (#83).
    my $ai_llm = $protected->under('/ai' => sub {
        my ($c) = @_;
        my $auth_middleware = $auth->();
        return 1 if $auth_middleware->check_ai_rate_limit($c);
        my $max    = $auth_middleware->ai_rate_limit_max;
        my $window = $auth_middleware->ai_rate_limit_window;
        return $rate_limited->($c,
            "AI rate limit exceeded: at most $max AI requests per ${window}s",
            $auth_middleware->ai_rate_limit_retry_after($c));
    });
    $ai_llm->post('/query'          => sub { my ($c) = @_; $ai->query($c) });
    $ai_llm->post('/analyze'        => sub { my ($c) = @_; $ai->analyze($c) });
    $ai_llm->post('/explain'        => sub { my ($c) = @_; $ai->explain($c) });
    $protected->get('/ai/suggest'   => sub { my ($c) = @_; $ai->suggest($c) });
    $protected->get('/ai/providers' => sub { my ($c) = @_; $ai->providers($c) });

    # ============================================
    # Clusters endpoint (multi-cluster support)
    # ============================================
    $protected->get('/clusters' => sub { my ($c) = @_; $clusters->list($c) });

    return;
}

1;

__END__

=head1 NAME

Purl::API::Routes::Integrations - Elasticsearch-compatible, syslog,
pipeline, dashboard, Kubernetes, AI and cluster routes

=cut
