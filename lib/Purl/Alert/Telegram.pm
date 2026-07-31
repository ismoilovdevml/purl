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

# Forum topic to post into (Telegram "supergroup with topics"). Optional: empty
# means the group's General topic, which is what every non-forum chat has.
has 'thread_id' => (
    is      => 'ro',
    default => '',
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

    my %payload = (
        chat_id    => $self->chat_id,
        text       => $text,
        parse_mode => $self->parse_mode,
    );

    # Forum routing rides on sendMessage or it does not happen at all — there
    # is no other way to reach a topic. Omitted unless well formed: Telegram
    # rejects the WHOLE request on a bad message_thread_id, so a stray value
    # must cost us the topic, never the alert. `0 +` because the Bot API wants
    # a JSON number and settings.json holds it as a string.
    $payload{message_thread_id} = 0 + $self->thread_id
        if valid_thread_id($self->thread_id);

    my $response = $self->_http->post($url, {
        content => $self->_json->encode(\%payload),
        headers => { 'Content-Type' => 'application/json' },
    });

    unless ($response->{success}) {
        warn "Telegram send failed: $response->{status} - $response->{content}";
        return 0;
    }

    return 1;
}

# Would Telegram accept this as a forum topic id?
#
# ONE definition, because two callers must agree: the settings endpoint refuses
# a bad value at the boundary, and deliver() also sees values that arrive by
# PURL_TELEGRAM_THREAD_ID and never pass through that endpoint. If the two ever
# disagreed we would be back to #71 — a value the API accepts and the channel
# silently drops.
#
# A plain sub, not a method: the controller asks about a PROPOSED value, before
# any channel object exists to carry it. Topic ids are positive integers, so 0
# and negatives are rejected rather than quietly meaning "General".
sub valid_thread_id {
    my ($value) = @_;
    return 0 if !defined $value || ref $value;
    return $value =~ /\A[1-9][0-9]{0,18}\z/ ? 1 : 0;
}

sub _html_escape {
    my ($str) = @_;
    $str =~ s/&/&amp;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;
    $str =~ s/"/&quot;/g;
    return $str;
}

sub _format_telegram_message {
    my ($self, $msg) = @_;

    my $severity_emoji = $msg->{severity} eq 'critical' ? "\x{1F6A8}" : "\x{26A0}";
    my $severity_text = uc($msg->{severity});

    my $alert = _html_escape($msg->{alert} // '');
    my $query = _html_escape($msg->{query} // '');

    return <<"EOF";
$severity_emoji <b>PURL ALERT</b> $severity_emoji

<b>Alert:</b> $alert
<b>Severity:</b> $severity_text
<b>Query:</b> <code>$query</code>

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
