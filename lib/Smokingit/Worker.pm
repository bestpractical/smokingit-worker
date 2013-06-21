use strict;
use warnings;

package Smokingit::Worker;
use base 'AnyEvent::RabbitMQ::RPC';

use AnyMQ;

use TAP::Harness;
use Storable qw( nfreeze thaw );
use YAML;

use Smokingit::Worker::Clean::TmpFiles;
use Smokingit::Worker::Clean::Postgres;
use Smokingit::Worker::Clean::Mysql;

sub new {
    my $class = shift;
    my %args = (
        max_jobs => 5,
        serialize => 'Storable',
        @_,
    );
    my $pubsub = AnyMQ->new_with_traits(
        exchange => 'events',
        %args,
        traits => ['AMQP'],
    );
    my $self = $class->SUPER::new(
        connection => $pubsub->_rf,
        %args,
    );
    $self->{pubsub} = $pubsub;
    $self->{max_jobs} = $args{max_jobs};
    $self->{repo_path} = $args{repo_path};
    die "No valid repository path set!"
        unless $args{repo_path} and -d $args{repo_path};

    return $self;
}

sub publish {
    my $self = shift;
    my (%msg) = @_;
    $msg{type} = "worker_progress";
    $self->{pubsub}->topic($msg{type})->publish(\%msg);
}

sub repo_path {
    my $self = shift;
    return $self->{repo_path} unless @_;
    $self->{repo_path} = shift;
}

sub max_jobs {
    my $self = shift;
    return $self->{max_jobs} unless @_;
    $self->{max_jobs} = shift || 1;
}

sub run {
    my $self = shift;
    chdir($self->repo_path);
    $self->register(
        name => "run_tests",
        run  => sub {$self->run_tests(@_)},
    );
    AE::cv->recv;
}

my %projects;

sub run_tests {
    my $self = shift;
    my $request = shift;
    my %ORIGINAL_ENV = %ENV;

    $self->publish(
        smoke_id => $request->{smoke_id},
        status   => "started",
    );

    # Read data out of the hash they passed in
    my $project = $request->{project};
    my $url     = $request->{repository_url};
    my $sha     = $request->{sha};
    my $config  = $request->{configure_cmd} || '';
    my $env     = $request->{env} || '';
    my $jobs    = $request->{parallel} ? $self->max_jobs : 1;
    my $tests   = $request->{test_glob} || 't/*.t';

    my $result = { smoke_id => $request->{smoke_id} };

    # Clone ourselves a copy if need be
    if (-d $project) {
        warn "Updating $project\n";
        chdir($project);
        system("git", "remote", "update");
    } else {
        warn "Cloning $project\n";
        system("git", "clone", "--quiet", $url, $project);
        chdir($project);
    }

    # Set up initial state for cleaning purposes
    my @cleaners = map {"Smokingit::Worker::Clean::$_"->new}
        qw/TmpFiles Postgres Mysql/;
    # Closures for cleanup and error handling
    my $cleanup = sub {
        system("git", "clean", "-fxdq");
        system("git", "reset", "--hard", "HEAD");
        $_->clean for @cleaners;
        chdir("..");
        %ENV = %ORIGINAL_ENV;
        return undef;
    };
    my $error = sub {
        $result->{error} = shift;
        warn $result->{error} . "\n";
        $self->call(
            name => "post_results",
            args => $result
        );
        $cleanup->();
    };

    # Check the SHA and check it out
    warn "Now testing:\n";
    !system("git", "rev-parse", "-q", "--verify", $sha)
        or return $error->("Can't find SHA $sha in $project!");
    system("git", "clean", "-fxdq");
    system("git", "reset", "--hard", "HEAD", "--quiet");
    system("git", "checkout", "-q", $sha);

    # Default perl-related environment vars
    $ENV{PERL_MM_USE_DEFAULT}=1;
    $ENV{PERL_AUTOINSTALL}="--alldeps";

    # Set up the environment
    for my $line (split /\n/, $env) {
        $line =~ s/\s*$//;
        my ($var, $val) = split /\s*[:=\s]\s*/, $line, 2;
        warn "Setting $var=$val\n";
        $ENV{$var} = $val;
    }

    # Run configure
    if ($config =~ /\S/) {
        $self->publish(
            smoke_id => $request->{smoke_id},
            status   => "configuring",
        );
        $config =~ s/\s*;?\s*\n+/ && /g;
        my $output = `($config) 2>&1`;
        my $ret = $?;
        my $exit_val = $ret >> 8;
        return $error->("Configuration failed (exit value $exit_val)!\n\n" . $output)
            if $ret;
    }


    # Progress indicator via Gearman
    my $done = 0;
    my @tests = glob($tests);
    my $harness = TAP::Harness->new( {
            jobs => $jobs,
            lib => [".", "lib"],
            switches => "-w",
        } );

    $self->publish(
        smoke_id => $request->{smoke_id},
        status   => "testing",
        complete => $done,
        total    => scalar(@tests),
    );
    $harness->callback(
        after_test => sub {
            my ($job, $parser) = @_;
            my $filename = $job->[0];
            $result->{test}{$filename}{is_ok} = not $parser->has_problems;
            $result->{test}{$filename}{tests_run} = $parser->tests_run;
            $result->{test}{$filename}{elapsed}
                = $parser->end_time - $parser->start_time;
            $result->{start} ||= $parser->start_time;
            $result->{end}     = $parser->end_time;
            $self->publish(
                smoke_id => $request->{smoke_id},
                status   => "testing",
                complete => ++$done,
                total    => scalar(@tests),
            );
        }
    );
    $harness->callback(
        parser_args => sub {
            my ($args, $job) = @_;
            my $filename = $job->[0];
            $result->{test}{$filename}{raw_tap} = "";
            open($args->{spool}, ">", \$result->{test}{$filename}{raw_tap});
        }
    );
    my $aggregator = eval {
        # Runtests apparently grows PERL5LIB -- local it so it doesn't
        # grow without bound
        local $ENV{PERL5LIB} = $ENV{PERL5LIB};
        $harness->runtests(@tests);
    } or return $error->("Testing bailed out!\n\n$@");
    $result->{is_ok} = not $aggregator->has_problems;
    $result->{elapsed} = $result->{end} - $result->{start};
    $result->{$_} = $aggregator->$_ for
        qw/failed
           parse_errors
           passed
           planned
           skipped
           todo
           todo_passed
           total
           wait
           exit
          /;

    $self->call(
        name => "post_results",
        args => $result,
    );

    # Clean out
    $cleanup->();
    return 1;
}

1;
