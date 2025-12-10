package Purl::Query::KQL;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;

# KQL-like query language parser
# Supports: field:value, field:value*, AND, OR, NOT, (), "quoted phrases"
# Examples:
#   level:ERROR
#   level:ERROR AND service:api*
#   (level:ERROR OR level:WARN) AND host:prod*
#   message:"connection refused"
#   NOT level:DEBUG

has 'default_field' => (
    is      => 'ro',
    default => 'message',
);

# Known fields and their types
has 'field_types' => (
    is      => 'ro',
    default => sub {
        {
            timestamp => 'date',
            level     => 'keyword',
            service   => 'keyword',
            host      => 'keyword',
            message   => 'text',
            raw       => 'text',
        }
    },
);

# Parse KQL query to SQL WHERE clause
sub parse {
    my ($self, $query) = @_;

    return { sql => '1=1', bind => [] } unless defined $query && $query =~ /\S/;

    # Tokenize
    my $tokens = $self->_tokenize($query);

    # Parse tokens to AST
    my $ast = $self->_parse_expression($tokens);

    # Convert AST to SQL
    return $self->_ast_to_sql($ast);
}

# Tokenize query string
sub _tokenize {
    my ($self, $query) = @_;

    my @tokens;
    my $pos = 0;
    my $len = length($query);

    while ($pos < $len) {
        # Skip whitespace
        if (substr($query, $pos) =~ /^(\s+)/) {
            $pos += length($1);
            next;
        }

        # Operators
        if (substr($query, $pos) =~ /^(AND|OR|NOT)\b/i) {
            push @tokens, { type => 'OP', value => uc($1) };
            $pos += length($1);
            next;
        }

        # Parentheses
        if (substr($query, $pos, 1) eq '(') {
            push @tokens, { type => 'LPAREN' };
            $pos++;
            next;
        }
        if (substr($query, $pos, 1) eq ')') {
            push @tokens, { type => 'RPAREN' };
            $pos++;
            next;
        }

        # Quoted string
        if (substr($query, $pos, 1) eq '"') {
            if (substr($query, $pos) =~ /^"([^"]*)"/) {
                push @tokens, { type => 'TERM', value => $1, quoted => 1 };
                $pos += length($1) + 2;
                next;
            }
        }

        # Field:value or plain term
        if (substr($query, $pos) =~ /^([\w\.@]+):("[^"]*"|[^\s()]+)/) {
            my $field = $1;
            my $value = $2;
            my $matched = $field . ':' . $value;
            $value =~ s/^"(.*)"$/$1/;  # Remove quotes
            push @tokens, { type => 'FIELD', field => $field, value => $value };
            $pos += length($matched);
            next;
        }

        # Plain term (search in default field)
        if (substr($query, $pos) =~ /^([^\s()]+)/) {
            push @tokens, { type => 'TERM', value => $1 };
            $pos += length($1);
            next;
        }

        # Unknown character, skip
        $pos++;
    }

    return \@tokens;
}

# Parse tokens to AST (recursive descent parser)
sub _parse_expression {
    my ($self, $tokens) = @_;

    return $self->_parse_or($tokens);
}

sub _parse_or {
    my ($self, $tokens) = @_;

    my $left = $self->_parse_and($tokens);

    while (@$tokens && $tokens->[0]{type} eq 'OP' && $tokens->[0]{value} eq 'OR') {
        shift @$tokens;  # consume OR
        my $right = $self->_parse_and($tokens);
        $left = { type => 'OR', left => $left, right => $right };
    }

    return $left;
}

sub _parse_and {
    my ($self, $tokens) = @_;

    my $left = $self->_parse_not($tokens);

    while (@$tokens) {
        if ($tokens->[0]{type} eq 'OP' && $tokens->[0]{value} eq 'AND') {
            shift @$tokens;  # consume AND
        } elsif ($tokens->[0]{type} =~ /^(FIELD|TERM|LPAREN)$/) {
            # Implicit AND
        } else {
            last;
        }

        my $right = $self->_parse_not($tokens);
        $left = { type => 'AND', left => $left, right => $right } if $right;
    }

    return $left;
}

sub _parse_not {
    my ($self, $tokens) = @_;

    if (@$tokens && $tokens->[0]{type} eq 'OP' && $tokens->[0]{value} eq 'NOT') {
        shift @$tokens;  # consume NOT
        my $operand = $self->_parse_primary($tokens);
        return { type => 'NOT', operand => $operand };
    }

    return $self->_parse_primary($tokens);
}

sub _parse_primary {
    my ($self, $tokens) = @_;

    return unless @$tokens;

    my $token = $tokens->[0];

    # Parenthesized expression
    if ($token->{type} eq 'LPAREN') {
        shift @$tokens;  # consume (
        my $expr = $self->_parse_expression($tokens);

        if (@$tokens && $tokens->[0]{type} eq 'RPAREN') {
            shift @$tokens;  # consume )
        }

        return $expr;
    }

    # Field:value
    if ($token->{type} eq 'FIELD') {
        shift @$tokens;
        return {
            type  => 'MATCH',
            field => $token->{field},
            value => $token->{value},
        };
    }

    # Plain term
    if ($token->{type} eq 'TERM') {
        shift @$tokens;
        return {
            type   => 'MATCH',
            field  => $self->default_field,
            value  => $token->{value},
            quoted => $token->{quoted},
        };
    }

    return;
}

