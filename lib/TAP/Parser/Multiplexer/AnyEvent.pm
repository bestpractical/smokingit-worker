package TAP::Parser::Multiplexer::AnyEvent;

use strict;
use vars qw($VERSION @ISA);

use TAP::Object ();
use AnyEvent;
use AnyEvent::Util qw//;

@ISA = 'TAP::Object';

=head1 NAME

TAP::Parser::Multiplexer::AnyEvent - AnyEvent-based multiplexer for TAP

=head1 VERSION

Version 1.0

=cut

$VERSION = '1.0';

=head1 SYNOPSIS

    use TAP::Parser::Multiplexer::AnyEvent;

    my $mux = TAP::Parser::Multiplexer->new(
        sub { ... }
    );
    $mux->add( $parser1, $stash1 );
    $mux->add( $parser2, $stash2 );

=head1 DESCRIPTION

L<TAP::Parser::Multiplexer> gathers input from multiple TAP::Parsers;
this does so, but using AnyEvent as the main select loop.  Results from
the parsers will be passed to the subroutine.

As it does not use the same C</next> interface as
L<TAP::Parser::Multiplexer>, it is only usable by
L<TAP::Harness::AnyEvent>.

=head1 METHODS

=head2 Class Methods

=head3 C<new>

    my $mux = TAP::Parser::Multiplexer::AnyEvent->new(
        sub { ... }
    );

Returns a new C<TAP::Parser::Multiplexer::AnyEvent> object.  The
subroutine reference is a callback, which will be called for every
result the multiplexer finds.  The subroutine will be called with three
arguments -- the L<TAP::Parser> object, the stash from when the parser
was added to the multiplexer, and the L<TAP::Parser::Result>.

=cut

# new() implementation supplied by TAP::Object

sub _initialize {
    my $self = shift;
    $self->{count}   = 0;

    # AnyEvent futzes with SIGCHLD.  We split the former _finish method
    # of TAP::Parser::Iterator::Process into two parts -- the exit-code
    # part, and the closing-sockets part.  The latter lies in _finish,
    # the former is installed per-child using L<AnyEvent/child>.
    {
        no warnings 'redefine';
        require TAP::Parser::Iterator::Process;
        *TAP::Parser::Iterator::Process::_finish = sub {
            my $self = shift;
            $self->{_next} = sub {return};
            ( delete $self->{out} )->close;
            ( delete $self->{err} )->close if $self->{sel};
            delete $self->{sel} if $self->{sel};
            $self->{teardown}->() if $self->{teardown};
            $self->{done}->end;
        }
    }

    $self->{on_result} = shift;

    return $self;
}

##############################################################################

=head2 Instance Methods

=head3 C<add>

  $mux->add( $parser, $stash );

Add a TAP::Parser to the multiplexer. C<$stash> is an optional opaque
reference that will be passed to the callback, along with the parser and
the next result.

=cut

sub add {
    my ( $self, $parser, $stash ) = @_;

    my @handles = $parser->get_select_handles;
    unless (@handles) {
        $self->{count}++;
        # We don't want to parse it _now_, as we expect ->add() to be
        # fast.  Rather, postpone it so we deal with it the next chance
        # we hit the event loop.
        AnyEvent::postpone {
            while (1) {
                my $result = $parser->next;
                if ($result) {
                    $self->{on_result}->( $parser, $stash, $result );
                } else {
                    $self->{count}--;
                    $self->{on_result}->( $parser, $stash, undef );
                    return;
                }
            }
        };
        return;
    }

    my $it = $parser->_iterator;
    $it->{done} = AnyEvent->condvar;
    $it->{done}->begin( sub {
        # Once we have all of the exit code (below), parsing from
        # sockets (below that), and closing of sockets (above), send the
        # undef that signals this test is done.
        undef $it->{done};
        $self->{count}--;
        $self->{on_result}->( $parser, $stash, undef );
    } );

    if ($parser->_iterator->{pid}) {
        # Add a SIGCHLD watcher that gets the exit code.
        $it->{done}->begin;
        my $watch; $watch = AnyEvent->child(
            pid => $it->{pid},
            cb  => sub {
                my ($pid, $status) = @_;
                undef $watch;
                $it->{wait} = $status;
                $it->{exit} = $it->_wait2exit($status);
                $it->{done}->end;
            },
        );
    }

    for my $h (@handles) {
        $it->{done}->begin;
        my $aeh; $aeh = AnyEvent->io(
            fh => $h,
            poll => "r",
            cb => sub {
                # If the filehandle has something to read, parse it
                my $result = $parser->next;
                if ($result) {
                    # Not EOF?  Return it.
                    $self->{on_result}->( $parser, $stash, $result );
                } else {
                    # If this is the end of the line, remove the
                    # watcher.  Pushing the undef is done once all parts
                    # of ->{done} are complete.
                    undef $aeh;
                    $it->{done}->end;
                }
            },
        );
    }
    $self->{count}++;
}

=head3 C<parsers>

  my $count   = $mux->parsers;

Returns the number of parsers. Parsers are removed from the multiplexer
when their input is exhausted.

=cut

sub parsers {
    my $self = shift;
    return $self->{count};
}

=head3 C<next>

Exists to error if this classes is attempted to be used like a drop-in
replacement for L<TAP::Parser::Multiplexer>.

=cut

sub next {
    die "TAP::Parser::Multiplexer::AnyEvent can only be used by TAP::Harness::AnyEvent";
}

=head1 See Also

L<TAP::Harness::AnyEvent>

L<TAP::Parser::Multiplexer>

=cut

1;
