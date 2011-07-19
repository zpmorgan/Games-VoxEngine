#!/usr/bin/env perl
use common::sense;
use Games::VoxEngine;
use Games::VoxEngine::Logging;
use Games::VoxEngine::Client;
use Games::VoxEngine::Server;
use Getopt::Long;
use IO::Pipe;
use AnyEvent;

vox_enable_log_categories ('info', 'error', 'warn', 'chat');

my $spawn_server = 1;
my $login_name = 'foo';
GetOptions ('spawn!' => \$spawn_server,
            'name' => \$login_name,
);

if ($spawn_server){
   my $server_to_client = IO::Pipe->new();
   my $client_to_server = IO::Pipe->new();
   
   if (fork()==0){
      #run server.
    #  vox_enable_log_categories ('debug', 'info', 'error', 'warn', 'chat');
      Games::VoxEngine::Debug::init ("server");

      my $server = Games::VoxEngine::Server->new(
         pipe_to_client => $server_to_client,
         pipe_from_client => $client_to_server, 
      #   log_categories => ['info', 'error', 'warn'],
      #   log_file => '/tmp/minecrap_server.log',
         temporary => 1,
      );
      $server->listen;
      exit(0);
   }

   vox_enable_log_categories ('debug', 'info', 'error', 'warn', 'chat');
   Games::VoxEngine::Debug::init ("client");
   #run client.
   my $client = eval { Games::VoxEngine::Client->new (
      auto_login => $login_name,
      pipe_from_server => $server_to_client,
      pipe_to_server => $client_to_server, 
   #   log_categories => ['info', 'error', 'warn'],
    #  log_file => '/tmp/minecrap_client.log',
      host => 'localhost',
      port => 9364,
   ) };
   if ($@) {
      vox_log (error => "Couldn't initialize client: %s", $@);
      exit 1;
   }

   $client->set_exception_cb (sub {
         my ($ex, $ev) = @_;
         vox_log (error => "exception in client (%s): %s", $ev, $ex);
         $client->{front}->msg ("Fatal Error: Exception in client caught: $ev: $ex");
         });
   sleep(5);
   $client->start;


}
