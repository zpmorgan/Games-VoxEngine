#!/usr/bin/env perl
use common::sense;
use Games::VoxEngine;
use Games::VoxEngine::Logging;
use Games::VoxEngine::Client;
use Getopt::Long;

my $spawn_server = 0;
my $login_name;
GetOptions ('spawn!' => \$spawn_server,
            'name' => \$login_name,
);

if ($spawn_server){
   if (fork()==0){
     
      exec('perl bin/construder_server');
   }
   sleep(5);
}


#vox_enable_log_categories ('all');
vox_enable_log_categories ('info', 'error', 'warn', 'chat');

Games::VoxEngine::Debug::init ("client");

our $game = eval { Games::VoxEngine::Client->new (auto_login => $login_name) };
if ($@) {
   vox_log (error => "Couldn't initialized client: %s", $@);
   exit 1;
}

our $in_ex; #does $in_ex do anything?
$game->set_exception_cb (sub {
   my ($ex, $ev) = @_;
   return if $in_ex;
   local $in_ex = 1;
   vox_log (error => "exception in client (%s): %s", $ev, $ex);
   $game->{front}->msg ("Fatal Error: Exception in client caught: $ev: $ex");
});

$game->start;
