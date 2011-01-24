use strict;
use warnings;

package Smokingit::Worker::Clean::TmpFiles;
use base 'Smokingit::Worker::Clean';

use constant TMPDIRS => [qw{/tmp /var/tmp}];
use File::Find;

sub new {
    my $class = shift;
    my $self = $class->SUPER::new();
    $self->{files}{$_}++ for $self->file_list;
    return $self;
}

sub clean {
    my $self = shift;
    my @destroy = grep !$self->{files}{$_}, file_list();
    for (@destroy) {
        if (-d $_) {
            warn "RMDIR $_\n";
            rmdir($_) or warn "Can't rmdir $_: $!";
        } else {
            warn "UNLINK $_\n";
            unlink($_) or warn "Can't unlink $_: $!";
        }
    }
}

sub file_list {
    my %open;
    # Find all the open files under /tmp
    $open{$_}++ for map {s/^n//;$_} grep {/^n(.*)/}
        split /\n/, `lsof +D @{+TMPDIRS} -F 'n' 2>/dev/null`;

    for my $file (keys %open) {
        # Add the parent dirs, as well
        $open{$file}++ while $file ne "/" and $file =~ s{/[^/]+$}{};
    }

    my @found;
    finddepth(
        {
            preprocess => sub {
                # Skip directories which had open files in them
                return grep {-w $_ and not $open{$File::Find::dir."/".$_}} @_;
            },
            wanted => sub {
                # Everything else gets listed
                push @found, $File::Find::name;
            }
        },
        @{+TMPDIRS}
    );
    return @found;
}

1;
