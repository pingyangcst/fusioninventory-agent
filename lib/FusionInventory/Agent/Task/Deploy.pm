package FusionInventory::Agent::Task::Deploy;

# Full protocol documentation available here:
#  http://fusioninventory.org/documentation/dev/spec/protocol/deploy.html

use strict;
use warnings;
use base 'FusionInventory::Agent::Task';

use FusionInventory::Agent::HTTP::Client::Fusion;
use FusionInventory::Agent::Storage;
use FusionInventory::Agent::Task::Deploy::ActionProcessor;
use FusionInventory::Agent::Task::Deploy::CheckProcessor;
use FusionInventory::Agent::Task::Deploy::Datastore;
use FusionInventory::Agent::Task::Deploy::File;
use FusionInventory::Agent::Task::Deploy::Job;

use FusionInventory::Agent::Task::Deploy::Version;

our $VERSION = FusionInventory::Agent::Task::Deploy::Version::VERSION;

sub isEnabled {
    my ($self) = @_;

    if (!$self->{target}->isa('FusionInventory::Agent::Target::Server')) {
        $self->{logger}->debug("Deploy task not compatible with local target");
        return;
    }

    return 1;
}

sub _validateAnswer {
    my ($msgRef, $answer) = @_;

    $$msgRef = "";

    if (!defined($answer)) {
        $$msgRef = "No answer from server.";
        return;
    }

    if (ref($answer) ne 'HASH') {
        $$msgRef = "Bad answer from server. Not a hash reference.";
        return;
    }

    if (!defined($answer->{associatedFiles})) {
        $$msgRef = "missing associatedFiles key";
        return;
    }

    if (ref($answer->{associatedFiles}) ne 'HASH') {
        $$msgRef = "associatedFiles should be an hash";
        return;
    }
    foreach my $k (keys %{$answer->{associatedFiles}}) {
        foreach (qw/mirrors multiparts name p2p-retention-duration p2p uncompress/) {
            if (!defined($answer->{associatedFiles}->{$k}->{$_})) {
                $$msgRef = "Missing key `$_' in associatedFiles";
                return;
            }
        }
    }
    foreach my $job (@{$answer->{jobs}}) {
        foreach (qw/uuid associatedFiles actions checks/) {
            if (!defined($job->{$_})) {
                $$msgRef = "Missing key `$_' in jobs";
                return;
            }

            if (ref($job->{actions}) ne 'ARRAY') {
                $$msgRef = "jobs/actions must be an array";
                return;
            }
        }
    }

    return 1;
}

sub _setStatus {
    my ($self, %params) = @_;

    return unless $self->{_remoreUrl};

    my $job = $params{job}
        or return;

    # Base action hash we wan't to send back to server as job status
    my $action ={
        action      => "setStatus",
        machineid   => $self->{deviceid},
        part        => 'job',
        uuid        => $job->{uuid},
    };

    # Specific case where we want to send a file status
    if (exists($params{file}) && $params{file}) {
        $action->{part}   = 'file';
        $action->{sha512} = $params{file}->{sha512};
    }

    # Map other optional and set params to action
    map { $action->{$_} = $params{$_} }
        grep { exists($params{$_}) && $params{$_} } qw(
            currentStep status actionnum cheknum msg
    );

    # Send back the job status
    $self->{client}->send(
        url  => $self->{_remoreUrl},
        args => $action
    );
}

