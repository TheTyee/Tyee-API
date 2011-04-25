#!/usr/bin/perl 
#===============================================================================
#
#         FILE:  tyee-api-story.pl
#
#        USAGE:  ./tyee-api-story.pl --options --[insert|delete]
#
#  DESCRIPTION:  Index stories from Bricolage to ElasticSearch
#
#      OPTIONS:  ---
# REQUIREMENTS:  ---
#       AUTHOR:  The Tyee (api AT thetyee DOT ca)
#      VERSION:  1.0
#      CREATED:  20/11/2010 18:02:57
#===============================================================================

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Tyee::API;

use Data::Dumper;
use DateTime;
use Getopt::Long;
use Pod::Usage;
use utf8;

GetOptions(
    "story_id=i"       => \my $story_id,
    "active=i"         => \my $active,
    "publish_status=i" => \my $publish_status,
    "unexpired=i"      => \my $unexpired,
    "date_start=s"     => \my $date_start,
    "date_end=s"       => \my $date_end,
    "expired_end=s"    => \my $expired_end,
    "expired=i"        => \my $expired,
    "insert"           => \my $insert,
    "delete"           => \my $delete,
    "debug"            => \my $debug,
);

my $result;
my $type = 'Story';
my $stories;
my $dt = DateTime->now;

# How Bricolage likes dates: 2011-03-26T12:59:59Z
my $today = $dt->ymd . 'T' . $dt->hms . 'Z';

my $params = [
    ( $story_id       ? ( id               => $story_id )   : () ),
    ( $date_start     ? ( cover_date_start => $date_start ) : () ),
    ( $date_end       ? ( cover_date_end   => $date_end )   : () ),
    ( defined $active ? ( active           => $active )     : () ),
    ( defined $publish_status ? ( publish_status  => $publish_status ) : () ),
    ( defined $unexpired      ? ( unexpired       => $unexpired )      : () ),
    ( $expired_end            ? ( expire_date_end => $expired_end )    : () ),
    ( $expired                ? ( expire_date_end => $today )          : () ),
];

print 'The supplied params to Tyee::API::Story-list were: '
    . Dumper( $params )
    if $debug;

if ( @$params > 0 ) {
    $stories = Tyee::API::Story->list( $params );
    print "Tyee::API::Story->list returned: " . @{$stories} . "\n" if $debug;
    if ( $stories && $insert ) {
        print "Inserting stories...\n\n" if $debug;

        # Loop because it's a memory hog
        for my $story ( @{$stories} ) {
            $result = Tyee::API->create( $type, [$story] );
            print Dumper( $result ) if $debug;
        }
    }
    elsif ( $stories && $delete ) {
        print "Deleting stories..." if $debug;
        $result = Tyee::API->delete( $type, $stories );
        print Dumper( $result ) if $debug;
    }
}
# TODO Actually print out the (non-existent) docs for this script
#      if parameters are missing. 
else { print "Not enough params provided\n" }
