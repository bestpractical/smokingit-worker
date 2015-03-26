package TAP::Harness::AnyEvent;

use strict;
use vars qw($VERSION @ISA);

use AnyEvent;
use AnyEvent::Util qw//;

use base 'TAP::Harness';

=head1 NAME

TAP::Harness::AnyEvent - AnyEvent-based TAP harness

=head1 VERSION

Version 1.0

=cut

$VERSION = 1.0;

=head1 DESCRIPTION

This provides a purely event-based alternative to L<TAP::Harness>, based
on L<AnyEvent>.

=head1 SYNOPSIS

    use TAP::Harness::AnyEvent;
    my $harness = TAP::Harness::AnyEvent->new( \%args );
    $harness->callback(
        after_runtests => sub { ... }
    );

    # This will return immediately:
    $harness->runtests(@tests);

This provides an alternative to L<TAP::Harness> which provides an
entirely non-blocking harness to run and capture test output.  It
leverages the existing L<TAP::Harness/callback> points to allow the
standard L</runtests> to return immediately; interaction with individual
results and aggregates is done via the C<after_test> and
C<after_runtests> callback points.

=head1 METHODS

=head2 Class Methods

=head3 C<new>

    my %args = (
       verbosity => 1,
       lib       => [ 'lib', 'blib/lib', 'blib/arch' ],
    );
    my $harness = TAP::Harness::AnyEvent->new( \%args );

The arguments are the same as for L<TAP::Harness/new>.  Under the hood,
it uses the L<TAP::Parser::Multiplexer::AnyEvent> class as its
L<TAP::Harness/multiplexer_class>.  Any C<multiplexer_class> which is
explicitly provided should behave similarly.

=cut

sub _initialize {
    my ($self, $args) = @_;
    $args->{multiplexer_class} ||= 'TAP::Parser::Multiplexer::AnyEvent';

    $self->SUPER::_initialize($args);
}

=head3 C<runtests>

    my $cv = $harness->runtests(@tests);

Unlike L<TAP::Harness>, this does not run tests and return a
L<TAP::Parser::Aggregator>; instead, it immediately returns a
L<condvar|AnyEvent/CONDITION VARIABLES> which will be called with a
L<TAP::Parser::Aggregator> when the tests are complete.

=cut

sub runtests {
    my ($self, @tests) = @_;

    my $aggregate = $self->_construct( $self->aggregator_class );
    $self->_make_callback( 'before_runtests', $aggregate );
    $aggregate->start;

    my $return = AnyEvent->condvar;
    my $done = $self->aggregate_tests( $aggregate, @tests );
    $done->cb(sub {
        $aggregate->stop;
        $self->summary( $aggregate );
        $self->_make_callback( 'after_runtests', $aggregate );
        $return->send( $aggregate );
    });

    return $return;
}

=head3 C<aggregate_tests>

    my $cv = $harness->aggregate_tests( $aggregate, @tests );

Runs tests in the given order, adding them to the
L<TAP::Parser::Aggregator> given.  Returns a condvar which will be
called with the aggregator when tests are complete.

=cut

sub aggregate_tests {
    my ( $self, $aggregate, @tests ) = @_;

    my $jobs      = $self->jobs;
    my $scheduler = $self->make_scheduler(@tests);

    local $ENV{HARNESS_IS_VERBOSE} = 1
      if $self->formatter->verbosity > 0;
    $self->formatter->prepare( map { $_->description } $scheduler->get_all );

    # Keep multiplexer topped up
    my $all_done = AnyEvent->condvar;
    $all_done->begin( sub { shift->send( $aggregate ) } );

    my $fill;
    my $mux  = $self->_construct(
        $self->multiplexer_class,
        sub {
            my ( $parser, $stash, $result ) = @_;
            my ( $session, $job ) = @$stash;
            if ( defined $result ) {
                $session->result($result);
                $self->_bailout($result) if $result->is_bailout;
            }
            else {
                # End of parser. Automatically removed from the mux.
                $self->finish_parser( $parser, $session );
                $self->_after_test( $aggregate, $job, $parser );
                $job->finish;

                # Top the MUX back off again -- before we complete this
                # task, so we don't finish prematurely
                $fill->();

                $all_done->end;
            }
        }
    );

    $fill = sub {
        while ( $mux->parsers < $jobs ) {
            my $job = $scheduler->get_job;

            # If we hit a spinner stop filling and start running.
            return if !defined $job || $job->is_spinner;

            $all_done->begin();
            my ( $parser, $session ) = $self->make_parser($job);
            $mux->add( $parser, [ $session, $job ] );
        }
    };

    $fill->();

    $all_done->end;
    return $all_done;
}

=head1 See Also

L<TAP::Harness::AnyEvent>

L<TAP::Parser::Multiplexer>

=cut

1;
