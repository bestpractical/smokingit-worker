use strict;
use warnings;

package Smokingit::Worker::Clean::Database;
use base 'Smokingit::Worker::Clean';
use DBI;

sub user { die "!!!\n" }
sub dsn  { die "!!!\n" }

sub new {
    my $class = shift;
    my %args = (
        user => $class->user,
        password => "",
        @_,
    );
    my $self = $class->SUPER::new();
    $self->{$_} = $args{$_} for qw/user password/;
    $self->{dbs}{$_}++ for $self->list_dbs;
    $self->{users}{$_}++ for $self->list_users;
    return $self;
}

sub dbh {
    my $self = shift;
    return $self->{dbh} ||= DBI->connect(
        $self->dsn,
        $self->{user},
        $self->{password},
        {RaiseError => 1}
    );
}

sub clean {
    my $self = shift;
    my @dbs = grep !$self->{dbs}{ $_ }, $self->list_dbs;
    my @users = grep !$self->{users}{ $_ }, $self->list_users;
    return unless @dbs or @users;

    warn "DROP DATABASE $_\n" for @dbs;
    $self->dbh->do("DROP DATABASE $_") for @dbs;

    for (@users) {
        my $sql = $self->clean_user_sql($_);
        warn $sql;
        $self->dbh->do($sql);
    }
}

sub list_dbs { die "!!!\n" }
sub list_users { die "!!!\n" }
sub clean_user_sql { die "!!!\n" }

1;

