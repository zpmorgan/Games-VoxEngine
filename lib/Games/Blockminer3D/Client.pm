package Games::Blockminer3D::Client;
use common::sense;
use Games::Blockminer3D::Client::Frontend;
use Games::Blockminer3D::Client::MapChunk;
use Games::Blockminer3D::Client::Renderer;
use Games::Blockminer3D::Client::World;
use Games::Blockminer3D::Protocol;
use Games::Blockminer3D;
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use Math::VectorReal;
use Benchmark qw/:all/;

use base qw/Object::Event/;

=head1 NAME

Games::Blockminer3D::Client - desc

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 METHODS

=over 4

=item my $obj = Games::Blockminer3D::Client->new (%args)

=cut

sub new {
   my $this  = shift;
   my $class = ref ($this) || $this;
   my $self  = { @_ };
   bless $self, $class;

   $self->init_object_events;

   Games::Blockminer3D::World::init;
   $self->{res} = Games::Blockminer3D::Client::Resources->new;
   $Games::Blockminer3D::Client::Renderer::RES = $self->{res};

   $self->{front} =
      Games::Blockminer3D::Client::Frontend->new (res => $self->{res});

   $self->{front}->reg_cb (
      update_player_pos => sub {
         $self->send_server ({ cmd => "player_pos", pos => $_[1] });
      },
      position_action => sub {
         my ($front, $pos, $build_pos, $btn) = @_;
         $self->send_server ({
            cmd => "pos_action", pos => $pos,
            build_pos => $build_pos, action => $btn
         });
      }
   );

   $self->connect (localhost => 9364);

   return $self
}

sub start {
   my ($self) = @_;

   my $c = AnyEvent->condvar;

   $c->recv;
}

sub msgbox {
   my ($self, $msg, $cb) = @_;

   $self->{front}->activate_ui (cl_msgbox => {
      window => {
         extents => [ 'center', 'center', 0.9, 0.1 ],
         color => "#000000",
         alpha => 1,
      },
      elements => [
         {
            type => "text",
            extents => [0, 0, 1, 0.6],
            align => "center",
            font => 'normal',
            color => "#ffffff",
            text => $msg
         },
         {
            type => "text",
            extents => [0, 0.6, 1, 0.4],
            align => "center",
            font => 'small',
            color => "#888888",
            text => "press ESC to hide",
         }
      ]
   });
}

sub connect {
   my ($self, $host, $port) = @_;

   tcp_connect $host, $port, sub {
      my ($fh) = @_
         or die "connect failed: $!\n";

      my $hdl = AnyEvent::Handle->new (
         fh => $fh,
         on_error => sub {
            my ($hdl, $fatal, $msg) = @_;
            $hdl->destroy;
            $self->disconnected;
         }
      );

      $self->{srv} = $hdl;
      $self->handle_protocol;
      $self->connected;
   };
}

sub handle_protocol {
   my ($self) = @_;

   $self->{srv}->push_read (packstring => "N", sub {
      my ($handle, $string) = @_;
      $self->handle_packet (data2packet ($string));
      $self->handle_protocol;
   });
}

sub send_server {
   my ($self, $hdr, $body) = @_;
   if ($self->{srv}) {
      $self->{srv}->push_write (packstring => "N", packet2data ($hdr, $body));
      warn "cl> $hdr->{cmd}\n";
   }
}

sub connected : event_cb {
   my ($self) = @_;
   $self->msgbox ("Connected to Server!");
   $self->send_server ({ cmd => 'hello', version => "Games::Blockminer3D::Client 0.1" });
}

sub handle_packet : event_cb {
   my ($self, $hdr, $body) = @_;

   warn "cl< $hdr->{cmd} (".length ($body).")\n";

   if ($hdr->{cmd} eq 'hello') {
      $self->msgbox ("Queried Resources");
      $self->send_server ({ cmd => 'list_resources' });

   } elsif ($hdr->{cmd} eq 'resources_list') {
      $self->{res}->set_resources ($hdr->{list});

      #  [ $_, $res->{type}, $res->{md5}, \$res->{data} ]
      my @data_res_ids = map { $_->[0] } grep { defined $_->[2] } @{$hdr->{list}};

      if (@data_res_ids) {
         $self->send_server ({ cmd => get_resources => ids => \@data_res_ids });
         $self->msgbox ("Initiated Resource Transfer (".scalar (@data_res_ids).")");
      } else {
         $self->msgbox ("No Resources Found!");
      }

   } elsif ($hdr->{cmd} eq 'resource') {
      my $res = $hdr->{res};
      #  [ $_, $res->{type}, $res->{md5}, \$res->{data} ]
      $self->{res}->set_resource_data ($hdr->{res}, $body);
      $self->send_server ({ cmd => 'transfer_poll' });

   } elsif ($hdr->{cmd} eq 'transfer_end') {
      $self->msgbox ("Transfer done! Waiting for map data...\n");
      #print JSON->new->pretty->encode ($self->{front}->{res}->{resource});
      $self->{res}->post_proc;
      $self->{res}->dump_resources;
      $self->send_server ({ cmd => 'enter' });

   } elsif ($hdr->{cmd} eq 'place_player') {
      $self->{front}->set_player_pos ($hdr->{pos});

   } elsif ($hdr->{cmd} eq 'activate_ui') {
      my $desc = $hdr->{desc};
      $desc->{command_cb} = sub {
         my ($cmd, $arg) = @_;
         $self->send_server ({
            cmd => 'ui_response' =>
               ui => $hdr->{ui}, ui_command => $cmd, arg => $arg
         });
      };
      $self->{front}->activate_ui ($hdr->{ui}, $desc);

   } elsif ($hdr->{cmd} eq 'deactivate_ui') {
      $self->{front}->deactivate_ui ($hdr->{ui});

   } elsif ($hdr->{cmd} eq 'highlight') {
      $self->{front}->add_highlight ($hdr->{pos}, $hdr->{color}, $hdr->{fade}, $hdr->{solid});

   } elsif ($hdr->{cmd} eq 'chunk') {
      my $chnk = world_get_chunk (@{$hdr->{pos}});
      $chnk = Games::Blockminer3D::Client::MapChunk->new
         unless $chnk;
      printf ("BODY LEN %d\n", length $body);
      $chnk->data_fill ($self->{res}, $body);
      world_set_chunk (@{$hdr->{pos}}, $chnk);
      Games::Blockminer3D::World::set_chunk_data (@{$hdr->{pos}}, $body, length $body);
   }
}

sub disconnected : event_cb {
   my ($self) = @_;
}

=back

=head1 AUTHOR

Robin Redeker, C<< <elmex@ta-sa.org> >>

=head1 SEE ALSO

=head1 COPYRIGHT & LICENSE

Copyright 2011 Robin Redeker, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;

