#!/bin/env perl
###############################################################################
#
# simple-telnetd.pl
#
###############################################################################

use strict;
use feature ':5.10';

use Data::Dumper;
use Log::Log4perl;
use Getopt::Long;
use POSIX qw( setsid WNOHANG );
use IO::Socket qw( $CRLF );
use YAML qw( LoadFile );

# PATH value when running as a daemon
use constant DAEMON_PATH => '/bin:/sbin:/usr/bin:/usr/sbin';

# Config file default location
use constant CONFIG_FILE => '/etc/simple-telnetd.conf';

# Listening network port
use constant PORT => 30000;

# Conenctions wait queue
use constant WAIT_QUEUE => 100;

# Connection timeout in seconds (defaults to 10 minutes)
use constant CONN_TIMEOUT => 600;

# Command timeout value in seconds (defaults to 5 minutes)
use constant CMD_TIMEOUT => 300;

# Logfile default location
use constant LOG_FILE => 'simple-telnetd.log';

# PID file default location
use constant PID_FILE => 'simple-telnetd.pid';

our %SIG;

my $script_name = $0;
$script_name =~ s/(\..*)$//;

my $quit_flag = 0;

# Parse options
my %options = ();
GetOptions(
    \%options,
    'help',
    'config:s',
    'port:i',
    'queue:i',
    'timeout:i',
    'cmdtimeout:i',
    'logfile:s',
    'pidfile:s',
    'daemon'
);

if ($options{help}) {
    print_usage();
    exit 0;
}

# Laod configuration from file
my $config_file = $options{config} || CONFIG_FILE;
my $config = load_config(config_file => $config_file);

# Override config options if we want to

foreach my $param (keys %options) {
    $config->{$param} = $options{$param};
}

# Validate config values

$config->{port} //= PORT;
die "$config->{port} value is below 1024\n" if ($config->{port} < 1024);
$config->{queue} //= WAIT_QUEUE;
$config->{timeout} //= CONN_TIMEOUT;
$config->{cmdtimeout} //= CMD_TIMEOUT;
$config->{logfile} //= LOG_FILE;
$config->{pidfile} //= PID_FILE;

# Initialize logger

my $logging_config = <<"LOGGING_CONFIG";
log4perl.logger.$script_name = DEBUG, ScreenAppender, FileAppender

log4perl.appender.ScreenAppender = Log::Log4perl::Appender::Screen
log4perl.appender.ScreenAppender.utf8 = 1
log4perl.appender.ScreenAppender.layout = Log::Log4perl::Layout::PatternLayout
log4perl.appender.ScreenAppender.layout.ConversionPattern = %d,%H,%P,%p,%c,%m%n

log4perl.appender.FileAppender = Log::Log4perl::Appender::File
log4perl.appender.FileAppender.filename = $config->{logfile}
log4perl.appender.FileAppender.autoflush = 1
log4perl.appender.FileAppender.layout = Log::Log4perl::Layout::PatternLayout
log4perl.appender.FileAppender.layout.ConversionPattern = %d,%H,%P,%p,%c,%m%n
LOGGING_CONFIG

Log::Log4perl::init(\$logging_config);
my $logger = Log::Log4perl->get_logger($script_name);
$logger->info(" --- $script_name started");

# Set signal handlers

$SIG{__DIE__} = sub {
    my $msg = shift;
    $logger->error($msg);
    die $msg;
};

$SIG{__WARN__} = sub {
    my $msg = shift;
    $logger->warn($msg);
    warn $msg;
};

$SIG{CHLD} = sub {
    while (waitpid(-1, WNOHANG) > 0) {}
};

# Re-read allowed_commands value from config file on SIGHUP
$SIG{HUP} = sub {
    $logger->info("Got SIGHUP, reloading allowed commands list . . .");
    my $new_config = load_config(config_file => $config_file);
    $config->{allowed_commands} = $new_config->{allowed_commands};
    $config->{allowed_commands_map} = $new_config->{allowed_commands_map};
    $logger->info("Allowed commands list reloaded");
};

$SIG{QUIT} = $SIG{INT} = $SIG{TERM} = sub {
    $quit_flag = 1;
};

# Switch to daemon mode if requested
if ($options{daemon}) {
    become_daemon();
    $logger->info('Running as a daemon');
}

# Create a listen sockect

my $listen_sock = IO::Socket::INET->new(
    LocalPort => $config->{port},
    Listen => $config->{queue},
    Proto => 'tcp',
    Timeout => $config->{timeout},
    Reuse => 1
);
die "Cannot create a listen socket! Reason: $@\n"
    unless defined $listen_sock;

