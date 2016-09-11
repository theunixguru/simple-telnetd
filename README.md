
simple-telnetd
==============

A very simple telnetd written in Perl. Listens and remote executes one of the allowed commands.

Configuration paremeters can be supplied as command line options,
except allowed commands list.

Options
-------

    config     -  a config file to use instead of default /etc/simple-telnetd.conf

    port       - a port to listion on

    queue      - a size of incoming requests queue, waiting to be processed

    timeout    - a connection timeout value

    cmdtimeout - a command to run timeout value

    logfile    - a log file location

    pidfile    - PID file to use when running as a daemon

    daemon     - run as a daemon process

