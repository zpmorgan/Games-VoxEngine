#!perl -T

use Test::More tests => 1;

BEGIN {
	use_ok( 'Games::VoxEngine' );
}

diag( "Testing Games::VoxEngine $Games::VoxEngine::VERSION, Perl $], $^X" );
