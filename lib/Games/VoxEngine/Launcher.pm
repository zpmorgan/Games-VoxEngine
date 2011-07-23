# Games::VoxEngine - A voxel game engine.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
package Games::VoxEngine::Launcher;
use Mouse;
use Games::VoxEngine;
use Games::VoxEngine::Logging;
use Games::VoxEngine::Client;
use Games::VoxEngine::Server;
use AnyEvent;
use AnyEvent::Util;

=head1 NAME

Games::VoxEngine::Launcher - This module spawns server & client processes.

=over 4

=cut

has _server_pid => (
   isa => 'Int',
   is => 'rw',
);
has _client_pid => (
   isa => 'Int',
   is => 'rw',
);
has run_locally => (
   is => 'Bool',
   is => 'ro',
   default => 1,
);

has _client_to_server => (
   isa => 'ArrayRef',
   is => 'rw',
   default => sub{[]},
);
has _server_to_client => (
   isa => 'ArrayRef',
   is => 'rw',
   default => sub{[]},
);
has login_name => (
   isa => 'Str',
   is => 'rw',
   default => 'foo',
);

sub BUILD{
   my $self = shift;
  
   vox_enable_log_categories ('info', 'error', 'warn');
   vox_log('foo', 'BUILDing launcher pipes');
   
   #server reads, client writes.
   my ($r,$w) = AnyEvent::Util::portable_pipe();
   $self->_client_to_server->[0] = $r;
   $self->_client_to_server->[1] = $w;

   #client reads, server writes.
   my ($r2,$w2) = AnyEvent::Util::portable_pipe();
   $self->_server_to_client->[0] = $r2;
   $self->_server_to_client->[1] = $w2;
}

sub launch {
   my $self = shift;
   exit(1) unless (2 == @{$self->_client_to_server});
   $self->start_server();
   $self->start_client();
   $self->haunt();
}

sub start_server {
   my $self = shift;
   my $server_pid = fork();
   if ($server_pid){
      $self->_server_pid($server_pid);
   }
   else { #this is child. so run server.
      vox_enable_log_categories ('info', 'error', 'warn');
      Games::VoxEngine::Debug::init ("server");

      my $server = eval { Games::VoxEngine::Server->new(
         run_locally => [$self->_client_to_server->[0], $self->_server_to_client->[1]],
      #   temporary => 1,
      ) };
      if ($@) {
         vox_log error => "Couldn't initialize server: $@ ";
         exit 1;
      }
      $server->listen;
      exit(0);
   }
}

sub start_client{
   my $self = shift;
   my $client_pid = fork();
   if ($client_pid){
      $self->_client_pid($client_pid);
   }
   else { #this is child. so run client.

      vox_enable_log_categories ('info', 'error', 'warn');
      Games::VoxEngine::Debug::init ("client");
      my $client = eval { Games::VoxEngine::Client->new (
            auto_login => $self->login_name,
            run_locally => [$self->_server_to_client->[0], $self->_client_to_server->[1]],
            #host => 'localhost',
            #port => 9364,
      ) };
      if ($@) {
         vox_log error => "Couldn't initialize client: $@";
         exit 1;
      }
      $client->start;
   }
}

sub haunt {
   my $self = shift;
sleep(5);
}


1;
=back

=head1 AUTHOR

Zach Morgan, C<< <zpmorgan@gmail.com> >>

=head1 COPYRIGHT & LICENSE

Copyright 2011 Zach Morgan, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the terms of the GNU Affero General Public License.

=cut


