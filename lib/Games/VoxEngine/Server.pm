# Games::VoxEngine - A 3D Game written in Perl with an infinite and modifiable world.
# Copyright (C) 2011  Robin Redeker
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
package Games::VoxEngine::Server;

#use base qw/Object::Event/;
use Mouse;
use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;
use JSON;
use Carp qw/confess/;

use Games::VoxEngine::Protocol;
use Games::VoxEngine::Server::Resources;
use Games::VoxEngine::Server::Player;
use Games::VoxEngine::Server::World;
use Games::VoxEngine::Server::Objects;
use Games::VoxEngine::UI;
use Games::VoxEngine::Vector;
use Games::VoxEngine::Logging;

#push @ISA, qw/Object::Event/;
has _event_handler => (
   is => 'ro',
   isa => 'Object::Event',
   builder => '_build_event_handler',
   lazy => 1,
   handles => [qw/ reg_cb unreg_cb set_exception_cb handles stop_event /],
);
sub _build_event_handler{
   my $self = shift;
   my $EH = Object::Event->new();
   $EH->init_object_events;
   return $EH;
}

#if temporary is set, shut down after player disconnects.
has 'temporary' => (
   is => 'ro',
   isa => 'Bool',
   default => 0,
);
has run_locally => (
   is => 'ro',
   isa => 'ArrayRef',
);
sub pipe_from_client{ shift()->run_locally()->[0] }
sub pipe_to_client{ shift()->run_locally()->[1] }

has 'port' => (
   isa => 'Int',
   is => 'ro',
   default => 9364,
);
has _cv => (
   isa => 'AnyEvent::CondVar',
   is => 'ro',
   default => sub{ AnyEvent->condvar() },
);

=head1 NAME

Games::VoxEngine::Server - Server side networking and player management

=over 4

=cut

our $RES;

sub BUILD {
   my ($self) = @_;

   $RES = Games::VoxEngine::Server::Resources->new;
   $RES->init_directories;
   $RES->load_content_file;

   world_init ($self, $RES->{region_cmds});

   $RES->load_objects;

   $self->{sigint} = AE::signal INT => sub {
      vox_log (info => "received signal INT, saving maps and players and shutting down...");
      $self->shutdown;
   };
   $self->{sigterm} = AE::signal TERM => sub {
      vox_log (info => "received signal TERM, saving maps and players and shutting down...");
      $self->shutdown;
   };

   vox_log (info => "Initiated world.");

}

sub listen {
   my ($self) = @_;
   
   if ($self->run_locally){
     #use pipes for communication 
     $self->pipe_listen();
   }
   else{
      $self->tcp_listen();
   }
   #AnyEvent won't stop until $self->_cv->send().
   $self->_cv->recv();
};

#deal with just one client, with a pipe.
sub pipe_listen{
   my $self = shift;
   my $cid = "piper42";
   my $hdl_in = AnyEvent::Handle->new(
      fh => $self->pipe_from_client,
      on_error => sub {
         my ($hdl, $fatal, $msg) = @_;
         $hdl->destroy;
         $self->client_disconnected ($cid, "error: $msg");
      },
      on_eof => sub {
         my ($hdl, $fatal, $msg) = @_;
         $hdl->destroy;
         $self->client_disconnected ($cid, "error: $msg");
      },
   );
   my $hdl_out = AnyEvent::Handle->new(
      fh => $self->pipe_to_client,
      on_error => sub {
         my ($hdl, $fatal, $msg) = @_;
         $hdl->destroy;
         $self->client_disconnected ($cid, "error: $msg");
      },
   );
   $self->{clients}->{$cid}{in}  = $hdl_in;
   $self->{clients}->{$cid}{out} = $hdl_out;
   $self->client_connected ($cid);
   $self->handle_protocol ($cid);
}

