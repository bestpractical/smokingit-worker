use strict;
use warnings;

package Smokingit::Worker;
use base 'Gearman::Worker';

use TAP::Harness;

use Gearman::Client;
use Storable qw( freeze thaw );
use YAML;

use Smokingit::Worker::Clean::TmpFiles;
use Smokingit::Worker::Clean::Postgres;

use fields qw(max_jobs repo_path client);

sub new {
    my $class = shift;
    my %args = (
        max_jobs => 5,
        @_,
    );
    my $self = $class->SUPER::new(%args);
    $self->{max_jobs} = $args{max_jobs};
    $self->{repo_path} = $args{repo_path};
    die "No valid repository path set!"
        unless $args{repo_path} and -d $args{repo_path};

    return $self;
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

sub client {
    my $self = shift;
    return $self->{client};
}

sub run {
    my $self = shift;
    chdir($self->repo_path);
    $self->register_function( run_tests => sub {$self->run_tests(@_)} );
    $self->{client} = Gearman::Client->new(
        job_servers => $self->job_servers,
    );
    $self->work while 1;
}

my %projects;

sub run_tests {
    my $self = shift;
    my $job = shift;
    my $request = @_ ? shift : thaw( $job->arg );
    my %ORIGINAL_ENV = %ENV;

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

    # Check the SHA and check it out
    warn "Now testing:\n";
    if (system("git", "rev-parse", "-q", "--verify", $sha)) {
        warn "No such SHA $sha in $project!\n";
        $result->{error} = "Can't find SHA";
        $self->client->do_task(post_results => freeze($result));
        chdir("..");
        return undef;
    }
    system("git", "clean", "-fxdq");
    system("git", "reset", "--hard", "HEAD", "--quiet");
    system("git", "checkout", "-q", $sha);

    # Set up the environment
    for my $line (split /\n/, $env) {
        $line =~ s/\s*$//;
        my ($var, $val) = split /\s*[:=\s]\s*/, $line, 2;
        warn "Setting $var=$val\n";
        $ENV{$var} = $val;
    }

    # Run configure
    if ($config =~ /\S/) {
        $config =~ s/\s*;?\s*\n+/ && /g;
        my $output = `($config) 2>&1`;
        my $ret = $?;
        if ($ret) {
            my $exit_val = $ret >> 8;
            warn "Return value of $config from $project = $exit_val\n$output\n";
            $result->{error} = "Configuration failed (exit value $exit_val)!\n\n"
                . $output;
            $self->client->do_task(post_results => freeze($result));

            system("git", "clean", "-fxdq");
            system("git", "reset", "--hard", "HEAD");
            chdir("..");
            return;
        }
    }

    # Set up initial state for cleaning purposes
    my @cleaners = map {"Smokingit::Worker::Clean::$_"->new}
        qw/TmpFiles Postgres Mysql/;

    # Run the tests
    my $done = 0;
    my @tests = glob($tests);
    my $harness = TAP::Harness->new( {
            jobs => $jobs,
            lib => [".", "lib"],
        } );
    $harness->callback(
        after_test => sub {
            $job->set_status(++$done,scalar(@tests));
        }
    );
    my $aggregator = do {
        # Runtests apparently grows PERL5LIB -- local it so it doesn't
        # grow without bound
        local $ENV{PERL5LIB} = $ENV{PERL5LIB};
        $harness->runtests(@tests);
    };

    # Shove back the frozen aggregator, stripping out the iterator
    # coderefs first
    $aggregator->{parser_for}{$_}{_iter} = undef
        for keys %{$aggregator->{parser_for}};
    $result->{aggregator} = $aggregator;
    $self->client->do_task(post_results => freeze($result))
        or die "Can't send task!";

    # Clean out
    system("git", "clean", "-fxdq");
    system("git", "reset", "--hard", "HEAD");
    $_->clean for @cleaners;
    chdir("..");
}

1;