sub processRemote {
    my ($self, $remoteUrl) = @_;

    $self->{_remoreUrl} = $remoteUrl
        or return;

    my $datastore = FusionInventory::Agent::Task::Deploy::Datastore->new(
        path => $self->{target}{storage}{directory}.'/deploy',
        logger => $self->{logger}
    );
    $datastore->cleanUp();

    my $jobList = [];
    my $files;
    my $logger = $self->{logger};

    my $answer = $self->{client}->send(
        url  => $remoteUrl,
        args => {
            action    => "getJobs",
            machineid => $self->{deviceid},
            version   => $VERSION
        }
    );

    if (ref($answer) eq 'HASH' && !keys %$answer) {
        $self->{logger}->debug("Nothing to do");
        return 0;
    }

    my $msg;
    if (!_validateAnswer(\$msg, $answer)) {
        $self->{logger}->debug("bad JSON: ".$msg);
        return 0;
    }

    foreach my $sha512 ( keys %{ $answer->{associatedFiles} } ) {
        $files->{$sha512} = FusionInventory::Agent::Task::Deploy::File->new(
            client    => $self->{client},
            sha512    => $sha512,
            data      => $answer->{associatedFiles}{$sha512},
            datastore => $datastore,
            logger    => $self->{logger}
        );
    }

    foreach my $job ( @{ $answer->{jobs} } ) {
        my $associatedFiles = [];
        if ( $job->{associatedFiles} ) {
            foreach my $uuid ( @{ $job->{associatedFiles} } ) {
                if ( !$files->{$uuid} ) {
                    $logger->error("unknown file: '$uuid'. Not found in JSON answer!");
                    next;
                }
                push @$associatedFiles, $files->{$uuid};
            }
            if (@$associatedFiles != @{$job->{associatedFiles}}) {
                $logger->error("Bad job definition in JSON answer!");
                next;
            }
        }

        push @$jobList, FusionInventory::Agent::Task::Deploy::Job->new(
            data            => $job,
            associatedFiles => $associatedFiles,
        );
    }

  JOB: foreach my $job (@$jobList) {

        # RECEIVED
        $self->_setStatus(
            job         => $job,
            currentStep => 'checking',
            msg         => 'starting'
        );

        # CHECKING
        if ( ref( $job->{checks} ) eq 'ARRAY' ) {
            foreach my $checknum ( 0 .. @{ $job->{checks} } ) {
                next unless $job->{checks}[$checknum];
                my $checkStatus = FusionInventory::Agent::Task::Deploy::CheckProcessor->process(
                    check => $job->{checks}[$checknum],
                    logger => $self->{logger}
                );
                next if $checkStatus eq "ok";
                next if $checkStatus eq "ignore";

                $self->_setStatus(
                    job         => $job,
                    currentStep => 'checking',
                    status      => 'ko',
                    msg         => "failure of check #".($checknum+1)." ($checkStatus)",
                    cheknum     => $checknum
                );

                next JOB;
            }
        }

        $self->_setStatus(
            job         => $job,
            currentStep => 'checking',
            status      => 'ok',
            msg         => 'all checks are ok'
        );


        # DOWNLOADING

        $self->_setStatus(
            job         => $job,
            currentStep => 'downloading',
            msg         => 'downloading files'
        );

        my $retry = 5;
        my $workdir = $datastore->createWorkDir( $job->{uuid} );
        FETCHFILE: foreach my $file ( @{ $job->{associatedFiles} } ) {

            # File exists, no need to download
            if ( $file->filePartsExists() ) {
                $self->_setStatus(
                    job         => $job,
                    file        => $file,
                    status      => 'ok',
                    currentStep => 'downloading',
                    msg         => $file->{name}.' already downloaded'
                );

                $workdir->addFile($file);
                next;
            }

            # File doesn't exist, lets try or retry a download
            $self->_setStatus(
                job         => $job,
                file        => $file,
                currentStep => 'downloading',
                msg         => 'fetching '.$file->{name}
            );

            $file->download();

            # Are all the fileparts here?
            my $downloadIsOK = $file->filePartsExists();

            if ( $downloadIsOK ) {

                $self->_setStatus(
                    job         => $job,
                    file        => $file,
                    currentStep => 'downloading',
                    status      => 'ok',
                    msg         => $file->{name}.' downloaded'
                );

                $workdir->addFile($file);
                next;
            }

            # Retry the download 5 times in a row and then give up
            if ( !$downloadIsOK ) {

                if ($retry--) { # Retry
# OK, retry!
                    $self->_setStatus(
                        job         => $job,
                        file        => $file,
                        currentStep => 'downloading',
                        msg         => 'retrying '.$file->{name}
                    );

                    redo FETCHFILE;
                } else { # Give up...

                    $self->_setStatus(
                        job         => $job,
                        file        => $file,
                        currentStep => 'downloading',
                        status      => 'ko',
                        msg         => $file->{name}.' download failed'
                    );

                    next JOB;
                }
            }

        }


        $self->_setStatus(
            job         => $job,
            currentStep => 'downloading',
            status      => 'ok',
            msg         => 'success'
        );

        if (!$workdir->prepare()) {
            $self->_setStatus(
                job         => $job,
                currentStep => 'prepare',
                status      => 'ko',
                msg         => 'failed to prepare work dir'
            );
            next JOB;
        } else {
            $self->_setStatus(
                job         => $job,
                currentStep => 'prepare',
                status      => 'ok',
                msg         => 'success'
            );
        }

        # PROCESSING
        my $actionProcessor =
          FusionInventory::Agent::Task::Deploy::ActionProcessor->new(
            workdir => $workdir
        );
        my $actionnum = 0;
        ACTION: while ( my $action = $job->getNextToProcess() ) {
        my ($actionName, $params) = %$action;
            if ( $params && (ref( $params->{checks} ) eq 'ARRAY') ) {
                foreach my $checknum ( 0 .. @{ $params->{checks} } ) {
                    next unless $job->{checks}[$checknum];
                    my $checkStatus = FusionInventory::Agent::Task::Deploy::CheckProcessor->process(
                        check => $params->{checks}[$checknum],
                        logger => $self->{logger}

                    );
                    if ( $checkStatus ne 'ok') {

                        $self->_setStatus(
                            job         => $job,
                            currentStep => 'checking',
                            status      => $checkStatus,
                            msg         => "failure of check #".($checknum+1)." ($checkStatus)",
                            actionnum   => $actionnum,
                            cheknum     => $checknum
                        );

                        next ACTION;
                    }
                }
            }


            my $ret;
            eval { $ret = $actionProcessor->process($actionName, $params, $self->{logger}); };
            $ret->{msg} = [] unless $ret->{msg};
            push @{$ret->{msg}}, $@ if $@;
            if ( !$ret->{status} ) {
                $self->_setStatus(
                    job       => $job,
                    msg       => $ret->{msg},
                    actionnum => $actionnum,
                );

                $self->_setStatus(
                    job         => $job,
                    currentStep => 'processing',
                    status      => 'ko',
                    actionnum   => $actionnum,
                    msg         => "action #".($actionnum+1)." processing failure"
                );

                next JOB;
            }
            $self->_setStatus(
                job         => $job,
                currentStep => 'processing',
                status      => 'ok',
                actionnum   => $actionnum,
                msg         => "action #".($actionnum+1)." processing success"
            );

            $actionnum++;
        }

        $self->_setStatus(
            job    => $job,
            status => 'ok',
            msg    => "job successfully completed"
        );
    }

    $datastore->cleanUp();

    return @$jobList ? 1 : 0 ;
}


