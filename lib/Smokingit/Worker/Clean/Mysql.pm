use strict;
use warnings;

package Smokingit::Worker::Clean::Mysql;
use base 'Smokingit::Worker::Clean';
use DBI;

sub new {
    my $class = shift;
    my %args = (
        user => "root",
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
        "dbi:mysql:",
        $self->{user},
        $self->{password},
        {RaiseError => 1}
    );
    warn "DROP DATABASE $_\n" for @dbs;
    $dbh->do("DROP DATABASE $_") for @dbs;
}

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