#start a tcp server on $self->port
sub tcp_listen{
   my $self = shift;

   tcp_server undef, $self->port, sub {
      my ($fh, $h, $p) = @_;

      $self->{clids}++;
      my $cid = "$h:$p:$self->{clids}";
      my $hdl = AnyEvent::Handle->new (
         fh => $fh,
         on_error => sub {
            my ($hdl, $fatal, $msg) = @_;
            $hdl->destroy;
            $self->client_disconnected ($cid, "error: $msg");
         },
         on_eof => sub {
            my ($hdl, $fatal, $msg) = @_;
            $hdl->destroy;
            $self->client_disconnected ($cid, "error: $msg");
         },
      );
      #sockets are bidirectional. use same handle for in & out.
      $self->{clients}->{$cid}{out} = $hdl;
      $self->{clients}->{$cid}{in} = $hdl; 
      $self->client_connected ($cid);
      $self->handle_protocol ($cid);
   };

   vox_log (info => "Listening for clients on port %d", $self->port);
}

sub shutdown {
   my ($self) = @_;
   world_save_all ();
   for (values %{$self->{players}}) {
      $_->save;
   }
   $self->_cv->send;
}

sub handle_protocol {
   my ($self, $cid) = @_;

   $self->{clients}->{$cid}{in}->push_read (packstring => "N", sub {
      my ($handle, $string) = @_;
      $self->handle_packet ($cid, data2packet ($string));
      $self->handle_protocol ($cid);
   }) if $self->{clients}->{$cid};
}

sub send_client {
   my ($self, $cid, $hdr, $body) = @_;
   #print (%$hdr, "\n") and confess unless $body;
   $body //= '';

   $self->{clients}->{$cid}{out}->push_write (packstring => "N", packet2data ($hdr, $body));

   if (!grep { $hdr->{cmd} eq $_ } qw/chunk activate_ui/) {
      vox_log (network => "send[%d]> %s: %s", length ($body), $hdr->{cmd}, join (',', keys %$hdr));
   }
}

sub transfer_res2client {
   my ($self, $cid, $res) = @_;
   $self->{transfer}->{$cid} = [
      map {
         my $body = "";
         if (defined ${$_->[-1]} && not (ref ${$_->[-1]})) {
            $body = ${$_->[-1]};
            $_->[-1] = undef;
         } else {
            $_->[-1] = ${$_->[-1]};
         }
         packet2data ({
            cmd => "resource",
            res => $_
         }, $body)
      } @$res
   ];
   $self->send_client ($cid, { cmd => "transfer_start" });
   $self->push_transfer ($cid);
}

sub push_transfer {
   my ($self, $cid) = @_;
   my $t = $self->{transfer}->{$cid};
   return unless $t;

   my $data = shift @$t;
   $self->{clients}->{$cid}{out}->push_write (packstring => "N", $data);
   unless (@$t) {
      $self->send_client ($cid, { cmd => "transfer_end" });
      delete $self->{transfer}->{$cid};
   }
}

sub client_disconnected {
   my ($self, $cid) = @_;
   my $pl = delete $self->{players}->{$cid};
   $pl->logout if $pl;
   delete $self->{player_guards}->{$cid};
   delete $self->{clients}->{$cid};
   vox_log (info => "Client disconnected: %s", $cid);
   vox_log (info => "temp: " . $self->temporary);

   if ($self->temporary){
      vox_log (info => 'Shutting down temporary server.');
      $self->shutdown;
   }
}

sub schedule_chunk_upd {
   my ($self) = @_;
   for (values %{$self->{players}}) {
      $_->push_chunk_to_network;
   }
}

sub get_player {
   my ($self, $name) = @_;
   grep {
      $_->{name} eq $name
   } values %{$self->{players}}
}

sub players_near_pos {
   my ($self, $pos) = @_;
   my @p;
   for (values %{$self->{players}}) {
      my $d = vsub ($pos, $_->get_pos_normalized);
      my $dist = vlength ($d);
      if ($dist < 60) {
         push @p, [$_, $dist];
      }
   }
   @p
}

sub client_connected {
   my ($self, $cid) = @_;
   vox_log (info => "Client connected: %s", $cid);
}

