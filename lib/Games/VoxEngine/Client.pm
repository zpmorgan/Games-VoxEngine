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
package Games::VoxEngine::Client;
use Mouse;
use common::sense;
use Compress::LZF;
use Games::VoxEngine::Client::Frontend;
use Games::VoxEngine::Client::World;
use Games::VoxEngine::Protocol;
use Games::VoxEngine::Vector;
use Games::VoxEngine::Logging;
use Games::VoxEngine;
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use Benchmark qw/:all/;
use Time::HiRes qw/time/;

#use base qw/Object::Event/;

=head1 NAME

Games::VoxEngine::Client - Client Networking Implementation

=over 4

=cut

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
has run_locally => (
   is => 'ro',
   isa => 'ArrayRef',
);
sub pipe_from_server { shift()->run_locally()->[0] }
sub pipe_to_server { shift()->run_locally()->[1] }

has 'port' => (
   isa => 'Int',
   is => 'ro',
   default => 9364,
);

has 'host' => (
   isa => 'Str',
   is => 'ro',
   default => 'localhost',
);
has srv_in => (
   is => 'rw',
   isa => 'AnyEvent::Handle',
);
has srv_out => (
   is => 'rw',
   isa => 'AnyEvent::Handle',
);

#event loop conditional
has _cv => (
   isa => 'AnyEvent::CondVar',
   is => 'ro',
   default => sub{ AnyEvent->condvar() },
);

sub BUILD {
   my $self  = shift;

   Games::VoxEngine::World::init (sub {
   }, sub { });

   $self->{res} = Games::VoxEngine::Client::Resources->new;
   $self->{res}->init_directories;
   $self->{res}->load_config;
   $Games::VoxEngine::Client::UI::RES = $self->{res};

   $self->{front} =
      Games::VoxEngine::Client::Frontend->new (res => $self->{res}, client => $self);

   $self->{in_ex} = 0;
   $self->{front}->set_exception_cb (sub {
      my ($ex, $ev) = @_;
      return if $self->{in_ex};
      local $self->{in_ex} = 1;
      vox_log (error => "exception in frontend (%s): %s", $ev, $ex);
      $self->{front}->msg ("Fatal Error: Exception in frontend caught: $ev: $ex");
   });

   $self->{front}->reg_cb (
      update_player_pos => sub {
         $self->send_server ({
            cmd => "p", p => vcompres ($_[1]), l => vcompres ($_[2])
         });
      },
      position_action => sub {
         my ($front, $pos, $build_pos, $btn) = @_;
         $self->send_server ({
            cmd => "pos_action", pos => $pos,
            build_pos => $build_pos, action => $btn
         });
      },
      visibility_radius => sub {
         my ($front, $radius) = @_;
         $self->send_server ({ cmd => "visibility_radius", radius => $radius });
      },
      visible_chunks_changed => sub {
         my ($front, $new, $old, $req) = @_;
         (@$req) = grep {
            my $p = $_;
            my $id = world_pos2id ($p);
            my $rereq = not $self->{requested_chunks}->{$id};
            $self->{requested_chunks}->{$id} = time if $rereq;
            $rereq
         } @$req; # Frontend will retry until it succeeds (at least it should)!

         return unless @$new || @$old || @$req;
         $self->send_server ({ cmd => "vis_chunks", old => $old, new => $new, req => $req });
      }
   );

   $self->{req_chnk_cleanup} = AE::timer 1, 0.5, sub {
      for (keys %{$self->{requested_chunks}}) {
         my $to = $self->{requested_chunks}->{$_};
         my $td = time - $to;
         delete $self->{requested_chunks}->{$_} if $td > 2;
      }
   };
   $self->connect ($self->host , $self->port);

   return $self
}

sub is_connected{
   my $self = shift;
   return ( $self->srv_in() && $self->srv_out() );
}

sub start {
   my ($self) = @_;
   $self->_cv->recv;
}

sub connect {
   my ($self) = @_;
   if ($self->run_locally){
      $self->piped_connect();
   }
   else {
      $self->socket_connect ($self->host, $self->port);
   }
}

