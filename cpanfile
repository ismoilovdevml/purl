# Purl - Universal Log Parser & Dashboard
# Perl dependencies

requires 'perl', '5.024';

# Core
requires 'Moo', '2.005';
requires 'namespace::clean', '0.27';
requires 'Type::Tiny', '2.000';

# JSON
requires 'JSON::XS', '4.0';

# YAML config
requires 'YAML::XS', '0.88';

# Web Framework
requires 'Mojolicious', '9.0';

# Database
requires 'DBI', '1.643';
requires 'DBD::SQLite', '1.74';

# File operations
requires 'Path::Tiny', '0.144';

# Config merging
requires 'Hash::Merge';

# Date/Time
requires 'Time::Piece';

# HTTP client (for ClickHouse)
requires 'HTTP::Tiny';
requires 'URI::Escape';

# Testing
on 'test' => sub {
    requires 'Test::More', '1.302';
    requires 'Test::Exception', '0.43';
};