sub run {
    my ($self, %params) = @_;

    # Turn off localised output for commands
    $ENV{LC_ALL} = 'C'; # Turn off localised output for commands
    $ENV{LANG} = 'C'; # Turn off localised output for commands

    $self->{client} = FusionInventory::Agent::HTTP::Client::Fusion->new(
        logger       => $self->{logger},
        user         => $params{user},
        password     => $params{password},
        proxy        => $params{proxy},
        ca_cert_file => $params{ca_cert_file},
        ca_cert_dir  => $params{ca_cert_dir},
        no_ssl_check => $params{no_ssl_check},
        debug        => $self->{debug}
    );

    my $globalRemoteConfig = $self->{client}->send(
        url  => $self->{target}->{url},
        args => {
            action    => "getConfig",
            machineid => $self->{deviceid},
            task      => { Deploy => $VERSION },
        }
    );

    if (!$globalRemoteConfig->{schedule}) {
        $self->{logger}->info("No job schedule returned from server at ".$self->{target}->{url});
        return;
    }
    if (ref( $globalRemoteConfig->{schedule} ) ne 'ARRAY') {
        $self->{logger}->info("Malformed schedule from server at ".$self->{target}->{url});
        return;
    }
    if ( !@{$globalRemoteConfig->{schedule}} ) {
        $self->{logger}->info("No Deploy job enabled or Deploy support disabled server side.");
        return;
    }

    my $run_jobs = 0;
    foreach my $job ( @{ $globalRemoteConfig->{schedule} } ) {
        next unless $job->{task} eq "Deploy";
        $run_jobs += $self->processRemote($job->{remote});
    }

    if ( !$run_jobs ) {
        $self->{logger}->info("No Deploy job found in server jobs list.");
        return;
    }

    return 1;
}

__END__

=head1 NAME

FusionInventory::Agent::Task::Deploy - Software deployment support for FusionInventory Agent

=head1 DESCRIPTION

With this module, F<FusionInventory> can accept software deployment
request from an GLPI server with the FusionInventory plugin.

This module uses SSL certificat to authentificat the server. You may have
to point F<--ca-cert-file> or F<--ca-cert-dir> to your public certificat.

If the P2P option is turned on, the agent will looks for peer in its network. The network size will be limited at 255 machines.

=head1 FUNCTIONS

=head2 isEnabled ( $self )

Returns true if the task is enabled.

=head2 processRemote ( $self, $remoteUrl )

Process orders from a remote server.

=head2 run ( $self, %params )

Run the task.
