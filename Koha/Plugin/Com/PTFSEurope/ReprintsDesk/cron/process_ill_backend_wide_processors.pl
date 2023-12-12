#!/usr/bin/perl

# This file is part of Koha.
#
# Copyright (C) 2022 PTFS Europe
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;
use Getopt::Long qw( GetOptions );

use Koha::Script;
use Koha::Illrequests;

# Command line option values
my $get_help = 0;
my $backend = "";
my $dry_run = 0;
my $debug = 0;
my $env = "dev";
my $processor = "";

my $options = GetOptions(
    'h|help'            => \$get_help,
    'backend=s'         => \$backend,
    'dry-run'           => \$dry_run,
    'debug'             => \$debug,
    'env=s'             => \$env,
    'processor:s'       => \$processor
);

if ($get_help) {
    get_help();
    exit 1;
}

if (!$backend) {
    print "No backend specified\n";
    exit 0;
}

# First check we can proceed
my $cfg = Koha::Illrequest::Config->new;
my $backends = $cfg->available_backends;
my $has_branch = $cfg->has_branch;
my $backends_available = ( scalar @{$backends} > 0 );
if (!$has_branch || $backends_available == 0) {
    print "Unable to proceed:\n";
    print "Branch configured: $has_branch\n";
    print "Backends available: $backends_available\n";
    exit 0;
}

my $where = {
    backend => $backend
};

debug_msg("DBIC WHERE:");
debug_msg($where);

# Create an options hashref to pass to processors
my $options_to_pass = {
    dry_run         => $dry_run,
    debug           => \&debug_msg,
    env             => $env
};

# Load the backend
my @raw = qw/Koha Illbackends/; # Base Path
my $location = join "/", @raw, $backend, "Base.pm";    # File to load
my $backend_class = join "::", @raw, $backend, "Base"; # Package name

require $location;

$backend = $backend_class->new;

# Backend processor specified, run only this processor
if( $processor ) {
    my @backend_proc = map { $_->{name} eq $processor ? $_ : () } @{$backend->{backend_wide_processors}};
    my $backend_proc = $backend_proc[0];
    if ( $backend_proc ) {
        debug_msg("Running backend wide processor: " . $backend_proc->{name});
        $backend_proc->run(undef, $options_to_pass);
    } else {
        print "Specified processor name " . $processor . " not found in backend " . $backend->name. ".\n";
    }
# No backend_wide_processor specified, iterate and run each
} else {
    foreach my $backend_processor(@{$backend->{backend_wide_processors}}) {
        debug_msg("- Processor " . $backend_processor->{name});
        $backend_processor->run(undef, $options_to_pass);
    }
}

sub debug_msg {
    my ( $msg ) = @_;

    if (!$debug) {
        return;
    }

    if (ref $msg eq 'HASH') {
        use Data::Dumper;
        $msg = Dumper $msg;
    }
    print STDERR "$msg\n";
}

sub get_help {
    print <<"HELP";
$0: Process backend-wide ILL processors

This script will run backend-wide processors provided by the Backend.
Example: the ReprintsDesk backend provides a processor script
that queries the supplier for the most recent 100 orders and acts 
upon the response.

Parameters:
    --backend                            name of the backend being used, required
    --processor                          name of the backend-wide processor to run exclusively
    --dry-run                            only produce a run report, without actually doing anything permanent
    --debug                              print additional debugging info during run
    --env                                prod/dev - defaults to dev if not specified

    --help or -h                         get help
HELP
}