sub piped_connect{
   my $self = shift;
   
   vox_log (debug => "connecting to piped server");

   my $hdl_in = AnyEvent::Handle->new(
      fh => $self->pipe_from_server(),
      on_error => sub {
         my ($hdl, $fatal, $msg) = @_;
         $self->disconnect;
      },
   );
   my $hdl_out = AnyEvent::Handle->new(
      fh => $self->pipe_to_server(),
      on_error => sub {
         my ($hdl, $fatal, $msg) = @_;
         $self->disconnect;
      },
   );
   $self->{srv_in}  = $hdl_in;
   $self->{srv_out} = $hdl_out;
   $self->handle_protocol;
   $self->connected;
}

sub socket_connect {
   my ($self, $host, $port) = @_;

   vox_log (debug => "connecting to server %s at port %d", $host, $port);

   delete $self->{recon};
   tcp_connect $host, $port, sub {
      my ($fh) = @_;
      unless ($fh) {
         vox_log (error => "Couldn't connect to server %s at port %d: %s", $host, $port, $!);
         $self->{front}->msg ("Couldn't connect to server: $!");
         $self->{recon} = AE::timer 5, 0, sub { $self->connect; };
         return;
      }

      my $hdl = AnyEvent::Handle->new (
         fh => $fh,
         on_error => sub {
            my ($hdl, $fatal, $msg) = @_;
            $self->disconnect;
         }
      );
      # tcp is bidirectional. Same handle for both
      $self->{srv_in}  = $hdl;
      $self->{srv_out} = $hdl;
      $self->handle_protocol;
      $self->connected;
   };
}

sub handle_protocol {
   my ($self) = @_;

   $self->srv_in->push_read (packstring => "N", sub {
      my ($handle, $string) = @_;
      $self->handle_packet (data2packet ($string));
      $self->handle_protocol;
   });
}

sub send_server {
   my ($self, $hdr, $body) = @_;
   if ($self->is_connected()) {
      vox_log (network => "send[%d]> %s: %s", length ($body), $hdr->{cmd}, join (',', keys %$hdr));
      $self->srv_out->push_write (packstring => "N", packet2data ($hdr, $body));
   }
}

sub connected {
   my ($self) = @_;
   $self->{front}->msg ("Connected to Server!");
   if ($self->run_locally){
      vox_log (info => "connected to piped server.");
   } else {
      vox_log (info => "connected to server %s on port %d", $self->host, $self->port);
   }

   $self->send_server ({ cmd => 'hello', version => "Games::VoxEngine::Client 0.1" });
}