$logger->info('Listening on port: ' . $config->{port});

# Main processing cycle

while (!$quit_flag) {
    my $client_sock = $listen_sock->accept();
    next unless defined $client_sock;

    my $child = fork();
    die "Cannot fork! Reason: $!\n" unless defined $child;

    if ($child > 0) {
        close $client_sock;

    } elsif ($child == 0) {
        process_request(client_sock => $client_sock);
        exit 0;
    }
}

# Done!
close $listen_sock;
if ($config->{daemon}) {
    unlink $config->{pidfile};
}
$logger->info('Bye!');

###############################################################################
#                           F U N C T I O N S
###############################################################################

#
# Load configuration from file
#

sub load_config {
    my %args = @_;
    my $config_file = $args{config_file} or
        die "config_file argument is missing\n";

    my $config = {};

    eval {
        $config = LoadFile($config_file);
    };
    if ($@) {
        die "Cannot load configuration from file $config_file!\nReason: $!\n";
    }

    # Check if we have allowed_commands specified in the config
    die "allowed_commands config value must be set!\n"
        unless exists $config->{allowed_commands};

    # Check that allowed_commands value is an array ref
    die "allowed_commands is not an ARRAY\n"
        unless (ref($config->{allowed_commands}) eq 'ARRAY');

    # Intialize allowed commands lookup hash
    $config->{allowed_commands_map} =
        { map { $_ => 1 } @{$config->{allowed_commands}} };

    return $config;
}

#
# Switch to daemon mode
#

sub become_daemon {
    my $child = fork();
    die "Cannot fork: $!" unless (defined $child);
    exit 0 if ($child);

    # Leaving previous process and session groups,
    # becoming new session/group leader
    setsid();

    # Re-opening STD* handles to /dev/null
    open(STDIN, '</dev/null');
    open(STDOUT, '>/dev/null');
    open(STDERR, '>&STDOUT');

    # Setting an explicit PATH
    $ENV{PATH} = DAEMON_PATH;

    # Resetting umask
    umask(0006);

    # Saving PID
    if ( -f $config->{pidfile} ) {
        my $fh = IO::File->new($config->{pidfile}, 'r') or
            die "Cannot open PID file $config->{pidfile} for reading!".
                " Reason: $!";
        my $saved_pid = $fh->getline();
        chomp($saved_pid);
        die "Cannot run as a daemon - " .
            "previous process still running, PID: $saved_pid ";

    } else {
        my $fh = IO::File->new($config->{pidfile}, 'w') or
            die "Cannot open PID file $config->{pidfile} for writing!".
                " Reason: $!";
        print $fh $$, "\n";
        close $fh;
    }

    # Done!
    return;
}

#
# Client request processing
#

sub process_request {
    my %args = @_;
    my $client_sock = $args{client_sock} or
        die "client_sock argument is required\n";

    $logger->info(sprintf("Connected, remote host %s",
        $client_sock->peerhost()));

    my $cmd = $client_sock->getline();
    $cmd =~ /^\s*(\S+)/;
    my $cmd_name = $1;
    unless (exists $config->{allowed_commands_map}{$cmd_name}) {
        my $msg = "Command is not allowed: $cmd_name";

        $logger->warn($msg);
        $logger->warn("Requested: $cmd");

        print $client_sock $msg, $CRLF;
        close $client_sock;

        exit 1;
    }

    $logger->info("Running command: $cmd");
    my $result = eval {
        local $SIG{ALRM} = sub { die "$cmd_name timed-out"; };
        alarm($config->{cmdtimeout});
        return `$cmd`;
    };
    alarm(0);
    $result = $@ if ($@ =~ /timed-out/);

    print $client_sock $result;
    close $client_sock;
}

#
# Print usage info
#

sub print_usage {
    print <<HELP;

    simple-telnetd.pl - A very basic restricted telnet server.

    Runs any command listed in configuration file, under allowed_commands key.

    Configuration paremeters can be supplied as command line options,
    except allowed commands list.

    Options:

        config     -  a config file to use instead of default /etc/simple-telnetd.conf

        port       - a port to listion on

        queue      - a size of incoming requests queue, waiting to be processed

        timeout    - a connection timeout value

        cmdtimeout - a command to run timeout value

        logfile    - a log file location

        pidfile    - PID file to use when running as a daemon

        daemon     - run as a daemon process

HELP
}

###############################################################################
#                                 E N D
###############################################################################