sub handle_player_packet {
   my ($self, $player, $hdr, $body) = @_;

   if ($hdr->{cmd} eq 'ui_response') {
      $player->ui_res ($hdr->{ui}, $hdr->{ui_command}, $hdr->{arg},
                       [$hdr->{pos}, $hdr->{build_pos}]);

   } elsif ($hdr->{cmd} eq 'p') {
      $player->update_pos ($hdr->{p}, $hdr->{l});

   } elsif ($hdr->{cmd} eq 'set_player_pos_ok') {
      $player->unfreeze_update_pos ($hdr->{id});

   } elsif ($hdr->{cmd} eq 'visibility_radius') {
      $player->set_vis_rad ($hdr->{radius});

   } elsif ($hdr->{cmd} eq 'vis_chunks') {
      $player->set_visible_chunks ($hdr->{new}, $hdr->{old}, $hdr->{req});

   } elsif ($hdr->{cmd} eq 'pos_action') {
      if ($hdr->{action} == 1 && @{$hdr->{build_pos} || []}) {
         $player->start_materialize ($hdr->{build_pos});

      } elsif ($hdr->{action} == 2 && @{$hdr->{build_pos} || []}) {
         $player->debug_at ($hdr->{pos});
         $player->debug_at ($hdr->{build_pos});

      } elsif ($hdr->{action} == 3 && @{$hdr->{pos} || []}) {
         $player->start_dematerialize ($hdr->{pos});
      }

   }

}

sub login {
   my ($self, $cid, $name) = @_;

   if (grep { $_->{name} eq $name } values %{$self->{players}}) {
      $self->send_client ($cid, {
         cmd => "msg", msg => "Couldn't login as '$name', already logged in!"
      });
      return;
   }

   my $pl = $self->{players}->{$cid}
      = Games::VoxEngine::Server::Player->new (
           cid => $cid, name => $name);

   $self->{player_guards}->{$cid} = $pl->reg_cb (send_client => sub {
      my ($pl, $hdr, $body) = @_;
      $self->send_client ($cid, $hdr, $body);
   });

   $pl->init;

   $self->send_client ($cid,
      { cmd => "login", name => $name });
}

sub handle_packet {
   my ($self, $cid, $hdr, $body) = @_;

   if ($hdr->{cmd} ne 'p') {
      vox_log (network => "recv[%d]> %s: %s", length ($body), $hdr->{cmd}, join (',', keys %$hdr));
   }

   if ($hdr->{cmd} eq 'hello') {
      $self->send_client ($cid,
         { cmd => "hello",
           info => {
              version => (sprintf "G::C::Server %s", $Games::VoxEngine::VERSION),
              credits => $RES->credits,
           }
         });

   } elsif ($hdr->{cmd} eq 'ui_response' && $hdr->{ui} eq 'login') {
      $self->send_client ($cid, { cmd => deactivate_ui => ui => "login" });

      if ($hdr->{ui_command} eq 'login') {
         $self->login ($cid, $hdr->{arg}->{name})
      }

   } elsif ($hdr->{cmd} eq 'login') {
      if ($hdr->{name} ne '') {
         $self->login ($cid, $hdr->{name})

      } else {
         $self->send_client ($cid, { cmd => activate_ui => ui => "login", desc => {
            %{ui_window ("Login",
               ui_pad_box (hor =>
                  ui_desc ("Name:"),
                  ui_entry (name => "", 9),
               ),
               ui_subdesc ("After Login hit F1 for Client Help\nAnd F2 for Server Help!"),
            )},
            commands => {
               default_keys => {
                  return => "login",
               },
            },
         } });
      }

   } elsif ($hdr->{cmd} eq 'transfer_poll') { # a bit crude :->
      $self->push_transfer ($cid);

   } elsif ($hdr->{cmd} eq 'list_resources') {
      my $res = $RES->list_resources;
      $self->send_client ($cid, { cmd => "resources_list", list => $res });

   } elsif ($hdr->{cmd} eq 'get_resources') {
      my $res = $RES->get_resources_by_id (@{$hdr->{ids}});
      $self->transfer_res2client ($cid, $res);

   } else {
      my $pl = $self->{players}->{$cid}
         or return;

      $self->handle_player_packet ($pl, $hdr, $body);
   }
}

=back

=head1 AUTHOR

Robin Redeker, C<< <elmex@ta-sa.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2011 Robin Redeker, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the terms of the GNU Affero General Public License.

=cut

1;