sub handle_packet {
   my ($self, $hdr, $body) = @_;

   vox_log (network => "recv[%d]> %s: %s", length ($body), $hdr->{cmd}, join (',', keys %$hdr));

   if ($hdr->{cmd} eq 'hello') {
      $self->{front}->{server_info} = $hdr->{info};
      $self->{front}->msg ("Queried Resources");
      $self->send_server ({ cmd => 'list_resources' });

   } elsif ($hdr->{cmd} eq 'resources_list') {
      $self->{res}->set_resources ($hdr->{list});

      #  [ $_, $res->{type}, $res->{md5}, \$res->{data} ]
      my @data_res_ids = map { $_->[0] } grep { defined $_->[2] } @{$hdr->{list}};

      if (@data_res_ids) {
         $self->send_server ({ cmd => get_resources => ids => \@data_res_ids });
         $self->{front}->msg ("Initiated resource transfer (".scalar (@data_res_ids).")");
      } else {
         $self->{front}->msg ("No resources on server found!");
      }

   } elsif ($hdr->{cmd} eq 'resource') {
      my $res = $hdr->{res};
      #  [ $_, $res->{type}, $res->{md5}, \$res->{data} ]
      $self->{res}->set_resource_data ($hdr->{res}, $body);
      $self->send_server ({ cmd => 'transfer_poll' });

   } elsif ($hdr->{cmd} eq 'login') {
      $self->{front}->{res}->{config}->{chat}->{recent_login_name} = $hdr->{name};
      $self->{front}->{res}->save_config;

   } elsif ($hdr->{cmd} eq 'transfer_end') {
      $self->{front}->msg;
      #print JSON->new->pretty->encode ($self->{front}->{res}->{resource});
      $self->{res}->post_proc;
      vox_cond_log (debug => sub {
         vox_log (debug => "dumping received resources:");
         $self->{res}->dump_resources;
      });
      $self->send_server (
         { cmd => 'login',
           ($self->{auto_login} ? (name => $self->{auto_login}) : ()) });

   } elsif ($hdr->{cmd} eq 'place_player') {
      $self->{front}->set_player_pos ($hdr->{pos});
      $self->send_server ({ cmd => 'set_player_pos_ok', id => $hdr->{id} });

   } elsif ($hdr->{cmd} eq 'activate_ui') {
      my $desc = $hdr->{desc};
      $desc->{command_cb} = sub {
         my ($cmd, $arg, $need_selection) = @_;

         $self->send_server ({
            cmd => 'ui_response' =>
               ui => $hdr->{ui}, ui_command => $cmd, arg => $arg,
               ($need_selection
                  ? (pos => $self->{front}->{selected_box},
                     build_pos => $self->{front}->{selected_build_box})
                  : ())
         });
      };
      $self->{front}->activate_ui ($hdr->{ui}, $desc);

   } elsif ($hdr->{cmd} eq 'deactivate_ui') {
      $self->{front}->deactivate_ui ($hdr->{ui});

   } elsif ($hdr->{cmd} eq 'highlight') {
      $self->{front}->add_highlight ($hdr->{pos}, $hdr->{color}, $hdr->{fade});

   } elsif ($hdr->{cmd} eq 'model_highlight') {
      if ($hdr->{model}) {
         $self->{front}->add_highlight_model ($hdr->{pos}, $hdr->{model}, $hdr->{id});
      } else {
         $self->{front}->remove_highlight_model ($hdr->{id});
      }

   } elsif ($hdr->{cmd} eq 'dirty_chunks') {
      $self->{front}->clear_chunk ($_) for @{$hdr->{chnks}}

   } elsif ($hdr->{cmd} eq 'chunk') {
      my $id = world_pos2id ($hdr->{pos});
      delete $self->{requested_chunks}->{$id};
      $body = decompress ($body);

      # WARNING FIXME XXX: this data might not be freed up all chunks that
      # were set/initialized by the server! see also free_compiled_chunk in Frontend.pm
      my $neigh_chunks =
         Games::VoxEngine::World::set_chunk_data (@{$hdr->{pos}}, $body, length $body);
      if ($neigh_chunks & 0x01) {
         $self->{front}->dirty_chunk (vaddd ($hdr->{pos}, -1, 0, 0));
      }
      if ($neigh_chunks & 0x02) {
         $self->{front}->dirty_chunk (vaddd ($hdr->{pos}, 0, -1, 0));
      }
      if ($neigh_chunks & 0x04) {
         $self->{front}->dirty_chunk (vaddd ($hdr->{pos}, 0, 0, -1));
      }
      if ($neigh_chunks & 0x08) {
         $self->{front}->dirty_chunk (vaddd ($hdr->{pos}, 1, 0, 0));
      }
      if ($neigh_chunks & 0x10) {
         $self->{front}->dirty_chunk (vaddd ($hdr->{pos}, 0, 1, 0));
      }
      if ($neigh_chunks & 0x20) {
         $self->{front}->dirty_chunk (vaddd ($hdr->{pos}, 0, 0, 1));
      }
      $self->{front}->dirty_chunk ($hdr->{pos});

   } elsif ($hdr->{cmd} eq 'msg') {
      $self->{front}->msg ("Server: " . $hdr->{msg});
   }
}

sub disconnect {
   my ($self) = @_;
   if($self->run_locally){
      #local server shut down. so exit?
      $self->srv_out->push_shutdown(); #send eof so server shuts down
      $self->stop;
      vox_log (network => "pushed EOF to server.");
      vox_log (info => "disconnected from local server");
   }
   else{
      #shut down socket.
      unless ($self->srv_out->destroyed()) {
         $self->srv_out->push_shutdown(); #send eof to server
         $self->srv_out->destroy(); #send eof so server shuts down
      }
      delete $self->{srv_in};
      delete $self->{srv_out};
      
      $self->{front}->msg ("Disconnected from server!");
      $self->{front}->clear_chunks;
      #try to reconnect.
      $self->{recon} = AE::timer 5, 0, sub { $self->connect; };
      vox_log (info => "disconnected from server");
   }
}

#end event loop. try to shut down without calling exit.
sub stop{
   my $self = shift;
   $self->_cv->send;
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

