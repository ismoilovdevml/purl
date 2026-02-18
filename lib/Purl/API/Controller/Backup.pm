package Purl::API::Controller::Backup;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json);

extends 'Purl::API::Controller::Base';

sub list {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $backups = $self->storage->list_backups();
        $c->render(json => { backups => $backups });
    });
}

sub create {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $body = eval { decode_json($c->req->body) } // {};
        my $name = $body->{name};
        my $backup_dir = $ENV{PURL_BACKUP_DIR} // '/app/backups';

        my $result = $self->storage->create_backup(
            name       => $name,
            backup_dir => $backup_dir,
        );

        $c->render(json => {
            status => 'ok',
            backup => $result,
        });
    });
}

sub restore {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $body = eval { decode_json($c->req->body) } // {};
        my $id = $body->{id};

        unless ($id) {
            $self->render_error($c, 'Backup ID required', 400);
            return;
        }

        my $result = $self->storage->restore_backup($id);

        $c->render(json => {
            status  => 'ok',
            restore => $result,
        });
    });
}

sub remove {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $id = $c->param('id');

        unless ($id) {
            $self->render_error($c, 'Backup ID required', 400);
            return;
        }

        my $result = $self->storage->delete_backup($id);

        $c->render(json => { status => 'ok' });
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Backup - Backup management endpoints

=head1 DESCRIPTION

Handles backup list, create, restore, and delete operations.

=cut
