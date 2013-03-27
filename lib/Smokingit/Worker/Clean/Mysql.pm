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

sub list_users {
    my $self = shift;
    my $users = $self->dbh->selectcol_arrayref(
        "SELECT concat(User,'\@',Host) FROM mysql.user");
    return @$users;
}

sub clean_user_sql {
    "DROP USER $_[1]\n"
}

1;

