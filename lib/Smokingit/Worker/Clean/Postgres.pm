use strict;
use warnings;

package Smokingit::Worker::Clean::Postgres;
use base 'Smokingit::Worker::Clean::Database';
use DBI;

sub user { "postgres" }
sub dsn  { "dbi:Pg:" }

sub list_dbs {
    my $self = shift;
    local $@;
    my @dbs = eval { DBI->data_sources(
        "Pg",
        "user=$self->{user};password=$self->{password}",
    ) };
    return map {s/.*dbname=([^;]+).*/$1/ ? $_ : () } grep defined, @dbs;
}

1;

