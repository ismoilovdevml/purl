package Purl::Alert::Telegram;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use HTTP::Tiny;
use JSON::XS ();
use URI::Escape qw(uri_escape);

with 'Purl::Alert::Base';

has 'bot_token' => (
    is       => 'ro',
    required => 1,
);

has 'chat_id' => (
    is       => 'ro',
    required => 1,
);

has 'parse_mode' => (
    is      => 'ro',
    default => 'HTML',
);

has '_http' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        HTTP::Tiny->new(
            timeout => 10,
            agent   => 'Purl-Alert/1.0',
        )
    },
);

has '_json' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { JSON::XS->new->utf8 },
);

sub deliver {
    my ($self, $message) = @_;

    my $text = $self->_format_telegram_message($message);
    my $url = sprintf(
        'https://api.telegram.org/bot%s/sendMessage',
        $self->bot_token
    );

    my $payload = $self->_json->encode({
        chat_id    => $self->chat_id,
        text       => $text,
        parse_mode => $self->parse_mode,
    });

    my $response = $self->_http->post($url, {
        content => $payload,
        headers => { 'Content-Type' => 'application/json' },
    });

    unless ($response->{success}) {
        warn "Telegram send failed: $response->{status} - $response->{content}";
        return 0;
    }

    return 1;
}

sub _format_telegram_message {
    my ($self, $msg) = @_;

    my $severity_emoji = $msg->{severity} eq 'critical' ? "\x{1F6A8}" : "\x{26A0}";
    my $severity_text = uc($msg->{severity});

    return <<"EOF";
$severity_emoji <b>PURL ALERT</b> $severity_emoji

<b>Alert:</b> $msg->{alert}
<b>Severity:</b> $severity_text
<b>Query:</b> <code>$msg->{query}</code>

<b>Count:</b> $msg->{count} (threshold: $msg->{threshold})
<b>Window:</b> $msg->{window} minutes
<b>Time:</b> $msg->{time}
EOF
}

# Test connection
sub test {
    my ($self) = @_;

    my $url = sprintf(
        'https://api.telegram.org/bot%s/getMe',
        $self->bot_token
    );

    my $response = $self->_http->get($url);

    if ($response->{success}) {
        my $data = eval { $self->_json->decode($response->{content}) };
        return $data->{ok} ? $data->{result} : 0;
    }

    return 0;
}

# Send test message
sub send_test {
    my ($self) = @_;

    return $self->deliver({
        title     => 'Test Alert',
        alert     => 'Test Connection',
        query     => 'level:ERROR',
        count     => 5,
        threshold => 10,
        window    => 5,
        time      => scalar localtime(),
        severity  => 'warning',
    });
}

1;

__END__

=head1 NAME

Purl::Alert::Telegram - Telegram Bot alert notifier

=head1 SYNOPSIS

    use Purl::Alert::Telegram;

    my $telegram = Purl::Alert::Telegram->new(
        name      => 'my-telegram',
        bot_token => '123456:ABC-DEF...',
        chat_id   => '-1001234567890',
    );

    # Test connection
    if (my $bot = $telegram->test) {
        print "Connected as: $bot->{username}\n";
    }

    # Send test message
    $telegram->send_test;

    # Send alert
    $telegram->notify($alert, { count => 15 });

=head1 CONFIGURATION

1. Create bot via @BotFather on Telegram
2. Get bot token from BotFather
3. Add bot to group/channel or get your chat_id
4. For group chat_id: add bot, send message, check:
   https://api.telegram.org/bot<TOKEN>/getUpdates

=cut
