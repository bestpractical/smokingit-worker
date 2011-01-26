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
    return $self;
}

sub clean {
    my $self = shift;
    my @dbs = grep !$self->{dbs}{ $_ }, $self->list_dbs;
    return unless @dbs;

    my $dbh = DBI->connect(
        $self->dsn,
        $self->{user},
        $self->{password},
        {RaiseError => 1}
    );
    warn "DROP DATABASE $_\n" for @dbs;
    $dbh->do("DROP DATABASE $_") for @dbs;
}

sub list_dbs { die "!!!\n" }

1;