# Convert AST to SQL
sub _ast_to_sql {
    my ($self, $ast) = @_;

    return { sql => '1=1', bind => [] } unless $ast;

    my @bind;

    my $sql = $self->_node_to_sql($ast, \@bind);

    return { sql => $sql, bind => \@bind };
}

sub _node_to_sql {
    my ($self, $node, $bind) = @_;

    my $type = $node->{type};

    if ($type eq 'AND') {
        my $left = $self->_node_to_sql($node->{left}, $bind);
        my $right = $self->_node_to_sql($node->{right}, $bind);
        return "($left AND $right)";
    }

    if ($type eq 'OR') {
        my $left = $self->_node_to_sql($node->{left}, $bind);
        my $right = $self->_node_to_sql($node->{right}, $bind);
        return "($left OR $right)";
    }

    if ($type eq 'NOT') {
        my $operand = $self->_node_to_sql($node->{operand}, $bind);
        return "NOT ($operand)";
    }

    if ($type eq 'MATCH') {
        return $self->_match_to_sql($node, $bind);
    }

    return '1=1';
}

sub _match_to_sql {
    my ($self, $node, $bind) = @_;

    my $field = $node->{field};
    my $value = $node->{value};

    # Special time range syntax: @timestamp>now-1h
    if ($field eq '@timestamp' || $field eq 'timestamp') {
        return $self->_time_condition($value, $bind);
    }

    # Normalize field name
    $field = $self->_normalize_field($field);

    # Check if it's a valid field
    my $field_type = $self->field_types->{$field};

    # Wildcard matching
    if ($value =~ /\*/) {
        my $pattern = $value;
        $pattern =~ s/\*/%/g;
        push @$bind, $pattern;
        return "$field LIKE ?";
    }

    # Exact match for keywords
    if ($field_type && $field_type eq 'keyword') {
        push @$bind, $value;
        return "$field = ?";
    }

    # Contains match for text fields
    if ($field_type && $field_type eq 'text') {
        push @$bind, "%$value%";
        return "$field LIKE ?";
    }

    # Default: contains match
    push @$bind, "%$value%";
    return "$field LIKE ?";
}

# Handle time range conditions
sub _time_condition {
    my ($self, $value, $bind) = @_;

    # Parse relative time: now-1h, now-30m, now-7d
    if ($value =~ /^(>|>=|<|<=)?now(-(\d+)([mhdwM]))?$/) {
        my $op = $1 // '>=';
        my $amount = $3 // 0;
        my $unit = $4 // 'm';

        my $seconds = 0;
        if ($unit eq 'm') { $seconds = $amount * 60 }
        elsif ($unit eq 'h') { $seconds = $amount * 3600 }
        elsif ($unit eq 'd') { $seconds = $amount * 86400 }
        elsif ($unit eq 'w') { $seconds = $amount * 604800 }
        elsif ($unit eq 'M') { $seconds = $amount * 2592000 }

        my $time = time() - $seconds;
        my $ts = _epoch_to_iso($time);

        push @$bind, $ts;
        return "timestamp $op ?";
    }

    # Absolute time
    push @$bind, $value;
    return "timestamp >= ?";
}

sub _normalize_field {
    my ($self, $field) = @_;

    # Map common aliases
    my %aliases = (
        '@timestamp' => 'timestamp',
        'time'       => 'timestamp',
        'severity'   => 'level',
        'log_level'  => 'level',
        'app'        => 'service',
        'application' => 'service',
        'hostname'   => 'host',
        'server'     => 'host',
        'msg'        => 'message',
        'log'        => 'message',
    );

    return $aliases{$field} // $field;
}

sub _epoch_to_iso {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# Format query for display (syntax highlighting info)
sub explain {
    my ($self, $query) = @_;

    my $result = $self->parse($query);

    return {
        original => $query,
        sql      => $result->{sql},
        bind     => $result->{bind},
    };
}

1;

__END__

=head1 NAME

Purl::Query::KQL - KQL-like query language parser

=head1 SYNOPSIS

    use Purl::Query::KQL;

    my $kql = Purl::Query::KQL->new();

    # Parse query to SQL
    my $result = $kql->parse('level:ERROR AND service:api*');

    # Result:
    # {
    #     sql  => '(level = ? AND service LIKE ?)',
    #     bind => ['ERROR', 'api%'],
    # }

=head1 QUERY SYNTAX

    level:ERROR                    # exact match
    service:api*                   # wildcard
    message:"connection refused"   # phrase search
    level:ERROR AND service:nginx  # AND
    level:ERROR OR level:WARN      # OR
    NOT level:DEBUG                # NOT
    (level:ERROR OR level:WARN) AND host:prod*  # grouping
    @timestamp>now-1h              # time range

=cut
