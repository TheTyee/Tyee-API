package Tyee::Config;

require Exporter;

our @ISA    = qw( Exporter );
our @EXPORT = qw( $config );

use strict;
use warnings;
use JSON;

=head1 NAME

Tyee::Config - Load/export configuration for Tyee module(s) from a JSON file

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

Expects a JSON file with configuration options like:

    { 
        "servers": "127.0.0.1:9200",
        "transport": "httplite",
        "timeout": 30,
        "index": "index-name",
        "domain": "http://domain.com",
        "cdn": "http://content-delivery-network.com"
    }

=cut

# Load config from JSON file
local $/;
open( my $fh, '<', '/var/home/tyee/lib/Tyee-API/config.json' ) or die $!;
my $json = <$fh>;
our $config = decode_json( $json );
1;
