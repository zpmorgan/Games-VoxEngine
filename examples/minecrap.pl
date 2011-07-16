#!/usr/bin/env perl
use common::sense;
use Games::VoxEngine;
use Games::VoxEngine::Logging;
use Games::VoxEngine::Client;
use Games::VoxEngine::Server;
use Getopt::Long;
use IO::Pipe;

my $spawn_server = 0;
my $login_name = 'foo';
GetOptions ('spawn!' => \$spawn_server,
            'name' => \$login_name,
);

if ($spawn_server){
   my $server_to_client = IO::Pipe->new();
   my $client_to_server = IO::Pipe->new();
   
   if (fork()==0){
      #run server.
      #initialize debug stuff
      vox_enable_log_categories ('info', 'error', 'warn');
      Games::VoxEngine::Debug::init ("server");

      my $server = Games::VoxEngine::Server->new(
         pipe_to_client => $server_to_client,
         pipe_from_client => $client_to_server, 
         log_categories => ['info', 'error', 'warn'],
         log_file => '/tmp/minecrap_server.log',
      );
      $server->init;
      #$server->enable_log_categories('info', 'error', 'warn');
      $server->listen;
      
      exit(0);
   }

   #run client.
   my $client = eval { Games::VoxEngine::Client->new (
      auto_login => $login_name,
      pipe_from_server => $server_to_client,
      pipe_to_server => $client_to_server, 
      log_categories => ['info', 'error', 'warn'],
    #  log_file => '/tmp/minecrap_client.log',

   ) };
   if ($@) {
      vox_log (error => "Couldn't initialized client: %s", $@);
      exit 1;
   }

   $client->set_exception_cb (sub {
         my ($ex, $ev) = @_;
         vox_log (error => "exception in client (%s): %s", $ev, $ex);
         $client->{front}->msg ("Fatal Error: Exception in client caught: $ev: $ex");
         });

   $client->start;



}
