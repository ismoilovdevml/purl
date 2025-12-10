# Purl - Log Aggregation Dashboard
# Perl dependencies

requires 'perl', '5.024';

# OOP
requires 'Moo', '2.005';
requires 'namespace::clean', '0.27';

# JSON
requires 'JSON::XS', '4.0';

# Web Framework
requires 'Mojolicious', '9.0';

# HTTP client (for ClickHouse HTTP API)
requires 'HTTP::Tiny';
requires 'URI::Escape';

# Date/Time
requires 'Time::Piece';

# Crypto (for caching)
requires 'Digest::MD5';

# Auth
requires 'MIME::Base64';
