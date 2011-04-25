#!perl

use Test::More tests => 1;

BEGIN {
    use_ok( 'Tyee::API' ) || print "Bail out!
";
}

diag( "Testing Tyee::API $Tyee::API::VERSION, Perl $], $^X" );
