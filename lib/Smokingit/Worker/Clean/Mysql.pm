use strict;
use warnings;

package Smokingit::Worker::Clean::Mysql;
use base 'Smokingit::Worker::Clean::Database';
use DBI;

sub user { "root" }
sub dsn  { "dbi:mysql:" }

sub list_dbs {
    my $self = shift;
    local $@;
    my @dbs = eval { DBI->data_sources(
        "mysql", {
            user => $self->{user},
            password => $self->{password},
        }
    ) };
    return map {s/^DBI:mysql:(.*)/$1/ ? $_ : () } grep defined, @dbs;
}

1;

