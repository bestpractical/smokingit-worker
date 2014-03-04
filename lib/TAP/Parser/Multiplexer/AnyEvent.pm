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

    my $mux = TAP::Parser::Multiplexer->new;
    $mux->add( $parser1, $stash1 );
    $mux->add( $parser2, $stash2 );
    while ( my ( $parser, $stash, $result ) = $mux->next ) {
        # Will block waiting for input from the parsers, but still
        # interact with other AnyEvent timers, etc
    }

=head1 DESCRIPTION

L<TAP::Parser::Multiplexer> gathers input from multiple TAP::Parsers;
this does so, but using AnyEvent as the main select loop.  A complete
rewrite of L<TAP::Harness> to be event-driven is too complex, so this
suffices to use the AnyEvent main loop for the main waiting-for-IO
portion of testing.

To use it, specify C<< multiplexer_class =>
'TAP::Parser::Multiplexer::AnyEvent' >> to the L<TAP::Harness>
constructor.  L<TAP::Harness/run_tests> will still block, but will be
able to service AnyEvent events during its main loop.

=head1 METHODS

=head2 Class Methods

=head3 C<new>

    my $mux = TAP::Parser::Multiplexer::AnyEvent->new;

Returns a new C<TAP::Parser::Multiplexer::AnyEvent> object.

=cut

# new() implementation supplied by TAP::Object

sub _initialize {
    my $self = shift;
    $self->{avid}    = [];                # Parsers that can't select
    $self->{return}  = [];
    $self->{handles} = [];
    $self->{count}   = 0;
    $self->{ready}   = AnyEvent->condvar;

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

    return $self;
}

##############################################################################

=head2 Instance Methods

=head3 C<add>

  $mux->add( $parser, $stash );

Add a TAP::Parser to the multiplexer. C<$stash> is an optional opaque
reference that will be returned from C<next> along with the parser and
the next result.

=cut

sub add {
    my ( $self, $parser, $stash ) = @_;

    my @handles = $parser->get_select_handles;
    unless (@handles) {
        push @{ $self->{avid} }, [ $parser, $stash ];
        return;
    }

    my $it = $parser->_iterator;
    $it->{done} = AnyEvent->condvar;
    $it->{done}->begin( sub {
        # Once _both_ exit code and reading-from-sockets is complete,
        # push the undef that signals "this job is done" and kick the
        # blocked ->recv in the iterator that reads the queue
        undef $it->{done};
        push @{ $self->{return} }, [ $parser, $stash, undef ];
        $self->{count}--;
        $self->{ready}->send;
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
        my $aeh; $aeh = AnyEvent->io(
            fh => $h,
            poll => "r",
            cb => sub {
                # If the filehandle has something to read, parse it
                my $result = $parser->next;
                if ($result) {
                    # Not EOF?  Push onto the queue, and notify the
                    # iterator that we just topped it off.
                    push @{ $self->{return} },
                        [ $parser, $stash, $result ];
                    $self->{ready}->send;
                } else {
                    # If this is the end of the line, remove the
                    # watcher.  We _don't_ push the "we're done" undef,
                    # because we need the exit code first.
                    undef $aeh;
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
    return $self->{count} + scalar @{ $self->{avid} };
}

sub _iter {
    my $self = shift;

    return sub {
        # Drain all the non-selectable parsers first
        if (@{ $self->{avid} } ) {
            my ( $parser, $stash ) = @{ $self->{avid}->[0] };
            my $result = $parser->next;
            shift @{$self->{avid}} unless defined $result;
            return ( $parser, $stash, $result );
        }

        # Block for the signal that we've got something to read
        while (not @{ $self->{return} } and $self->{count} ) {
            $self->{ready} = AnyEvent->condvar;
            $self->{ready}->recv;
        }

        if (@{ $self->{return} }) {
            my ($parser, $stash, $result) = @{ shift @{ $self->{return} } };
            return ( $parser, $stash, $result );
        }

        return unless $self->{count};
        die "No lines in the queue, but open handles?";
    };
}


=head3 C<next>

Return a result from the next available parser. Returns a list
containing the parser from which the result came, the stash that
corresponds with that parser and the result.

    my ( $parser, $stash, $result ) = $mux->next;

If C<$result> is undefined the corresponding parser has reached the end
of its input (and will automatically be removed from the multiplexer).

When all parsers are exhausted an empty list will be returned.

    if ( my ( $parser, $stash, $result ) = $mux->next ) {
        if ( ! defined $result ) {
            # End of this parser
        }
        else {
            # Process result
        }
    }
    else {
        # All parsers finished
    }

=cut

sub next {
    my $self = shift;
    return ($self->{_iter} ||= $self->_iter)->();
}

=head1 See Also

L<TAP::Parser>

L<TAP::Harness>

=cut

1;
