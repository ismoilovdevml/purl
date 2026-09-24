package Purl::Storage::ClickHouse::JsonColumn;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use JSON::XS ();
use Encode ();
use namespace::clean;

# ============================================
# JSON kept in a ClickHouse String column (logs.meta, dashboards.widgets,
# pipelines.rules, ...).
#
# The encoding rule of the storage layer (#113): SQL text and bind parameters
# are Perl CHARACTER strings, and Connection encodes them to UTF-8 exactly once
# on the way out. JSON that is embedded in SQL, or nested inside a JSONEachRow
# row, is therefore produced as characters too — never as UTF-8 bytes, which
# the outer encoding would encode a second time.
#
# Reading is the mirror image: JSONEachRow has already been decoded, so a
# column value is a character string and is decoded as such.
# ============================================

has '_json_text' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { JSON::XS->new->canonical->allow_nonref },
);

sub _encode_json_column {
    my ($self, $data) = @_;
    return $self->_json_text->encode($data);
}

# Decode a JSON column value; $default when it is empty or not valid JSON.
#
# Rows written before #113 hold non-ASCII JSON that was UTF-8 encoded twice
# (the nested JSON went in as bytes and the row encoder encoded them again).
# Such a value reads back as a string of code points <= 0xFF that is itself
# valid UTF-8, so it is decoded once more. A current row whose characters
# happen to spell valid UTF-8 in Latin-1 (e.g. "Ã©") would be misread — an
# accepted trade for not showing every old Cyrillic/CJK meta as mojibake.
sub _decode_json_column {
    my ($self, $text, $default) = @_;
    return $default unless defined $text && length $text;

    if ($text =~ /[\x80-\xFF]/ && $text !~ /[^\x00-\xFF]/) {
        my $bytes = $text;
        my $once  = eval { Encode::decode('UTF-8', $bytes, Encode::FB_CROAK) };
        $text = $once if defined $once;
    }

    my $value = eval { $self->_json_text->decode($text) };
    return defined $value ? $value : $default;
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::JsonColumn - encode/decode JSON stored in ClickHouse String
columns as character strings, so the transport's single UTF-8 encoding is the only one.

=cut
